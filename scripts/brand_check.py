#!/usr/bin/env python3
"""Check brand.css, the base style, against every page and document using it.

    brand_check.py [--root DIR] [--offline] [--diff REV]
    brand_check.py --self-test

ROOT (default ~/src/oceanhue) mirrors https://iguigova.github.io: the hub
repo, iguigova.github.io, is the site root and holds brand.css, every other
repo is /<repo>/, and ROOT/brand.css is a symlink to the hub's file. Run it
after every change to brand.css, or to a project's theme colours.

Checks, each printing `ok` or `FAIL <what>`:

  link      ROOT/brand.css is a symlink to the hub's brand.css
  contrast  every colour token meets its WCAG AA ratio against --bg in both
            themes: text 4.5:1, large titles and rules 3:1; a colour token
            this script has no role for fails, so none goes unchecked
  imports   every reference to brand.css in a repo's CSS or HTML resolves
            to the hub's file, or sits in a repo whose build copies
            ../brand.css (boca)
  themes    no consumer repo's CSS or HTML uses prefers-color-scheme: a
            project colour is light-dark(light, dark), so it follows the
            color-scheme brand.css sets, data-theme included
  copies    every built copy (dist/brand.css) equals the hub's file
  live      the site serves origin/main's brand.css (skipped by --offline)

--diff REV also renders every consumer page with brand.css at REV and as it
is now, in light and dark, and prints the differing pixels of each; a page
whose CSS sets @page is a document and is printed too, with its page count.
Every page is rendered three times from each file, over a local server laid
out like the site, and the closest old and new pair is reported: headless
Chrome now and then renders a page in a second state, and a real change
differs in every pair. Beside it is how far the new file's own renders vary.
A refactor shows 0 everywhere; an intended change shows where it lands.
Differences are reported, never failed. A page in a repo whose build copies
brand.css is not rendered: its copy is what `copies` checks.

The Trust Loop artifact inlines brand.css too. No shell can read it, so the
last line names the commit its copy must name, for the session to check.

Exit 0 when every check passes, 1 when one fails, 75 when all pass but the
site gave no answer.
"""
import argparse
import contextlib
import functools
import http.server
import itertools
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request

HUB = "iguigova.github.io"
SITE = "https://iguigova.github.io/brand.css"
TEXT = {"--ink", "--muted", "--link", "--good"}
LARGE = {"--title", "--rule"}
SURFACE = {"--bg", "--hair", "--band", "--panel"}
RENDERS = 3
SKIP_DIRS = {"node_modules", "dist", ".git", "test", "coverage"}
REF = re.compile(
    r"""(?:url\(\s*["']?|href=["'])([^"')]*brand\.css)""")
LINK = re.compile(r"""href=["']([^"']+\.css)["']""")
STYLE = re.compile(r"<style[^>]*>(.*?)</style>", re.S)
HREF = re.compile(r"""href=["'][^"']+\.css["']""")
HEX = r"#[0-9a-fA-F]{6}"
TOKEN = re.compile(
    rf"(--[\w-]+):\s*(?:light-dark\(\s*({HEX}),\s*({HEX})\s*\)|({HEX}))")


class Report:
    def __init__(self, quiet=False):
        self.failed = False
        self.quiet = quiet

    def ok(self, msg):
        if not self.quiet:
            print(f"  ok   {msg}")

    def fail(self, msg):
        if not self.quiet:
            print(f"  FAIL {msg}")
        self.failed = True


def lum(hexcol):
    def chan(c):
        c = int(c, 16) / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (chan(hexcol[i:i + 2]) for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def tokens(css):
    """Each colour token of the first :root block as (light, dark)."""
    block = css[css.index(":root {"):]
    block = block[:block.index("}")]
    out = {}
    for name, light, dark, both in TOKEN.findall(block):
        out[name] = (light, dark) if light else (both, both)
    return out


def check_contrast(css, rep):
    before = rep.failed
    rep.failed = False
    toks = tokens(css)
    if "--bg" not in toks:
        rep.fail("contrast: brand.css has no --bg colour token")
        return
    for name, pair in toks.items():
        if name in SURFACE:
            continue
        need = 4.5 if name in TEXT else 3.0 if name in LARGE else None
        if need is None:
            rep.fail(f"contrast: {name} has no role here (text, large or"
                     " surface); add it to brand_check.py")
            continue
        for theme, col, bg in zip(("light", "dark"), pair, toks["--bg"]):
            r = ratio(col, bg)
            if r < need:
                rep.fail(f"contrast: {name} {theme} {col} is {r:.2f}:1"
                         f" on {bg}, needs {need}:1")
    if not rep.failed:
        rep.ok(f"contrast: {len(toks)} colour tokens pass in both themes")
    rep.failed |= before


def walk(repo):
    for dirpath, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if f.endswith((".css", ".html")) and f != "brand.css":
                yield pathlib.Path(dirpath, f)


def styling(f):
    """The text of f that loads styles: all of a CSS file; an HTML file's
    links and <style> blocks, never its prose, which may quote an import."""
    text = f.read_text(errors="replace")
    if f.suffix == ".css":
        return text
    return "\n".join(HREF.findall(text) + STYLE.findall(text))


def resolve(root, src, url):
    if url.startswith("/"):
        return (root / url.lstrip("/")).resolve()
    return (src.parent / url).resolve()


def builds_copy(repo):
    pkg = repo / "package.json"
    return pkg.exists() and "cp ../brand.css" in pkg.read_text()


def consumers(root):
    """{repo: [(file, url, resolved)]} for every repo referring to it."""
    found = {}
    for repo in sorted(p for p in root.iterdir() if p.is_dir()):
        if repo.name.startswith("."):
            continue
        for f in walk(repo):
            for url in REF.findall(styling(f)):
                found.setdefault(repo, []).append(
                    (f, url, resolve(root, f, url)))
    return found


def check_imports(root, brand, found, rep):
    if not found:
        rep.fail("imports: no file refers to brand.css; the scan is broken")
        return
    n = 0
    for repo, refs in found.items():
        for f, url, target in refs:
            n += 1
            if target == brand:
                continue
            if builds_copy(repo):
                continue
            rep.fail(f"imports: {f.relative_to(root)} loads {url},"
                     f" which is {target}, not {brand}")
    rep.ok(f"imports: {n} references in {len(found)} repos")


def check_themes(root, found, rep):
    bad = [f for repo in found for f in walk(repo)
           if "prefers-color-scheme" in styling(f)]
    for f in bad:
        rep.fail(f"themes: {f.relative_to(root)} uses prefers-color-scheme;"
                 " write the colour as light-dark(light, dark)")
    if not bad:
        rep.ok("themes: no consumer switches theme on its own")


def check_copies(root, brand, found, rep):
    for repo in found:
        copy = repo / "dist" / "brand.css"
        if builds_copy(repo) and copy.exists():
            if copy.read_bytes() == brand.read_bytes():
                rep.ok(f"copies: {copy.relative_to(root)} is current")
            else:
                rep.fail(f"copies: {copy.relative_to(root)} is stale;"
                         " rebuild it")


def git(hub, *args):
    return subprocess.run(["git", "-C", str(hub), *args],
                          capture_output=True, check=True).stdout


def check_live(hub, rep):
    """True when the site answered."""
    want = git(hub, "show", "origin/main:brand.css")
    try:
        with urllib.request.urlopen(SITE, timeout=15) as r:
            got = r.read()
    except OSError as e:
        print(f"  ---  live: no answer from {SITE} ({e})")
        return False
    if got == want:
        rep.ok("live: the site serves origin/main's brand.css")
    else:
        rep.fail("live: the site differs from origin/main (Pages may still"
                 " be deploying)")
    return True


def pages(root, found):
    """Every HTML page styled by brand.css, directly or through its CSS."""
    styled = {f.resolve() for refs in found.values() for f, _, _ in refs}
    out = []
    for repo in found:
        if builds_copy(repo):
            continue
        for f in walk(repo):
            if f.suffix != ".html":
                continue
            text = f.read_text(errors="replace")
            links = {resolve(root, f, u) for u in LINK.findall(text)}
            if f.resolve() in styled or links & styled:
                out.append((f, any(
                    "@page" in p.read_text(errors="replace")
                    for p in links if p.exists())))
    return sorted(out)


def mirror(root, brand_text, dest):
    """The site as it is served, made of symlinks, with brand.css replaced:
    the hub's files at the top and every other repo at /<repo>/."""
    for p in (root / HUB).iterdir():
        if p.name not in ("brand.css", ".git"):
            (dest / p.name).symlink_to(p)
    for p in root.iterdir():
        if p.is_dir() and p.name != HUB and not p.name.startswith("."):
            (dest / p.name).symlink_to(p)
    (dest / "brand.css").write_text(brand_text)


def url_path(root, page):
    """The path the site serves a file of ROOT at."""
    rel = page.relative_to(root)
    if rel.parts[0] == HUB:
        rel = rel.relative_to(HUB)
    return "/" + rel.as_posix()


@contextlib.contextmanager
def serve(directory):
    """A local web server over directory, so a page's root-relative links
    (style.html's frames of /) reach the mirror, not the filesystem."""
    handler = functools.partial(QuietHandler, directory=str(directory))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def chrome(*args):
    # Reduced motion: brand.css then stops every animation, so a render
    # is the same each time instead of catching a pulse mid-beat.
    subprocess.run(["google-chrome", "--headless", "--hide-scrollbars",
                    "--force-prefers-reduced-motion",
                    "--virtual-time-budget=3000", *args],
                   capture_output=True, timeout=60)


def differing(a, b):
    r = subprocess.run(["compare", "-metric", "AE", str(a), str(b),
                        "null:"], capture_output=True, text=True)
    return float(r.stderr.split()[0])


def render_diff(root, hub, rev, rep):
    for tool in ("google-chrome", "compare", "pdfinfo", "pdftoppm"):
        if not shutil.which(tool):
            rep.fail(f"diff: {tool} is not installed, so --diff did not run")
            return
    old_text = git(hub, "show", f"{rev}:brand.css").decode()
    found = consumers(root)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        trees = {"old": tmp / "old", "new": tmp / "new"}
        for name, text in (("old", old_text),
                           ("new", (root / HUB / "brand.css").read_text())):
            trees[name].mkdir()
            mirror(root, text, trees[name])
        print(f"== diff: brand.css at {rev} against the working file ==")
        with serve(trees["old"]) as old, serve(trees["new"]) as new:
            sites = {"old": old, "new": new}
            for page, is_doc in pages(root, found):
                render_page(root, page, is_doc, sites, tmp)


def render_page(root, page, is_doc, sites, tmp):
    """Print what the new brand.css changes on one page."""
    rel = page.relative_to(root)
    path = url_path(root, page)
    for theme in ("light", "dark"):
        flags = ["--force-dark-mode"] if theme == "dark" else []
        shots = {"old": [], "new": []}
        for name, site in sites.items():
            for i in range(RENDERS):
                shots[name].append(tmp / f"{name}{i}.png")
                chrome(*flags, "--window-size=1200,1600",
                       f"--screenshot={shots[name][-1]}", site + path)
        change = min(differing(o, n)
                     for o in shots["old"] for n in shots["new"])
        noise = max(differing(a, b) for a, b in
                    itertools.combinations(shots["new"], 2))
        print(f"  {rel} {theme}: {change:g} differing pixels"
              f" (its own renders vary by up to {noise:g})")
    if is_doc:
        pdfs = {}
        for name, site in sites.items():
            pdfs[name] = tmp / f"{name}.pdf"
            chrome("--no-pdf-header-footer",
                   f"--print-to-pdf={pdfs[name]}", site + path)
        counts = [re.search(rb"Pages:\s+(\d+)", subprocess.run(
            ["pdfinfo", str(p)], capture_output=True).stdout)
            .group(1).decode() for p in pdfs.values()]
        pngs = []
        for name, p in pdfs.items():
            subprocess.run(["pdftoppm", "-r", "60", "-png", "-f",
                            "1", "-l", "1", "-singlefile", str(p),
                            str(tmp / f"{name}-pdf")])
            pngs.append(tmp / f"{name}-pdf.png")
        print(f"  {rel} printed: pages {counts[0]} -> {counts[1]},"
              f" {differing(*pngs):g} differing pixels on page 1")


def run(root, offline, rev):
    rep = Report()
    hub = root / HUB
    brand = (hub / "brand.css").resolve()
    print(f"== brand_check: {root} ==")
    link = root / "brand.css"
    if link.is_symlink() and link.resolve() == brand:
        rep.ok("link: ROOT/brand.css is a symlink to the hub's file")
    else:
        rep.fail(f"link: {link} is not a symlink to {brand}")
    check_contrast(brand.read_text(), rep)
    found = consumers(root)
    check_imports(root, brand, found, rep)
    check_themes(root, found, rep)
    check_copies(root, brand, found, rep)
    answered = True if offline else check_live(hub, rep)
    if rev:
        render_diff(root, hub, rev, rep)
    head = git(hub, "log", "-1", "--format=%h", "--", "brand.css")
    print(f"  the Trust Loop's copy must name commit {head.decode().strip()}"
          " (read_artifact)")
    if rep.failed:
        return 1
    return 0 if answered else 75


def self_test():
    st = 0

    def expect(cond, msg):
        nonlocal st
        print(f"  {'ok  ' if cond else 'FAIL'} {msg}")
        st |= not cond

    good = (":root {\n  --bg: light-dark(#ffffff, #0a0a0a);"
            " --ink: light-dark(#666666, #f2f2f2); --title: #cc6633;\n"
            "  --hair: #cccccc; --sans: Arial;\n}\nbody { color: red }\n")
    rep = Report(quiet=True)
    check_contrast(good, rep)
    expect(not rep.failed, "a passing palette passes")
    expect(tokens(good)["--ink"] == ("#666666", "#f2f2f2")
           and tokens(good)["--title"] == ("#cc6633", "#cc6633"),
           "light-dark() and plain tokens both parse")
    rep = Report(quiet=True)
    check_contrast(good.replace("#666666", "#bbbbbb"), rep)
    expect(rep.failed, "a text colour under 4.5:1 fails")
    rep = Report(quiet=True)
    check_contrast(good.replace("--hair", "--new"), rep)
    expect(rep.failed, "a colour token with no role fails")
    expect(f"{ratio('#cc6633', '#ffffff'):.2f}" == "3.81",
           "ratio matches the published 3.81:1 for the title")

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        hub = root / HUB
        hub.mkdir()
        (hub / "brand.css").write_text(good)
        (root / "brand.css").symlink_to(hub / "brand.css")
        proj = root / "proj" / "demo"
        proj.mkdir(parents=True)
        (proj / "a.css").write_text('@import url("../../brand.css");\n')
        (proj / "p.html").write_text('<link rel="stylesheet" href="a.css">')
        (hub / "index.html").write_text('<link href="brand.css">')
        brand = (hub / "brand.css").resolve()
        found = consumers(root)
        rep = Report(quiet=True)
        check_imports(root, brand, found, rep)
        check_themes(root, found, rep)
        expect(not rep.failed, "a correct relative import passes")
        expect([p.name for p, _ in pages(root, found)]
               == ["index.html", "p.html"],
               "pages finds a direct link and one through a project CSS")
        (proj / "b.css").write_text('@import url("../brand.css");\n')
        rep = Report(quiet=True)
        check_imports(root, brand, consumers(root), rep)
        expect(rep.failed, "an import that misses the hub's file fails")
        (proj / "b.css").write_text("@media (prefers-color-scheme: dark)"
                                    " { :root { --x: #000 } }\n")
        rep = Report(quiet=True)
        check_themes(root, consumers(root), rep)
        expect(rep.failed, "a consumer with prefers-color-scheme fails")
        ext = root / "ext"
        (ext / "static").mkdir(parents=True)
        (ext / "dist").mkdir()
        (ext / "package.json").write_text('"build": "cp ../brand.css dist/"')
        (ext / "static" / "p.html").write_text('<link href="brand.css">')
        (ext / "dist" / "brand.css").write_text("old")
        found = consumers(root)
        rep = Report(quiet=True)
        check_imports(root, brand, {ext: found[ext]}, rep)
        expect(not rep.failed, "a repo that builds a copy may link it bare")
        rep = Report(quiet=True)
        check_copies(root, brand, found, rep)
        expect(rep.failed, "a stale built copy fails")
        dest = root.parent / (root.name + "-mirror")
        dest.mkdir()
        try:
            mirror(root, "OLD", dest)
            expect((dest / "brand.css").read_text() == "OLD"
                   and (dest / "index.html").resolve()
                   == (hub / "index.html")
                   and (dest / "proj").resolve() == (root / "proj")
                   and not (dest / HUB).exists(),
                   "the mirror is the site: hub at the top, repos below,"
                   " brand.css swapped")
            expect(url_path(root, hub / "index.html") == "/index.html"
                   and url_path(root, proj / "p.html")
                   == "/proj/demo/p.html",
                   "a file's site path drops the hub's folder name")
            with serve(dest) as site:
                with urllib.request.urlopen(site + "/proj/demo/a.css") as r:
                    expect(b"brand.css" in r.read(),
                           "the server reaches a repo through its symlink")
        finally:
            shutil.rmtree(dest)
    print(f"brand_check self-test: {'FAIL' if st else 'PASS'}")
    return st


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default="~/src/oceanhue")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--diff", metavar="REV")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    root = pathlib.Path(args.root).expanduser()
    return run(root, args.offline, args.diff)


if __name__ == "__main__":
    sys.exit(main())

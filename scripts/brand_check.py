#!/usr/bin/env python3
"""Check brand.css, the base style, against every page and document using it.

    brand_check.py [--root DIR] [--offline] [--diff REV]
    brand_check.py --self-test

ROOT (default ~/src/oceanhue) mirrors https://iguigova.github.io: the hub
repo, iguigova.github.io, is the site root and holds brand.css, every other
repo is /<repo>/, and ROOT/brand.css is a symlink to the hub's file, as
ROOT/brand.js, the theme switch beside it, is to its own. Run it
after every change to brand.css, or to a project's theme colours.

Checks, each printing `ok` or `FAIL <what>`:

  link      ROOT/brand.css and ROOT/brand.js are symlinks to the hub's files
  contrast  every colour token meets its WCAG AA ratio against --bg in both
            themes: text 4.5:1, large titles and rules 3:1; a colour token
            this script has no role for fails, so none goes unchecked
  imports   every reference to brand.css in a repo's CSS or HTML resolves
            to the hub's file, or sits in a repo whose build copies
            ../brand.css (boca)
  themes    no consumer repo's CSS or HTML uses prefers-color-scheme: a
            project colour is light-dark(light, dark), so it follows the
            color-scheme brand.css sets, data-theme included
  switch    every page but a printed document loads brand.js: a page by a
            path resolving to the hub's file, a page in a repo whose build
            copies it by its bare name
  copies    every built copy (dist/brand.css, dist/brand.js) equals the
            hub's file
  live      the site serves origin/main's brand.css (skipped by --offline)

--diff REV also renders every consumer page as committed (the hub at REV,
every other repo at its HEAD) and as it is in the working trees, in light and
dark, and prints the differing pixels of each, so an uncommitted change to
brand.css or to a project's own CSS shows; a page whose CSS sets @page is a
document and is printed too, with its page count. A page with no committed
copy, such as a built document, is its working file on both sides.
Every page is rendered three times from each file, over a local server laid
out like the site, and the closest old and new pair is reported: headless
Chrome now and then renders a page in a second state, and a real change
differs in every pair. Beside it is how far the new file's own renders vary.
A refactor shows 0 everywhere; an intended change shows where it lands.
Differences are reported, never failed. A page in a repo whose build copies
brand.css is not rendered: its copy is what `copies` checks.

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

from tap import Tap

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
SCRIPT = re.compile(r"""<script[^>]*\ssrc=["']([^"']*brand\.js)["']""")
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


def check_switch(root, found, rep):
    js = (root / HUB / "brand.js").resolve()
    want = [(f, False) for f, is_doc in pages(root, found) if not is_doc]
    want += [(f, True) for f in built(root, found)]
    bad = []
    for f, copied in sorted(set(want)):
        srcs = SCRIPT.findall(f.read_text(errors="replace"))
        if not any(s == "brand.js" if copied else resolve(root, f, s) == js
                   for s in srcs):
            bad.append(f)
            rep.fail(f"switch: {f.relative_to(root)} does not load brand.js")
    if not bad:
        rep.ok(f"switch: {len(set(want))} pages load brand.js")


def check_copies(root, brand, found, rep):
    for repo in found:
        if not builds_copy(repo):
            continue
        for src in (brand, brand.with_name("brand.js")):
            copy = repo / "dist" / src.name
            if not copy.exists():
                continue
            if copy.read_bytes() == src.read_bytes():
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


def built(root, found):
    """Every HTML page a build copies with brand.css: in a repo whose build
    copies it, a page whose link misses the hub's file."""
    brand = (root / HUB / "brand.css").resolve()
    return sorted({f for repo, refs in found.items() if builds_copy(repo)
                   for f, _, target in refs
                   if f.suffix == ".html" and target != brand})


def pages(root, found):
    """Every HTML page styled by brand.css, directly or through its CSS; in
    a repo whose build copies it, a page linking the hub's file directly."""
    brand = (root / HUB / "brand.css").resolve()
    styled = {f.resolve() for refs in found.values() for f, _, _ in refs}
    out = []
    for repo, refs in found.items():
        if builds_copy(repo):
            out += [(f, False) for f, _, target in refs
                    if f.suffix == ".html" and target == brand]
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


def repos(root):
    """Every repo of ROOT but the hub."""
    return [p for p in sorted(root.iterdir()) if p.is_dir()
            and p.name != HUB and not p.name.startswith(".")]


def mirror(root, dest):
    """The site as the working trees serve it, made of symlinks: the hub's
    files at the top and every other repo at /<repo>/."""
    for p in (root / HUB).iterdir():
        if p.name != ".git":
            (dest / p.name).symlink_to(p)
    for p in repos(root):
        (dest / p.name).symlink_to(p)


def archive(repo, ref, dest):
    dest.mkdir(exist_ok=True)
    tar = subprocess.run(["git", "-C", str(repo), "archive", ref],
                         capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", str(dest)], input=tar, check=True)


def snapshot(root, rev, dest):
    """The site as committed: the hub at REV and every other repo at its
    HEAD. A folder that is no repo is the same on both sides."""
    archive(root / HUB, rev, dest)
    for p in repos(root):
        if (p / ".git").exists():
            archive(p, "HEAD", dest / p.name)
        else:
            (dest / p.name).symlink_to(p)


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


def render_diff(root, rev, rep):
    for tool in ("google-chrome", "compare", "pdfinfo", "pdftoppm"):
        if not shutil.which(tool):
            rep.fail(f"diff: {tool} is not installed, so --diff did not run")
            return
    found = consumers(root)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        old, new = tmp / "old", tmp / "new"
        snapshot(root, rev, old)
        new.mkdir()
        mirror(root, new)
        print(f"== diff: the hub at {rev} and every repo at HEAD,"
              " against the working trees ==")
        found_pages = pages(root, found)
        for page, _ in found_pages:
            uncommitted(root, page, old)
        with serve(old) as old_site, serve(new) as new_site:
            sites = {"old": old_site, "new": new_site}
            for page, is_doc in found_pages:
                render_page(root, page, is_doc, sites, tmp)


def uncommitted(root, page, old):
    """A page with no committed copy, such as a built document, is its
    working file on both sides, so only the styles around it differ."""
    dest = old / url_path(root, page).lstrip("/")
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(page, dest)


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
    for name in ("brand.css", "brand.js"):
        link, want = root / name, (hub / name).resolve()
        if link.is_symlink() and link.resolve() == want:
            rep.ok(f"link: ROOT/{name} is a symlink to the hub's file")
        else:
            rep.fail(f"link: {link} is not a symlink to {want}")
    check_contrast(brand.read_text(), rep)
    found = consumers(root)
    check_imports(root, brand, found, rep)
    check_themes(root, found, rep)
    check_switch(root, found, rep)
    check_copies(root, brand, found, rep)
    answered = True if offline else check_live(hub, rep)
    if rev:
        render_diff(root, rev, rep)
    if rep.failed:
        return 1
    return 0 if answered else 75


def self_test():
    t = Tap()

    def expect(cond, msg):
        t.check(bool(cond), msg)

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
        (hub / "brand.js").write_text("switch")
        (root / "brand.js").symlink_to(hub / "brand.js")
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
        rep = Report(quiet=True)
        check_switch(root, found, rep)
        expect(rep.failed, "a page that does not load brand.js fails")
        (hub / "index.html").write_text(
            '<link href="brand.css"><script src="brand.js"></script>')
        (proj / "p.html").write_text(
            '<link rel="stylesheet" href="a.css">'
            '<script src="../brand.js"></script>')
        rep = Report(quiet=True)
        check_switch(root, found, rep)
        expect(rep.failed, "a brand.js path that misses the hub's file fails")
        (proj / "p.html").write_text(
            '<link rel="stylesheet" href="a.css">'
            '<script src="../../brand.js"></script>')
        (proj / "a.css").write_text(
            '@import url("../../brand.css");\n@page { size: A4 }\n')
        (proj / "d.html").write_text('<link rel="stylesheet" href="a.css">')
        rep = Report(quiet=True)
        check_switch(root, consumers(root), rep)
        expect(not rep.failed, "pages load the hub's brand.js; a printed"
               " document need not")
        (proj / "d.html").unlink()
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
        (ext / "static" / "p.html").write_text(
            '<link href="brand.css"><script src="brand.js"></script>')
        (ext / "dist" / "brand.css").write_text(good)
        (ext / "dist" / "brand.js").write_text("old")
        found = consumers(root)
        rep = Report(quiet=True)
        check_imports(root, brand, {ext: found[ext]}, rep)
        check_switch(root, {ext: found[ext]}, rep)
        expect(not rep.failed, "a repo that builds a copy may link it bare")
        (ext / "index.html").write_text(
            '<link href="../brand.css"><script src="brand.js"></script>')
        found = consumers(root)
        rep = Report(quiet=True)
        check_switch(root, {ext: found[ext]}, rep)
        expect(rep.failed and [p.name for p, _ in pages(root, {ext: found[ext]})]
               == ["index.html"], "a page beside a build that links the hub's"
               " brand.css is a page, and loads the hub's brand.js")
        (ext / "index.html").write_text(
            '<link href="../brand.css"><script src="../brand.js"></script>')
        rep = Report(quiet=True)
        check_switch(root, {ext: consumers(root)[ext]}, rep)
        expect(not rep.failed, "so it passes when it loads ../brand.js")
        (ext / "index.html").unlink()
        found = consumers(root)
        rep = Report(quiet=True)
        check_copies(root, brand, found, rep)
        expect(rep.failed, "a stale built copy of brand.js fails")
        dest = root.parent / (root.name + "-mirror")
        dest.mkdir()
        snap = root.parent / (root.name + "-snapshot")
        try:
            mirror(root, dest)
            expect((dest / "brand.css").resolve() == brand
                   and (dest / "index.html").resolve()
                   == (hub / "index.html")
                   and (dest / "proj").resolve() == (root / "proj")
                   and not (dest / HUB).exists(),
                   "the mirror is the site: hub at the top, repos below")
            for repo in (hub, root / "proj"):
                g = ["git", "-C", str(repo), "-c", "user.name=t",
                     "-c", "user.email=t@example.com"]
                subprocess.run([*g, "init", "-q"], check=True)
                subprocess.run([*g, "add", "-A"], check=True)
                subprocess.run([*g, "commit", "-qm", "one"], check=True)
            (hub / "brand.css").write_text("NEW")
            (proj / "a.css").write_text("NEW")
            snapshot(root, "HEAD", snap)
            expect((snap / "brand.css").read_text() == good
                   and (snap / "proj" / "demo" / "a.css").read_text()
                   .startswith("@import")
                   and (snap / "ext").resolve() == ext,
                   "the snapshot is every repo as committed, and a folder"
                   " that is no repo as it is")
            built = proj / "built.html"
            built.write_text("BUILT")
            uncommitted(root, built, snap)
            (proj / "p.html").write_text("CHANGED")
            uncommitted(root, proj / "p.html", snap)
            expect((snap / "proj" / "demo" / "built.html").read_text()
                   == "BUILT"
                   and "a.css" in (snap / "proj" / "demo" / "p.html")
                   .read_text(),
                   "a page with no committed copy is its working file on"
                   " both sides, and a committed one stays as committed")
            expect(url_path(root, hub / "index.html") == "/index.html"
                   and url_path(root, proj / "p.html")
                   == "/proj/demo/p.html",
                   "a file's site path drops the hub's folder name")
            with serve(dest) as site:
                with urllib.request.urlopen(site + "/proj/demo/a.css") as r:
                    expect(r.read() == b"NEW",
                           "the server reaches a repo's working tree"
                           " through its symlink")
        finally:
            shutil.rmtree(dest)
            shutil.rmtree(snap, ignore_errors=True)
    return t.end()


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

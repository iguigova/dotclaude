#!/usr/bin/env python3
"""Inventory of everything you authored under .claude/: facts only.

An item is a regular file you wrote (a symlink is someone else's file and
is skipped), in one of six kinds:

  skill     skills/<name>/SKILL.md, global and project
  command   commands/<name>.md, global and project
  script    scripts/ and helpers/, .sh and .py
  rules     CLAUDE.md, the credo, the *_guidelines.md documents, a
            tooling README
  settings  settings.json and settings.local.json
  memory    the project's memory fact files

Machine state -- cache, sessions, logs, history -- is not authored and is
not an item.

Every field is measured; nothing is judged:
  identity   scope, kind, path, description, lines
  usage      runs, sessions, typed, loaded, first/last run, runs per month
             -- a skill or command by attribution, a script by the Bash
             calls that run it
  cost       list-price dollars: total, median run, the share spent in
             subagents and in late runs; growth in tokens -- skills and
             commands only
  upkeep     commits, first commit, last edit, edits in 90 days,
             uncommitted -- a script's bundled files included
  integrity  scripts named in the body (exist, offer --self-test),
             bundled files (a skill's beside SKILL.md; the files beside a
             script that are no script and that it names, such as
             inventory_kinds.txt), the other items that name this script,
             journal entries via it
  restates   the sentences said again in another sentence -- skills and
             commands only
  notes      the notes whose text names it -- each open, placed, drained,
             or with no id -- and the notes placed into it; shown only in
             the one-item report

The census is a row for each fact with a remedy -- an untracked or
uncommitted file, a missing script, a script with no --self-test, a script
nothing names and nothing has run, a probe hit, an item that restates, a
run's messages with no list price -- then one table, a row per item: runs per month, runs, last run, the
cost columns, commits, last edit, how many items name a script, and what the
item is. The table holds every item there is, or one kind under --kind. A
column no row fills is left out. The rest of the
measurement -- sessions, typed and loaded counts, upkeep beyond commits and
last edit, the scripts an item names, bundled files, journal facts -- is in
the one-item report and --json. The census's --json carries the attention
rows too, as attention: [problem, item, detail] apiece, so a reader of the
JSON states the same rows the text view does.

A cost is a run's messages priced one at a time from PRICES at the model's
list price, its subagents' messages added in. Growth is the median, over runs,
of the largest context a run reached less the context it started with: how
much a procedure pulls into the conversation. The late share is the part of
the dollars spent in runs that started with more than LATE_ENTRY tokens
already in context, where every turn re-reads that context. A message whose
price is not known -- a model PRICES lacks, fast mode, US-only inference --
is counted as unpriced and reported, because leaving it out understates the
dollars. List prices are not an invoice: a discount is invisible here.

Neither view lists notes. The queue has one reader, journal_queue.sh, and
/notes is where it is worked; a census that repeated it would be a second view
of the same queue. The one-item report lists the item's notes, because an
open note naming an item is a known defect in it and the audit is handed it.

A note is open while journal_queue.sh lists it: the queue holds open work, so
the absence of a close does not make a note open.

The header counts the closes that placed a note into the tooling: into an
item here, into a kind and no item in it, and into an item that is gone, each
gone one named. A close counts toward an item's report only when it names that
item, so the other two would otherwise be missing without a word.

A script's own source is not read for references or probes: a path-shaped
string in code may be a usage example or a fixture rather than a call. So
`named by` counts the other items whose text contains the file name -- which
a script calling another script does, whatever spelling it uses -- and a
script named by nothing is named by nothing anywhere in the tree. A reference
ends at a colon, so a cited line `tool.py:417` names tool.py, and one followed
by a glob character names a pattern and no script.

A description is the frontmatter `description` for a markdown item, the
first docstring line for a .py, and the leading comment block for a .sh.
A settings file has none. The census shows it as a blurb, its first
BLURB_CHARS characters; the one-item report shows it whole.

Journal facts match the slash form `/name` for a skill or command, because
bare names such as `journal` or `dev` are ordinary words; for every other
kind they match the file name. They count the whole journal, because a via
count and a note are lifetime facts, and the reader returns every entry. An
item's notes are the ones whose text names it. The entry a note was written in
does not attribute it: a run of /qa notices the product under test, so a note
written via /qa is about /qa only when it says so.

Usage and cost come from the project's transcripts. A run is a stretch of
consecutive assistant messages that carry the same attributionSkill, and a
typed invocation of the command ends the stretch before it, so typing it
twice is two runs. Runs exist only from the day the harness began writing
that field. The report states that day as `attribution_since`, and typed and
loaded counts use the same window so they compare with runs.

A script run is a Bash call that runs or sources the file, in the project's
transcripts and their subagents', counted in the same window. Each command
position of the call is read -- the first word of every segment between `;`,
`&&`, `||`, `|`, `&`, `$(`, a parenthesis, a brace or a newline -- past
assignments, flags, and words that only launch what follows (bash, python3,
timeout, source, ...). A heredoc body is data and is skipped, and a `cd` in the
call moves the directory a relative path resolves against. The word must end
in .sh or .py, and it counts for the item at that resolved path, so a `cat` or
a `grep` of a script is no run and the two selftest.sh are told apart. A call
asking for --self-test or --help tests or reads the script, so it is no run. A
script nothing names is flagged as unused only when it has no run either:
something a person runs by hand is named by nothing and still used.

A script is tested when it offers `--self-test`. Both gates sweep for
the flag and keep no list, so offering it is being covered from the moment
the script lands, and a script with no flag is untested even where a
bespoke check in the gate exercises it -- the flag is the convention both
gates state, and giving the script one is the fix.

Given a name, the report is that one item's facts instead of the
census. Two items can share a name -- there are two selftest.sh and two
CLAUDE.md -- and then the report lists the candidates and says to ask
which one is meant; --scope global|project answers that, and is refused
without a name, where it would pick nothing. Every item is measured either
way, because one transcript pass serves all of them.

--kind keeps one of the six kinds and drops the rest. It narrows the
finished report, never the measurement: `named by` counts the items of every
kind whose text names a script, so a report of scripts alone still names the
skill that calls one. The report states the kind it holds, because a report
of one kind must not read as a census of the tree.

Two probes report a defect that has a right answer. A bash block using a
variable it never sets expands it to empty, because each block runs in its
own shell. A fixed /tmp path is shared between sessions and survives none.
Both read only a document's bash blocks, the steps a reader runs: a path
the prose or a table describes is a fact about something else. The block is read as bash reads it: continued lines are one command, nothing
in single quotes, a comment or a quoted-delimiter heredoc is a use, and an
assignment sets a variable only when no command follows it (`X=1 cmd` is
that command's environment). A file the block sources is read for what it
sets, resolved against the document's own directory and one level deep. Both
probes still match benign cases -- a source whose path is built from a
variable, a block continuing the one before, a /tmp path a block's comment
describes -- so the probe reports and the reader judges.

A sentence restates when RESTATE_SHARE or more of its words appear in one
other sentence: of a skill, a command, a rules file, a script's header, or
elsewhere in the same file. Its words are those of three letters or more, less
a short FILLER list, and a sentence with fewer than RESTATE_WORDS of them is too
short to judge. What is read is what a reader reads as instructions -- a
markdown file less its code blocks, a .py's docstring, a .sh's leading comment
block. A sentence said twice is one that drifts when only one copy is edited,
and one that only repeats a script's header changes nothing a model does. It
is still a probe: words shared are not meaning shared, a summary a skill needs
in hand can look the same, and a paraphrase shares too few words to be found
-- so the probe reports and the audit judges.

The /inventory argument-hint is this grammar written as text, so the
self-test checks that it names exactly the name, flags and choices the parser
has: nothing missing, nothing extra.

Usage:
  skill_inventory.py [NAME [--scope global|project]] [--kind KIND]
                     [--project DIR] [--json]
  skill_inventory.py --self-test
"""

from __future__ import annotations

import argparse
import ast
import datetime as dt
import json
import os
import re
import shlex
import statistics
import subprocess
import sys

import yaml
import tempfile
import textwrap
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
HOME = Path.home() / ".claude"
COMMAND = SCRIPTS.parent / "commands/inventory.md"
TOKEN_FIELDS = (
    "input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
)
# List prices in USD per million tokens: base input, 5-minute cache write,
# 1-hour cache write, cache read, output. Read 2026-10-19 from
# https://platform.claude.com/docs/en/about-claude/pricing; a model missing
# here is reported as unpriced rather than guessed.
PRICES_READ = "2026-10-19"
PRICES = {
    "opus-5-5": (4, 5, 8, 0.20, 20),
    "opus-5": (5, 6.25, 10, 0.50, 25),
    "opus-4-8": (5, 6.25, 10, 0.50, 25),
    "opus-4-7": (5, 6.25, 10, 0.50, 25),
    "opus-4-6": (5, 6.25, 10, 0.50, 25),
    "sonnet-5": (2, 2.50, 4, 0.20, 10),
    "sonnet-4-6": (3, 3.75, 6, 0.30, 15),
    "fable-5": (10, 12.50, 20, 1, 50),
    "haiku-4-5": (1, 1.25, 2, 0.10, 5),
    "haiku-5-5": (0.10, 0.125, 0.20, 0.01, 0.50),
}
# Haiku 5.5 charges more for a request whose prompt -- input, cache writes and
# cache reads together -- is over this many tokens.
LONG_PROMPT = {"haiku-5-5": (100_000, (0.50, 0.625, 1, 0.05, 2.50))}
LATE_ENTRY = 200_000
RECENT_DAYS = 90
BLURB_CHARS = 40
NOTE_ORDER = ("open", "no id", "drained", "placed")
NAMERS_SHOWN = 3
UNTRACKED = {"ignored": "ignored by git: no history and no backup",
             "no repo": "in no git repository: no history and no backup"}
AGENT_TOOLS = frozenset({"Agent", "Task"})
PROCEDURE = frozenset({"skill", "command"})
# Read, not restated: journal.sh accepts the same list as the exits a note can
# take, and a copy here would be a second source of truth.
KINDS = tuple(ln for ln in (SCRIPTS / "inventory_kinds.txt").read_text().splitlines()
              if ln and not ln.startswith("#"))
SCRIPT_SUFFIX = frozenset({".sh", ".py"})
FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
FM_LINE = re.compile(r"^([A-Za-z_-]+):\s*(.*)$")
TYPED = re.compile(r"<command-name>/([\w:-]+)</command-name>")
# A name stops at a colon, so `tool.py:417` -- a line cited in prose -- names
# tool.py; a name followed by a glob character is a pattern, not a script.
SCRIPT_REF = re.compile(r"(\S*?)\.claude/(scripts|helpers)/([\w.-]+)(?![\w.*?\[-])")
NUMERIC = re.compile(r"^[-\d.,]+$")
COMMENT = re.compile(r"^#(?!!)\s?(.*)$")
BASH_FENCE = re.compile(r"```bash\n(.*?)```", re.S)
HINT_CHOICES = re.compile(r"\w+(?:\|\w+)+")
HINT_FLAG = re.compile(r"--[\w-]+")
HINT_NAME = re.compile(r"\b[a-z]\w*\b")
VAR_USE = re.compile(r"\$\{?([A-Za-z_]\w*)\}?(?![:\w])")
# A command substitution is part of the path, so `/tmp/x-$(id -u)` is read whole.
# A `}` outside an expansion closes the `${VAR:-/tmp/x}` the path is the default
# of, so it ends the path.
TMP_PATH = re.compile(
    r"(?<![\w/])/tmp/(?:\$\([^)]*\)|\$\{[^}]*\}|[^\s\"'`}])*")
SHELL_ENV = frozenset({"HOME", "PWD", "OLDPWD", "USER", "PATH", "SHELL",
                       "TMPDIR", "IFS", "RANDOM", "ARGUMENTS"})
DOCLINE = re.compile(r'^"""(.+)$', re.M)
RESTATE_SHARE = 0.7
RESTATE_WORDS = 8
PROSE_FENCE = re.compile(r"^[ \t]*```.*?^[ \t]*```", re.S | re.M)
PROSE_BREAK = re.compile(
    r"(?<=[.!?])\s+(?=[A-Z*`(])|\n\s*\n|\n(?=\s*(?:[-*|]|\d+\.)\s)")
PROSE_WORD = re.compile(r"[a-z][a-z0-9_:-]{2,}")
DOCSTRING = re.compile(r'"""(.*?)"""', re.S)
FILLER = frozenset("""the and for are this that with from not when what which
who each every one only than then there their they them was were has have had
but any all can its""".split())
HOME_PREFIXES =("~/", "$HOME/", f"{Path.home()}/")


# ---------------------------------------------------------------- discovery

def find_project(start: Path) -> Path:
    for d in (start, *start.parents):
        if (d / ".claude").is_dir() and d != Path.home():
            return d
    sys.exit(f"skill_inventory: no .claude/ at or above {start}")


def transcripts_for(home: Path, project: Path) -> Path:
    return home / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(project))


def owned(path: Path) -> bool:
    return path.exists() and not path.is_symlink()


def skills_in(base: Path, scope: str) -> list[dict]:
    dirs = sorted(base.glob("skills/*/SKILL.md"))
    return [item(p.parent.name, scope, "skill", p, p.parent)
            for p in dirs if owned(p.parent) and owned(p)]


def commands_in(base: Path, scope: str) -> list[dict]:
    files = sorted(base.glob("commands/*.md"))
    return [item(p.stem, scope, "command", p, p)
            for p in files if owned(p)]


def files_in(base: Path, scope: str, kind: str,
             globs: tuple[str, ...]) -> list[dict]:
    found = sorted(p for g in globs for p in base.glob(g))
    return [item(p.name, scope, kind, p, p) for p in found
            if p.is_file() and owned(p)]


def scripts_in(base: Path, scope: str) -> list[dict]:
    found = files_in(base, scope, "script", ("scripts/*", "helpers/*"))
    return [i for i in found if Path(i["path"]).suffix in SCRIPT_SUFFIX]


def rules_in(base: Path, scope: str) -> list[dict]:
    return files_in(base, scope, "rules",
                    ("CLAUDE.md", "credo.md", "*_guidelines.md"))


def readmes_in(base: Path, scope: str) -> list[dict]:
    return files_in(base, scope, "rules", ("*/README.md",))


def settings_in(base: Path, scope: str) -> list[dict]:
    return files_in(base, scope, "settings", ("settings*.json",))


def memory_in(transcripts: Path) -> list[dict]:
    return files_in(transcripts / "memory", "project", "memory",
                    ("*.md",))


def item(name, scope, kind, entry, root) -> dict:
    return {"name": name, "scope": scope, "kind": kind,
            "path": str(entry), "root": str(root)}


def discover(home: Path, project: Path, transcripts: Path) -> list[dict]:
    pc = project / ".claude"
    return (skills_in(pc, "project") + commands_in(pc, "project")
            + scripts_in(pc, "project") + settings_in(pc, "project")
            + rules_in(project, "project") + readmes_in(pc, "project")
            + memory_in(transcripts)
            + skills_in(home, "global") + commands_in(home, "global")
            + scripts_in(home, "global") + settings_in(home, "global")
            + rules_in(home, "global"))


# ----------------------------------------------------------------- identity

def scalar(raw: str) -> str:
    """A quoted YAML scalar's text, or the raw line when it is not one.

    The reader stays lenient — a value that will not parse comes back as written,
    so a malformed block is still described rather than dropped — but a value that
    IS a quoted scalar is unquoted, which a line regex alone cannot do. Without
    this a description reads back with its quotes and its doubled apostrophes,
    and its length, which is the routing-surface measure, counts them.
    """
    try:
        value = yaml.safe_load(raw)
    except yaml.YAMLError:
        return raw
    return value if isinstance(value, str) else raw


def frontmatter(text: str) -> dict:
    m = FRONTMATTER.match(text)
    lines = m.group(1).splitlines() if m else []
    return {k: scalar(v) for k, v in (FM_LINE.match(ln).groups()
                                      for ln in lines if FM_LINE.match(ln))}


def body_of(text: str) -> str:
    return FRONTMATTER.sub("", text, count=1)


def first_line(text: str) -> str:
    lines = (ln.strip().lstrip("#").strip() for ln in text.splitlines())
    return next((ln for ln in lines if ln), "")


def docstring_line(text: str) -> str:
    m = DOCLINE.search(text)
    return m.group(1).strip().rstrip('"') if m else ""


def comment_block(text: str) -> str:
    lines = []
    for ln in text.splitlines():
        if ln.startswith("#!"):
            continue
        m = COMMENT.match(ln)
        if not m or not m.group(1).strip():
            break
        lines.append(m.group(1).strip())
    return " ".join(lines)


def description(suffix: str, text: str) -> str:
    if suffix == ".py":
        return docstring_line(text)
    if suffix == ".sh":
        return comment_block(text)
    if suffix == ".json":
        return ""
    return frontmatter(text).get("description") or first_line(body_of(text))


def identity(it: dict) -> dict:
    text = Path(it["path"]).read_text(encoding="utf-8", errors="replace")
    desc = description(Path(it["path"]).suffix, text)
    return {"description": desc, "desc_chars": len(desc),
            "lines": text.count("\n")}


# -------------------------------------------------------------- transcripts

def records(path: Path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def context(usage: dict) -> int:
    return sum(usage.get(k) or 0 for k in TOKEN_FIELDS)


def total(usage: dict) -> int:
    return context(usage) + (usage.get("output_tokens") or 0)


def blocks(rec: dict) -> list:
    content = (rec.get("message") or {}).get("content")
    return content if isinstance(content, list) else []


def text_of(rec: dict) -> str:
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in blocks(rec)
                    if isinstance(b, dict) and b.get("type") == "text")


def model_key(model: str) -> str:
    """The PRICES key of a model id: `claude-opus-5[1m]` and
    `claude-haiku-4-5-20251001` are priced as opus-5 and haiku-4-5."""
    return re.sub(r"^claude-|\[\w+\]$|-\d{8}$", "", model or "")


def dollars(model: str, usage: dict) -> float | None:
    """One message's list price, or None when the price is not known: a model
    PRICES lacks, fast mode, US-only inference, or cache writes with no
    5-minute/1-hour split. None is counted, never read as zero."""
    if not total(usage):
        return 0.0
    key = model_key(model)
    rates = PRICES.get(key)
    split = usage.get("cache_creation")
    writes = usage.get("cache_creation_input_tokens") or 0
    if (rates is None or usage.get("speed") not in (None, "standard")
            or usage.get("inference_geo") == "us"
            or (writes and not isinstance(split, dict))):
        return None
    split = split or {}
    counts = (usage.get("input_tokens") or 0,
              split.get("ephemeral_5m_input_tokens") or 0,
              split.get("ephemeral_1h_input_tokens") or 0,
              usage.get("cache_read_input_tokens") or 0,
              usage.get("output_tokens") or 0)
    if key in LONG_PROMPT and sum(counts[:4]) > LONG_PROMPT[key][0]:
        rates = LONG_PROMPT[key][1]
    return sum(n * r for n, r in zip(counts, rates)) / 1e6


def price_into(run: dict, msg: dict, field: str) -> None:
    """Add a message's dollars to run[field], or count it as unpriced."""
    cost = dollars(msg.get("model", ""), msg["usage"])
    if cost is None:
        model = msg.get("model") or "?"
        run["unpriced"][model] = run["unpriced"].get(model, 0) + 1
    else:
        run[field] += cost


def price_subagent(run: dict, transcripts: Path, sid: str, agent: str) -> None:
    path = transcripts / sid / "subagents" / f"agent-{agent}.jsonl"
    if path.exists():
        for msg in unique_messages(records(path)):
            price_into(run, msg, "subagent")


def unique_messages(recs):
    """One entry per assistant message, keyed to its first record. The harness
    writes a record per content block, each repeating the message's usage, so
    usage is taken once and content is gathered from every record: a tool call
    is the last block, never in the record that comes first."""
    msgs = {}
    for rec in recs:
        msg = rec.get("message") or {}
        key = msg.get("id") or rec.get("requestId")
        if rec.get("type") != "assistant" or not msg.get("usage"):
            continue
        if key in msgs:
            msgs[key]["content"] += blocks(rec)
        else:
            msgs[key] = {**msg, "content": list(blocks(rec)), "_rec": rec}
    return msgs.values()


def new_run(sid: str, rec: dict, usage: dict) -> dict:
    return {"session": sid, "start": rec.get("timestamp", ""),
            "entry": context(usage), "max_ctx": 0, "dollars": 0.0,
            "subagent": 0.0, "unpriced": {}}


def add_turn(run: dict, msg: dict) -> None:
    run["max_ctx"] = max(run["max_ctx"], context(msg["usage"]))
    price_into(run, msg, "dollars")


def agent_calls(msg: dict) -> list[str]:
    return [b["id"] for b in msg.get("content") or []
            if isinstance(b, dict) and b.get("type") == "tool_use"
            and b.get("name") in AGENT_TOOLS]


def skill_loads(msg: dict) -> list[str]:
    return [(b.get("input") or {}).get("skill", "")
            for b in msg.get("content") or []
            if isinstance(b, dict) and b.get("type") == "tool_use"
            and b.get("name") == "Skill"]


def agent_result(rec: dict) -> tuple[str, list[str]] | None:
    res = rec.get("toolUseResult")
    agent = res.get("agentId") if isinstance(res, dict) else None
    ids = [b.get("tool_use_id") for b in blocks(rec)
           if isinstance(b, dict) and b.get("type") == "tool_result"]
    return (agent, ids) if agent else None


def typed(rec: dict, names: set) -> list[str]:
    """The tracked names a user record types as a slash command."""
    if rec.get("type") != "user" or rec.get("isCompactSummary"):
        return []
    return [n for n in TYPED.findall(text_of(rec)) if n in names]


def scan_session(path: Path, names: set, acc: dict) -> None:
    sid, transcripts = path.stem, path.parent
    recs = list(records(path))
    for rec in recs:
        for name in dict.fromkeys(typed(rec, names)):
            acc["typed"].setdefault(name, []).append(
                rec.get("timestamp", ""))
    scan_runs(recs, sid, transcripts, names, acc)


def scan_runs(recs, sid, transcripts, names, acc) -> None:
    msgs = {m["_rec"].get("uuid"): m for m in unique_messages(recs)}
    calls, cur, run = {}, None, None
    for rec in recs:
        msg = msgs.pop(rec.get("uuid"), None)
        if msg is not None:
            cur, run = step(msg, cur, run, sid, names, acc, calls)
        elif hit := agent_result(rec):
            attach_agent(hit, calls, transcripts, sid)
        elif typed(rec, names):
            # A typed invocation is a new run even when the messages on
            # either side of it carry the same attribution.
            cur = None


def step(msg, cur, run, sid, names, acc, calls):
    rec, usage = msg["_rec"], msg["usage"]
    skill = rec.get("attributionSkill")
    note_attribution(rec, acc)
    for loaded in skill_loads(msg):
        if loaded in names:
            acc["loaded"].setdefault(loaded, []).append(
                rec.get("timestamp", ""))
    if skill != cur:
        cur = skill
        run = new_run(sid, rec, usage) if skill in names else None
        if run is not None:
            acc["runs"].setdefault(skill, []).append(run)
    if run is not None:
        add_turn(run, msg)
        calls.update({cid: run for cid in agent_calls(msg)})
    return cur, run


def note_attribution(rec: dict, acc: dict) -> None:
    ts = rec.get("timestamp", "")
    if rec.get("attributionSkill") and ts:
        acc["since"] = min(filter(None, (acc["since"], ts)))


def attach_agent(hit, calls, transcripts, sid) -> None:
    agent, ids = hit
    for run in {id(calls[i]): calls[i] for i in ids if i in calls}.values():
        price_subagent(run, transcripts, sid, agent)


def scan_transcripts(transcripts: Path, names: set, home: Path) -> dict:
    acc = {"runs": {}, "typed": {}, "loaded": {}, "since": "",
           "invoked": {}, "calls": set()}
    for path in sorted(transcripts.glob("*.jsonl")):
        scan_session(path, names, acc)
        scan_invocations(records(path), path.stem, home, acc)
    for path in sorted(transcripts.glob("*/subagents/*.jsonl")):
        scan_invocations(records(path), path.parent.parent.name, home, acc)
    return acc


# A script run is a Bash call that runs or sources the file. Every command
# position in the call is read: the words of each segment between separators,
# past assignments, flags, and the words that only launch what follows.
SEGMENT = re.compile(r"\|\||&&|[;|&\n(){}`]|\$\(")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)",
                     re.S)
ASSIGN = re.compile(r"^[A-Za-z_]\w*=")
LAUNCHERS = frozenset({"bash", "sh", "exec", "command", "env", "time",
                       "timeout", "nohup", "source", ".", "then", "do", "else",
                       "if", "while", "until", "!", "sudo"})


def launcher(word: str) -> bool:
    return (word in LAUNCHERS or Path(word).name.startswith("python")
            or word.startswith("-") or word.isdigit() or bool(ASSIGN.match(word)))


def expand(word: str, cwd: str, home: Path) -> str:
    """A path word as a normalised absolute path: ~/.claude and $HOME/.claude
    are the tree being censused, a relative path is read from cwd."""
    word = word.strip("\"'")
    for prefix in ("~/.claude/", "$HOME/.claude/", "${HOME}/.claude/"):
        if word.startswith(prefix):
            return os.path.normpath(home / word[len(prefix):])
    word = os.path.expanduser(word.replace("${HOME}", "~", 1)
                              .replace("$HOME", "~", 1))
    return os.path.normpath(os.path.join(cwd, word))


def invoked(command: str, cwd: str, home: Path) -> list[str]:
    """The files a Bash command runs or sources, as absolute paths. A heredoc
    body is data, not commands, and a `cd` moves the directory the rest of the
    command resolves against. A call asking only for --self-test or --help
    tests or reads the script, and is not a use of it."""
    out = []
    for seg in SEGMENT.split(HEREDOC.sub("", command)):
        words = seg.split()
        if words[:1] == ["cd"] and len(words) > 1:
            cwd = expand(words[1], cwd, home)
            continue
        word = next((w for w in words if not launcher(w)), "")
        if {"--self-test", "-h", "--help"} & set(words):
            continue
        if Path(word.strip("\"'")).suffix in SCRIPT_SUFFIX:
            out.append(expand(word, cwd, home))
    return out


def scan_invocations(recs, sid: str, home: Path, acc: dict) -> None:
    """Every Bash call in one transcript, keyed by the files it runs. A call
    copied into a second transcript keeps its tool_use id, so it counts once."""
    for rec in recs:
        if rec.get("type") != "assistant":
            continue
        for b in blocks(rec):
            if (not isinstance(b, dict) or b.get("type") != "tool_use"
                    or b.get("name") != "Bash" or b.get("id") in acc["calls"]):
                continue
            acc["calls"].add(b.get("id"))
            command = (b.get("input") or {}).get("command") or ""
            for path in dict.fromkeys(invoked(command, rec.get("cwd") or "/",
                                              home)):
                acc["invoked"].setdefault(path, []).append(
                    {"session": sid, "start": rec.get("timestamp", "")})


# ------------------------------------------------------------- usage + cost

def month_counts(runs: list[dict]) -> dict:
    months: dict[str, int] = {}
    for run in runs:
        months[run["start"][:7]] = months.get(run["start"][:7], 0) + 1
    return dict(sorted(months.items()))


def in_window(stamps: list[str], since: str) -> int:
    return sum(bool(since) and ts[:10] >= since[:10] for ts in stamps)


def usage(name: str, acc: dict) -> dict:
    runs = acc["runs"].get(name, [])
    starts = sorted(r["start"] for r in runs)
    return {"runs": len(runs),
            "sessions": len({r["session"] for r in runs}),
            "typed": in_window(acc["typed"].get(name, []), acc["since"]),
            "loaded": in_window(acc["loaded"].get(name, []), acc["since"]),
            "first_run": starts[0][:10] if starts else None,
            "last_run": starts[-1][:10] if starts else None,
            "runs_by_month": month_counts(runs)}


def script_usage(path: str, acc: dict) -> dict:
    """A script's runs, in the window the procedures' runs use, so the two
    compare. A script has no typed or loaded count: only a Bash call runs it."""
    runs = [r for r in acc["invoked"].get(os.path.normpath(path), [])
            if acc["since"] and r["start"][:10] >= acc["since"][:10]]
    starts = sorted(r["start"] for r in runs)
    return {"runs": len(runs),
            "sessions": len({r["session"] for r in runs}),
            "first_run": starts[0][:10] if starts else None,
            "last_run": starts[-1][:10] if starts else None,
            "runs_by_month": month_counts(runs)}


def run_total(run: dict) -> float:
    return run["dollars"] + run["subagent"]


def cost(name: str, acc: dict) -> dict:
    """A procedure's runs in list-price dollars, subagents included. Growth is
    in tokens, because it is how far a run widens the context, not a price.
    `unpriced` counts the messages, by model, whose price is not known: the
    dollars leave them out, so they are reported and never read as free."""
    runs = acc["runs"].get(name, [])
    if not runs:
        return {}
    totals = [run_total(r) for r in runs]
    late = sum(run_total(r) for r in runs if r["entry"] > LATE_ENTRY)
    unpriced: dict[str, int] = {}
    for r in runs:
        for model, n in r["unpriced"].items():
            unpriced[model] = unpriced.get(model, 0) + n
    return {"dollars": sum(totals),
            "median_run": statistics.median(totals),
            "subagent": sum(r["subagent"] for r in runs),
            "median_growth": int(statistics.median(
                r["max_ctx"] - r["entry"] for r in runs)),
            "late_share": (round(100 * late / sum(totals), 1)
                           if sum(totals) else None),
            "unpriced": dict(sorted(unpriced.items()))}


# ------------------------------------------------------------------- upkeep

def git(cwd: Path, *args: str) -> str | None:
    proc = subprocess.run(["git", "-C", str(cwd), *args],
                          capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def upkeep(it: dict, today: dt.date, bundles: list[str] = ()) -> dict:
    """The item's history, its bundled files' included: a script and the
    list it reads are one thing to keep up. Each path is logged on its
    own, since --follow takes one, and a commit touching two counts once."""
    root = Path(it["root"])
    follow = ["--follow"] if root.is_file() else []
    commits = {}
    for name in (root.name, *bundles):
        log = git(root.parent, "log", "--format=%H %as", *follow, "--", name)
        if log is None:
            return {"tracked": "no repo"}
        commits.update(ln.split() for ln in log.splitlines())
    # check-ignore names a path only while git does not track it, so a hit is
    # exactly the file with no history and no backup. `status` cannot answer
    # this: it prints nothing for an ignored file, which reads as clean.
    if git(root.parent, "check-ignore", "-q", root.name) is not None:
        return {"tracked": "ignored"}
    dates = sorted(commits.values(), reverse=True)
    cutoff = (today - dt.timedelta(days=RECENT_DAYS)).isoformat()
    status = git(root.parent, "status", "--porcelain", "--untracked-files=all",
                 "--", root.name, *bundles)
    return {"tracked": "yes", "commits": len(dates),
            "first_commit": dates[-1] if dates else None,
            "last_edit": dates[0] if dates else None,
            "edits_90d": sum(d >= cutoff for d in dates),
            "uncommitted": bool(status and status.strip())}


# ---------------------------------------------------------------- integrity

def script_path(prefix: str, sub: str, name: str,
                home: Path, project: Path) -> Path:
    name = name.rstrip(".")
    if prefix.endswith(HOME_PREFIXES):
        return home / sub / name
    return project / ".claude" / sub / name


def tested(path: Path) -> bool:
    return path.is_file() and "--self-test" in path.read_text(
        encoding="utf-8", errors="replace")


def script_fact(ref: tuple, home: Path, project: Path) -> dict:
    path = script_path(*ref, home, project)
    return {"script": str(path), "exists": path.is_file(),
            "tested": tested(path)}


def bundled(it: dict) -> list[str]:
    """A skill's files beside SKILL.md; a script's files beside it that are
    no script and that its text names -- a list it reads."""
    root = Path(it["root"])
    if it["kind"] == "skill":
        return sorted(str(p.relative_to(root)) for p in root.rglob("*")
                      if p.is_file() and p.name != "SKILL.md")
    if it["kind"] != "script":
        return []
    text = root.read_text(encoding="utf-8", errors="replace")
    return sorted(p.name for p in root.parent.iterdir()
                  if p.is_file() and p.suffix not in SCRIPT_SUFFIX
                  and p.name in text)


def scripts_named(it: dict, home: Path, project: Path) -> list[dict]:
    text = Path(it["path"]).read_text(encoding="utf-8", errors="replace")
    refs = dict.fromkeys(SCRIPT_REF.findall(text))
    facts = {}
    for ref in refs:
        fact = script_fact(ref, home, project)
        facts[fact["script"]] = fact
    return list(facts.values())


# ------------------------------------------------------------------- probes

# The probes read a bash block as bash does, not as text. A `\`-newline joins
# two lines into one command; nothing expands inside single quotes, a comment,
# or the body of a heredoc whose delimiter is quoted.
CONTINUATION = re.compile(r"\\\n")
# One pass, left to right, so whichever opens first wins: a `'` in a comment
# starts no string, and a `#` in a string starts no comment.
QUOTED_OR_COMMENT = re.compile(
    r'"(?:\\.|[^"\\])*"|\'[^\']*\'|(?m:(?:^|(?<=\s))#(?!\{).*$)')
LITERAL_HEREDOC = re.compile(
    r"<<-?\s*(['\"])(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.S)
SUBSTITUTION = re.compile(r"\$\([^()]*\)|`[^`]*`")
SOURCED = re.compile(r"(?:^|[;&|(]\s*)(?:source|\.)\s+([^\s;&|)$]+)(?=[\s;&|)]|$)",
                     re.M)
COMMAND_SPLIT = re.compile(r"\|\||&&|[;|&\n(){}]")
KEYWORDS = frozenset({"if", "elif", "while", "until", "then", "do", "else",
                      "!", "time"})
DECLARERS = frozenset({"export", "local", "declare", "readonly", "typeset"})
ASSIGNMENT = re.compile(r"^([A-Za-z_]\w*)\+?=")
LOOP_VAR = re.compile(r"\bfor\s+([A-Za-z_]\w*)\s+in\b|\bread\s+(?:-\w+\s+)*([A-Za-z_]\w*)")


def expanding(block: str) -> str:
    """The block with what bash never expands taken out, its double-quoted
    strings kept whole."""
    text = LITERAL_HEREDOC.sub("", CONTINUATION.sub(" ", block))
    return QUOTED_OR_COMMENT.sub(lambda m: {'"': m.group(0), "'": "''"}.get(
        m.group(0)[0], ""), text)


def words_of(segment: str) -> list[str]:
    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


def set_in(block: str) -> set:
    """The variables a block sets in its own shell. An assignment sets one when
    nothing follows it in its command, or behind a declarer; one followed by a
    command, `X=1 cmd`, is that command's environment and sets nothing after it.
    A command substitution is one word here, so `X=$(cmd)` is an assignment."""
    text = expanding(block)
    while SUBSTITUTION.search(text):
        text = SUBSTITUTION.sub("SUBST", text)
    found = {g for m in LOOP_VAR.finditer(text) for g in m.groups() if g}
    for segment in COMMAND_SPLIT.split(text):
        words = words_of(segment)
        while words and words[0] in KEYWORDS:
            words = words[1:]
        if words and words[0] in DECLARERS:
            found |= {m.group(1) for w in words[1:] if (m := ASSIGNMENT.match(w))}
            continue
        lead = [m.group(1) for w in words if (m := ASSIGNMENT.match(w))]
        if lead and len(lead) == len(words):
            found |= set(lead)
    return found


def used_in(block: str) -> set:
    return {m.group(1) for m in VAR_USE.finditer(expanding(block))}


def sourced_sets(block: str, base: Path) -> set:
    """The variables the files a block sources set. A path is resolved against
    the directory of the document holding the block, one level deep; a path
    built from a variable, or one that is not a file, sets nothing here."""
    found = set()
    for m in SOURCED.finditer(expanding(block)):
        path = Path(m.group(1)).expanduser()
        path = path if path.is_absolute() else base / path
        if path.is_file():
            found |= set_in(path.read_text(encoding="utf-8", errors="replace"))
    return found


def unset_vars(text: str, base: Path) -> list[str]:
    """Each bash block runs in its own shell: a variable it uses and never
    sets expands to empty rather than failing."""
    out = []
    for n, block in enumerate(BASH_FENCE.findall(text), 1):
        gaps = sorted(v for v in used_in(block) - set_in(block)
                      - sourced_sets(block, base)
                      if v not in SHELL_ENV and not v.startswith("CLAUDE_"))
        if gaps:
            out.append(f"block {n} uses unset {', '.join(gaps)}")
    return out


def tmp_paths(text: str) -> list[str]:
    """A fixed /tmp path is shared between sessions and survives none.
    Prose punctuation after a path is not part of it, and neither is a `)`
    no `(` in the path opened; `/tmp/x-$(id -u)` keeps its own."""
    return sorted({f"fixed path {path_end(m)}" for block in BASH_FENCE.findall(text)
                   for m in TMP_PATH.findall(block)})


def path_end(path: str) -> str:
    path = path.rstrip(".,;:]")
    while path.endswith(")") and path.count(")") > path.count("("):
        path = path[:-1].rstrip(".,;:]")
    return path


def probes(it: dict) -> list[str]:
    """What a reader would run from this item. A script's source is skipped
    for the reason its references are: a path there may be a usage example or
    a fixture, and is not a step anyone runs."""
    if it["kind"] == "script":
        return []
    text = Path(it["path"]).read_text(encoding="utf-8", errors="replace")
    return unset_vars(text, Path(it["path"]).parent) + tmp_paths(text)


# ---------------------------------------------------------------- restating

def prose(path: str) -> str:
    """The text of an item a reader reads as instructions, each line kept at
    its own number: a markdown file without its code blocks and with no
    frontmatter but its description, a .py's module docstring, a .sh's
    leading comment block. A settings or memory file has none here."""
    p = Path(path)
    text = p.read_text(encoding="utf-8", errors="replace")
    if p.suffix == ".py":
        m = DOCSTRING.search(text)
        return "\n" * text.count("\n", 0, m.start(1)) + m.group(1) if m else ""
    if p.suffix == ".sh":
        lines = []
        for ln in text.splitlines():
            if not ln.startswith("#"):
                break
            lines.append("" if ln.startswith("#!") else re.sub(r"^# ?", "", ln))
        return "\n".join(lines)
    if p.suffix != ".md":
        return ""
    fm = FRONTMATTER.match(text)
    head = "\n".join(ln if ln.startswith("description:") else ""
                     for ln in fm.group(0).split("\n")) if fm else ""
    return PROSE_FENCE.sub(lambda m: "\n" * m.group(0).count("\n"),
                           head + text[fm.end() if fm else 0:])


def sentences(path: str) -> list[tuple[int, frozenset]]:
    """Each sentence of an item's prose as (line, its words). A sentence ends at
    a stop before a capital, a blank line, or the start of a list item or a
    table row. Its words are three letters or more, less FILLER."""
    text, out, pos = prose(path), [], 0
    for part in PROSE_BREAK.split(text):
        at = text.find(part, pos)
        pos = at + len(part)
        at += len(part) - len(part.lstrip())
        words = frozenset(PROSE_WORD.findall(part.lower())) - FILLER
        if words:
            out.append((text.count("\n", 0, at) + 1, words))
    return out


def fill_restates(rows: list[dict]) -> None:
    """Fill each skill's and command's restates: its sentences of RESTATE_WORDS
    words or more of which RESTATE_SHARE or more appear in one other sentence
    -- of a skill, a command, a rules file or a script's header, this item
    included -- each with the closest such sentence. Two sentences of one line
    matching the same place are one finding. A file's description is not
    matched against its own body, which it summarises by design."""
    said = {r["path"]: sentences(r["path"]) for r in rows
            if r["kind"] in PROCEDURE | {"rules", "script"}}
    desc = {r["path"]: FRONTMATTER.match(Path(r["path"]).read_text(
        encoding="utf-8", errors="replace")) for r in rows
        if r["kind"] in PROCEDURE}
    for row in rows:
        if row["kind"] not in PROCEDURE:
            continue
        fm = desc[row["path"]]
        head = fm.group(0).count("\n") if fm else 0
        found = {}
        for line, words in said[row["path"]]:
            if len(words) < RESTATE_WORDS:
                continue
            best = max(((len(words & other) / len(words), path, at)
                        for path, theirs in said.items()
                        for at, other in theirs
                        if path != row["path"]
                        or (at != line and (at > head) == (line > head))),
                       default=(0, "", 0))
            key = (line, best[1], best[2])
            if best[0] >= RESTATE_SHARE and best[0] > found.get(key, 0):
                found[key] = best[0]
        row["restates"] = [{"line": k[0], "path": k[1], "at": k[2],
                            "share": round(v, 2)} for k, v in found.items()]


# ------------------------------------------------------------------ journal

def slash(name: str) -> re.Pattern:
    return re.compile(r"(?<![\w:/.-])/" + re.escape(name) + r"(?![\w:-])")


def journal_entries(hist: Path) -> list[dict]:
    """Every entry ever written -- these facts are lifetime, not a backlog."""
    if not hist.exists():
        return []
    env = {**os.environ, "JOURNAL_HIST": str(hist)}
    out = subprocess.run([str(SCRIPTS / "journal_scan.sh")], env=env,
                         capture_output=True, text=True, check=True)
    scan = json.loads(out.stdout)
    grouped = [e for es in scan["tickets"].values() for e in es]
    return grouped + scan["no_ticket"]


def open_items(hist: Path) -> list[str]:
    if not hist.exists():
        return []
    env = {**os.environ, "JOURNAL_HIST": str(hist)}
    out = subprocess.run([str(SCRIPTS / "journal_queue.sh")], env=env,
                         capture_output=True, text=True, check=True)
    return [ln for ln in out.stdout.splitlines() if ln.strip()]


# journal_lib.sh owns the marker spelling; this restates it because Python cannot
# source it. The queue had two markers before it was merged into one, and a
# session history is append-only, so both spellings are read. `**TODO:**` lines carry an id and
# are the live queue. `**Improve:**` lines are closed history: 929 of them ran
# from 2026-06-11 to 2026-09-23 with no id, so none can be closed, and they were
# read once and drained on 2026-09-24 (journal entry u747). They are kept here
# because an entry still shows them as what a skill captured, never as open work.
QUEUE_MARKS = ("**TODO:**", "**Improve:**")

# The close mark, the pair of `**TODO:**`: a note opens under one and is placed
# under the other. Restated here for the same reason -- Python cannot source
# journal_lib.sh, which owns the spelling.
CLOSE_MARK = "**TODO-DONE:**"

# The id at the head of a note, and of the close that names it.
CLOSE_ID = re.compile(r"^\[([a-z0-9]{4})\] ")


def queue_lines(entry: dict) -> list[str]:
    """Every queue item captured in one entry, each keeping its minted id.

    An open item is named by its id wherever it is shown, so the id is kept
    rather than stripped. Entries written before ids existed carry none.
    """
    out = []
    for ln in entry["block"].splitlines():
        for m in QUEUE_MARKS:
            if ln.startswith(m):
                out.append(ln[len(m):].strip())
                break
    return out


def close_lines(entry: dict) -> list[str]:
    """Every placement recorded in one entry, each keeping its note's id.

    A close is shown by the id of the note it closes, as an open note is.
    """
    return [ln[len(CLOSE_MARK):].strip()
            for ln in entry["block"].splitlines()
            if ln.startswith(CLOSE_MARK)]


def placement(close: str) -> str:
    """The placement field of a close: the text before the reason.

    `<placement> — <reason>` is the grammar journal_close_re in journal_lib.sh
    enforces. The history is append-only and 98 closes were written before that
    grammar, so a line with no ` — ` yields its whole text, which names no item
    -- the right answer for a close that never named one.
    """
    return CLOSE_ID.sub("", close).split(" — ", 1)[0]


def places(close: str, it: dict) -> bool:
    """Whether this close placed its note into this item.

    The placement is `<kind>[:<name>]`, and the name is optional, so `script —
    seven now drive themselves` names the kind and no item in it: it attributes
    to nothing rather than to an arbitrary script. A memory fact is named by its
    stem, because `memory_fact.sh write <name>` and the MEMORY.md pointer both
    use the stem while the item carries the file name. A script is named by
    either: closes wrote `script:rails_pr_env` for rails_pr_env.sh.

    Two items can share a name -- there are two CLAUDE.md and two selftest.sh --
    and a placement cannot say which, so it counts for both. A count shown twice
    is visible; a count assigned by a guess is not.
    """
    kind, _, name = placement(close).partition(":")
    if kind != it["kind"] or not name:
        return False
    stem = Path(it["name"]).stem
    return name in ({stem} if kind == "memory"
                    else {it["name"], stem} if kind == "script"
                    else {it["name"]})


def placements(entries: list[dict], items: list[dict]) -> dict:
    """Every close into the tooling, by whether it names an item that is here.

    A close counts once, however many items share its name. `item` names one,
    `kind` names a kind and no item in it -- the grammar allows that, so it is
    counted rather than refused -- and `gone` lists the named placements no item
    answers to: renamed or deleted since. A close into a ticket, into `-`, or
    written before the grammar names no kind, and is none of the three. Taken
    from every item, before --kind keeps one, so a placement into another kind
    is not read as gone.
    """
    out = {"item": 0, "kind": 0, "gone": []}
    for c in (c for e in entries for c in close_lines(e)):
        kind, _, name = placement(c).partition(":")
        if kind not in KINDS:
            continue
        if not name:
            out["kind"] += 1
        elif any(places(c, it) for it in items):
            out["item"] += 1
        elif placement(c) not in out["gone"]:
            out["gone"].append(placement(c))
    return out


def captured_note(note: str, closed: set, queue: dict) -> dict:
    """A captured note, its id split off, and where it stands.

    A note is open while journal_queue.sh lists it -- the queue, not the absence
    of a close, is what holds open work -- and then carries the queue's age and
    ticket. It is placed when a close names its id. An id in neither is drained:
    two `**Improve:**` lines took ids on 2026-09-23 and were drained with the
    rest the next day. A note with no id predates ids and can be neither.
    """
    m = CLOSE_ID.match(note)
    if not m:
        return {"state": "no id", "id": None, "text": note}
    nid, text = m.group(1), note[m.end():]
    if nid in queue:
        q = queue[nid]
        return {"state": "open", "id": nid, "text": text,
                "age": q["age"], "ticket": q["ticket"]}
    return {"state": "placed" if nid in closed else "drained",
            "id": nid, "text": text}


def close_fact(close: str) -> dict:
    """A placement, its note's id split off. 98 closes predate ids."""
    m = CLOSE_ID.match(close)
    return ({"id": m.group(1), "close": close[m.end():]} if m
            else {"id": None, "close": close})


def queued(line: str) -> dict:
    """One line of journal_queue.sh: id, opened, age, ticket and text, tab-separated."""
    note_id, opened, age, ticket, text = line.split("\t", 4)
    return {"id": note_id.strip(), "opened": opened, "age": age,
            "ticket": ticket, "text": text}


def reference(it: dict) -> re.Pattern:
    if it["kind"] in PROCEDURE:
        return slash(it["name"])
    return re.compile(re.escape(it["name"]))


def journal(it: dict, entries: list[dict], todos: list[str]) -> dict:
    name = it["name"]
    pat, via = reference(it), f"(via /{name})"
    vias = sorted(e["ts"] for e in entries if e["header"].endswith(via))
    notes = list(dict.fromkeys(
        n for e in entries for n in queue_lines(e) if pat.search(n)))
    placed = list(dict.fromkeys(
        c for e in entries for c in close_lines(e) if places(c, it)))
    closed = {m.group(1) for e in entries for c in close_lines(e)
              if (m := CLOSE_ID.match(c))}
    queue = {q["id"]: q for q in map(queued, todos)}
    return {"via_entries": len(vias),
            "via_last": vias[-1][:10] if vias else None,
            "captured": [captured_note(n, closed, queue) for n in notes],
            "open": [queued(t) for t in todos if pat.search(t)],
            "placed": [close_fact(c) for c in placed]}


# ---------------------------------------------------------------- inventory

def inventory(home: Path, project: Path, transcripts: Path,
              today: dt.date) -> dict:
    items = discover(home, project, transcripts)
    acc = scan_transcripts(transcripts, {i["name"] for i in items}, home)
    hist = project / ".claude" / "session_history.md"
    entries, todos = journal_entries(hist), open_items(hist)
    rows = [describe(it, acc, entries, todos, home, project, today)
            for it in items]
    fill_named_by(rows)
    fill_restates(rows)
    return {"generated": today.isoformat(), "project": str(project),
            "transcripts": str(transcripts),
            "attribution_since": acc["since"][:10] or None,
            "placements": placements(entries, items),
            "items": rows}


def describe(it, acc, entries, todos, home, project, today) -> dict:
    name, run = it["name"], it["kind"] in PROCEDURE
    bundles = bundled(it)
    return {**{k: it[k] for k in ("name", "scope", "kind", "path")},
            **identity(it),
            "usage": (usage(name, acc) if run
                      else script_usage(it["path"], acc)
                      if it["kind"] == "script" else {}),
            "cost": cost(name, acc) if run else {},
            "upkeep": upkeep(it, today,
                             bundles if it["kind"] == "script" else []),
            "scripts": [] if it["kind"] == "script"
                       else scripts_named(it, home, project),
            **({"tested": tested(Path(it["path"]))}
               if it["kind"] == "script" else {}),
            "bundled": bundles,
            "probes": probes(it),
            "journal": journal(it, entries, todos)}


def fill_named_by(rows: list[dict]) -> None:
    """Fill each script's named_by: the items whose text names the file."""
    texts = {r["path"]: Path(r["path"]).read_text(
        encoding="utf-8", errors="replace") for r in rows}
    for row in (r for r in rows if r["kind"] == "script"):
        row["named_by"] = sorted(
            r["name"] for r in rows if r["path"] != row["path"]
            and row["name"] in texts[r["path"]])


def narrow(inv: dict, kind: str | None) -> dict:
    """Keep one kind. Takes a measured inventory, which is the whole rule:
    `named by` counts the items of every kind that name a script, so keeping
    one kind before the measurement would report a called script as named by
    nothing. The kept kind is recorded for the report to state."""
    if kind is None:
        return inv
    return {**inv, "kind": kind,
            "items": [i for i in inv["items"] if i["kind"] == kind]}


# ----------------------------------------------------------------- rendering

def kilo(n: int | None) -> str:
    return "-" if n is None else f"{n / 1e3:,.0f}"


def usd(n: float | None) -> str:
    return "-" if n is None else f"{n:,.2f}"


def dash(value) -> str:
    return "-" if value in (None, "", []) else str(value)


def align(column: list[str]) -> str:
    return ">" if all(NUMERIC.match(c) for c in column) else "<"


def table(title: str, headers: list[str], rows: list[list]) -> str:
    cells = [headers] + [[dash(c) for c in r] for r in rows]
    columns = list(zip(*cells))
    fmt = "  ".join(f"{{:{align(c[1:])}{max(map(len, c))}}}"
                    for c in columns)
    body = [fmt.format(*r).rstrip() for r in cells]
    return "\n".join([f"== {title}", *body, ""])


def short(path: str) -> str:
    return path.replace(str(Path.home()), "~")


def blurb(text: str) -> str:
    cut = text[:BLURB_CHARS - 1].rstrip() + "…"
    return text if len(text) <= BLURB_CHARS else cut


def labeller(items):
    """An item's name, with its scope added where two items share the name --
    there are two CLAUDE.md and two selftest.sh, and a bare name cannot say
    which one a row is about."""
    count: dict[str, int] = {}
    for i in items:
        count[i["name"]] = count.get(i["name"], 0) + 1
    return lambda i: (i["name"] if count[i["name"]] == 1
                      else f"{i['name']} ({i['scope']})")


def notes(items) -> list[dict]:
    """Every note the items show, once, with the items it names.

    An item meets a note three ways -- written naming it, open in the queue
    and naming it, placed into it -- and one note can name several
    items. So a note is keyed by its id, or by its text where it predates ids,
    and gathers the items and the placements from every way it was met. Open
    notes come first, then those with no id, then the placed.
    """
    label, found = labeller(items), {}

    def meet(key: str, i: dict, **fact) -> dict:
        n = found.setdefault(key, {"state": "no id", "id": None, "text": "",
                                   "age": "", "ticket": "", "items": [],
                                   "placements": []})
        n.update({k: v for k, v in fact.items() if v})
        if label(i) not in n["items"]:
            n["items"].append(label(i))
        return n

    for i in items:
        j = i["journal"]
        for c in j["captured"]:
            meet(c["id"] or c["text"], i, **c)
        for t in j["open"]:
            meet(t["id"], i, state="open", id=t["id"], text=t["text"],
                 age=t["age"], ticket=t["ticket"])
        for p in j["placed"]:
            n = meet(p["id"] or p["close"], i, state="placed", id=p["id"])
            if p["close"] not in n["placements"]:
                n["placements"].append(p["close"])
    return sorted(found.values(), key=lambda n: NOTE_ORDER.index(n["state"]))


def note_body(n: dict) -> str:
    """The note's text, prefixed by its age and ticket while open, followed
    by where it was placed once it was."""
    when = " ".join(x for x in (n["age"], n["ticket"]) if x and x != "-")
    placed = "; ".join(n["placements"])
    return " ".join(x for x in (when, n["text"],
                                f"→ {placed}" if placed else "") if x)


def note_line(n: dict) -> str:
    return f"{n['state']:<6}  {n['id'] or '-':<4}  {note_body(n)}"


def named_by(names: list[str]) -> str:
    """How many items name a script, and the first few: one row stays one line
    when twenty items source the same helper."""
    more = len(names) - NAMERS_SHOWN
    head = ", ".join(names[:NAMERS_SHOWN]) + (f" +{more} more" if more > 0 else "")
    return f"named by {len(names)}: {head}" if names else ""


def attention(items) -> list[list[str]]:
    """The facts that each have a remedy, one row apiece.

    Untracked and uncommitted files, a script a body names that does not exist,
    a script with no --self-test, a script nothing names and nothing has run,
    a probe hit, a procedure that restates -- one row, the one-item report
    listing the lines -- and a procedure's messages with no list price, the
    remedy being the price added to PRICES. Each is stated once: an untested
    script is one row however many items name it. An open note is no row:
    /notes works the queue.
    """
    label, rows = labeller(items), []
    for i in items:
        u = i["upkeep"]
        if u["tracked"] in UNTRACKED:
            rows.append(["untracked", label(i), UNTRACKED[u["tracked"]]])
        elif u.get("uncommitted"):
            rows.append(["uncommitted", label(i),
                         f"last commit {dash(u.get('last_edit'))}"])
    rows += [["missing script", label(i), short(s["script"])]
             for i in items for s in i["scripts"] if not s["exists"]]
    rows += [["no self-test", label(i), named_by(i["named_by"])]
             for i in items if i["kind"] == "script" and not i["tested"]]
    rows += [["unused", label(i), "named by nothing, no run"]
             for i in items
             if i.get("named_by") == [] and not i["usage"]["runs"]]
    rows += [["probe", label(i), q] for i in items for q in i["probes"]]
    rows += [["restates", label(i), f"{len(r)} restatement{'s' * (len(r) > 1)};"
              f" /inventory {i['name']} lists them"]
             for i in items if (r := i.get("restates"))]
    rows += [["unpriced", label(i), f"{n} {model} messages: no list price,"
              " so the dollars leave them out"]
             for i in items for model, n in
             ((i["cost"] or {}).get("unpriced") or {}).items()]
    return rows


def month_span(since: str, until: str) -> list[str]:
    """Every month from since to until, both YYYY-MM-DD, empty ones too."""
    y, m, out = int(since[:4]), int(since[5:7]), []
    while f"{y:04d}-{m:02d}" <= until[:7]:
        out.append(f"{y:04d}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def usage_line(u: dict) -> str:
    if not u:
        return "runs        not attributed for this kind"
    launched = (f"typed {u['typed']}, loaded {u['loaded']}; " if "typed" in u
                else "Bash calls that run or source it; ")
    return (f"runs        {u['runs']} in {u['sessions']} sessions; {launched}"
            f"first {dash(u['first_run'])}, last {dash(u['last_run'])}")


def cost_line(c: dict) -> str:
    if not c:
        return "cost        no attributed run"
    unpriced = "".join(f"; {n} unpriced {m} messages left out"
                       for m, n in c["unpriced"].items())
    return (f"cost        ${usd(c['dollars'])} at list prices, "
            f"${usd(c['subagent'])} of it in subagents; median run "
            f"${usd(c['median_run'])}; median growth "
            f"{kilo(c['median_growth'])}K tokens; "
            f"{dash(c['late_share'])}% spent late{unpriced}")


def upkeep_line(k: dict) -> str:
    if k["tracked"] != "yes":
        return f"upkeep      not tracked by git ({k['tracked']})"
    return (f"upkeep      {k['commits']} commits, first "
            f"{dash(k['first_commit'])}, last edit {dash(k['last_edit'])}, "
            f"{k['edits_90d']} in {RECENT_DAYS}d, uncommitted "
            f"{'yes' if k['uncommitted'] else 'no'}")


def script_line(s: dict) -> str:
    state = ("missing" if not s["exists"]
             else "self-test" if s["tested"] else "no self-test")
    return f"names       {short(s['script'])} — {state}"


def item_lines(i: dict) -> list[str]:
    out = [usage_line(i["usage"]), cost_line(i["cost"]),
           upkeep_line(i["upkeep"])]
    if i["kind"] == "script":
        out.append(f"named by    {', '.join(i['named_by']) or 'nothing'}")
    out += [script_line(s) for s in i["scripts"]]
    out += [f"bundles     {b}" for b in i["bundled"]]
    out += [f"probe       {q}" for q in i["probes"]]
    out += [f"restates    line {r['line']} ~ {short(r['path'])}:{r['at']}"
            f" ({round(r['share'] * 100)}% of its words)"
            for r in i.get("restates", [])]
    j = i["journal"]
    out.append(f"journal     {j['via_entries']} entries via it"
               + (f", last {j['via_last']}" if j["via_last"] else ""))
    out += [f"note        {note_line(n)}" for n in notes([i])]
    return out


def render_one(inv: dict, i: dict) -> str:
    head = (f"{i['name']} — {i['scope']} {i['kind']} — "
            f"{short(i['path'])}\n"
            f"as of {inv['generated']}; runs and cost since "
            f"{dash(inv['attribution_since'])}")
    desc = textwrap.fill(i["description"] or "(no description)", 76,
                         initial_indent="  ", subsequent_indent="  ")
    size = f"lines       {i['lines']}; description {i['desc_chars']} chars"
    return "\n".join([head, "", desc, "", size, *item_lines(i), ""])


def render_choice(hits: list[dict]) -> str:
    rows = [f"  --scope {i['scope']:8} {i['kind']:9} {short(i['path'])}"
            for i in hits]
    return "\n".join([f"{len(hits)} items are named {hits[0]['name']}. "
                       "Ask which one is meant:", *rows, ""])


def header(inv: dict) -> str:
    items = inv["items"]
    kinds = ", ".join(f"{n} {k}" for k in KINDS
                      if (n := sum(i["kind"] == k for i in items)))
    return (f"Inventory — {short(inv['project'])} — {inv['generated']}\n"
            f"{len(items)} items: {kinds or 'none'}\n"
            f"runs and cost since {dash(inv['attribution_since'])}, "
            f"from {short(inv['transcripts'])}\n"
            + placements_line(inv["placements"])
            + (f"kind {inv['kind']} only\n" if inv.get("kind") else ""))


def placements_line(p: dict) -> str:
    gone = f": {', '.join(p['gone'])}" if p["gone"] else ""
    return (f"notes placed: {p['item']} into an item, {p['kind']} into a kind"
            f" and no item, {len(p['gone'])} into an item gone{gone}\n")


def needs_attention(items) -> str:
    rows = attention(items)
    if not rows:
        return "== Needs attention (0)\nnothing\n"
    return table(f"Needs attention ({len(rows)})",
                 ["problem", "item", "detail"], rows)


def census_rows(items, months):
    """One row per item: how often it runs, what it costs, how it is kept,
    and what it is. A kind with no runs or cost leaves those cells empty."""
    return [[i["name"], i["kind"], i["scope"],
             *(u.get("runs_by_month", {}).get(m, "") for m in months),
             u.get("runs"), u.get("last_run"), usd(c.get("dollars")),
             usd(c.get("median_run")), usd(c.get("subagent")),
             kilo(c.get("median_growth")), c.get("late_share"),
             k.get("commits"), k.get("last_edit"),
             len(i["named_by"]) if i["kind"] == "script" else None,
             blurb(i["description"])]
            for i in items
            for u, c, k in [(i["usage"], i["cost"] or {}, i["upkeep"])]]


def render(inv: dict) -> str:
    """The census: what needs attention, then one table of every item, or of
    the one kind --kind kept."""
    items = inv["items"]
    months = month_span(inv["attribution_since"] or inv["generated"],
                        inv["generated"])
    heads = ["name", "kind", "scope", *(m[2:] for m in months), "runs",
             "last run", "$ total", "$/run", "$ subagent", "growth",
             "late %", "commits", "last edit", "named by", "what it is"]
    rows = census_rows(items, months)
    # A column no row fills measures nothing these kinds have -- named by
    # among the procedures, cost among the scripts -- so it is left out. The
    # months go as one block: a month dropped from the middle would read as
    # no gap at all.
    filled = [any(dash(r[j]) != "-" for r in rows) for j in range(len(heads))]
    span = range(3, 3 + len(months))
    if any(filled[j] for j in span):
        filled[3:3 + len(months)] = [True] * len(months)
    keep = [j for j in range(len(heads)) if filled[j]]
    notes_on = [text for head, text in (
        ("runs", "runs per month"),
        ("$ total", f"$ at list prices read {PRICES_READ}"),
        ("growth", "growth in K tokens")) if heads.index(head) in keep]
    title = "Items" + (
        f" ({'; '.join(notes_on)})" if notes_on else "")
    return "\n".join([
        header(inv), needs_attention(items),
        table(title, [heads[j] for j in keep],
              [[r[j] for j in keep] for r in rows])])


# ---------------------------------------------------------------- self-test

def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def jsonl(path: Path, recs: list[dict]) -> None:
    write(path, "".join(json.dumps(r) + "\n" for r in recs))


def assistant(uuid, mid, ts, usage, skill=None, content=(),
              model="claude-opus-5-5") -> dict:
    rec = {"type": "assistant", "uuid": uuid, "timestamp": ts,
           "message": {"id": mid, "model": model, "usage": usage,
                       "content": list(content)}}
    return {**rec, "attributionSkill": skill} if skill else rec


# Eight words of three letters or more, none of them FILLER: just long enough.
SAID = "A review names the ticket, the branch and the commit it read first, always."
WORDS = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
RESTATE_CASES = {  # case: (the subject skill's text, what it restates)
    "a script header": ("---\ndescription: S.\n---\n" + WORDS + ".\n",
                        [(4, "ref.sh", 2, 1.0)]),
    "too short": ("Alpha bravo charlie delta echo foxtrot golf.\n", []),
    "fenced": ("- step\n\n  ```bash\n  " + WORDS + "\n  ```\n", []),
    "own description": ("---\ndescription: Kilo lima mike november oscar papa"
                        " quebec romeo.\n---\nKilo lima mike november oscar"
                        " papa quebec romeo.\n", []),
    "same file": ("Kilo lima mike november oscar papa quebec romeo.\n\n"
                  "Kilo lima mike november oscar papa quebec romeo.\n",
                  [(1, "skill.md", 3, 1.0), (3, "skill.md", 1, 1.0)]),
    "six in ten": (" ".join(WORDS.split()[:6]) + " kilo lima mike november.\n",
                   []),
    "seven in ten": (" ".join(WORDS.split()[:7]) + " kilo lima mike.\n",
                     [(1, "ref.sh", 2, 0.7)]),
    "one line, twice": (WORDS + ". " + WORDS.capitalize().replace(
        "juliet", "kilo") + ".\n",
                        [(1, "ref.sh", 2, 1.0)]),
}


def restate_cases() -> dict:
    """Each case's skill beside one script whose header holds WORDS, and what
    fill_restates finds the skill restating."""
    out = {}
    for case, (text, _) in RESTATE_CASES.items():
        with tempfile.TemporaryDirectory() as d:
            ref = write(Path(d) / "ref.sh", f"#!/bin/sh\n# {WORDS}.\necho\n")
            skill = write(Path(d) / "skill.md", text)
            rows = [{"path": str(skill), "kind": "skill"},
                    {"path": str(ref), "kind": "script"}]
            fill_restates(rows)
            out[case] = [(r["line"], Path(r["path"]).name, r["at"], r["share"])
                         for r in rows[0]["restates"]]
    return out


def fixture(tmp: Path) -> tuple[Path, Path, Path]:
    home, project = tmp / "home", tmp / "proj"
    write(home / "commands/mine.md", "---\ndescription: Mine.\n---\nbody\n")
    (home / "commands/theirs.md").symlink_to(
        write(tmp / "shared/theirs.md", "shared\n"))
    write(home / "scripts/selftest.sh",
          "#!/bin/sh\n# The gate.\n"
          'for f in ./*.sh ./*.py; do grep -q -- --self-test "$f" &&'
          ' sh "$f" --self-test; done\n'
          "python3 tool.py --version   # a bespoke check, no flag\n")
    # A /tmp path in a script's source is a usage line or a fixture, not a probe.
    write(home / "scripts/gated.sh",
          "#!/bin/sh\n# Gated.\n--self-test\necho /tmp/out\n")
    write(home / "scripts/tool.py", '"""Tool."""\nx = 1\n')
    write(home / "CLAUDE.md", "# Global Preferences\n")
    write(home / "credo.md", "# Credo\n")
    write(home / "x_guidelines.md", "# X rules\n")
    write(home / "settings.json", "{}\n")
    write(project / ".claude/skills/alpha/SKILL.md",
          "---\ndescription: Alpha.\n---\nRun .claude/scripts/probe.sh,"
          " ~/.claude/scripts/gated.sh, ~/.claude/scripts/tool.py"
          " and .claude/scripts/gone.sh\n"
          # A cited line names the script; a glob names no script at all.
          "See .claude/scripts/probe.sh:12 and .claude/helpers/jira-*.sh\n")
    write(project / ".claude/skills/alpha/scripts/local.sh", "echo\n")
    # A data file the script names beside it is the script's bundled file.
    write(project / ".claude/scripts/probe.sh", "echo no flag < probe.list\n")
    write(project / ".claude/scripts/probe.list", "x\n")
    write(project / ".claude/scripts/unnamed.list", "x\n")
    write(project / ".claude/commands/beta.md",
          "# Beta heading\n\n```bash\nDIR=/tmp/out\n"
          "echo $DIR $DAY $HOME /tmp/r-$(id -u)/x\n```\n"
          # A `'` in a comment opens no string that would hide B=x, and a
          # `#` in a string opens no comment.
          "- step\n\n  ```bash\n  true  # it's set below\n"
          "  B=x; echo '#'\n  echo $B\n  ```\n\n" + SAID + "\n"
          # A sourced file sets what it assigns; a missing one sets nothing,
          # and the `}` closing a default ends the /tmp path inside it.
          "\n```bash\nsource ./env.sh\n. ./gone.sh\n"
          "echo $FROM_ENV $FROM_GONE ${KEEP:-/tmp/k-$(id -u)}/x\n```\n"
          # A path the prose describes is no step anyone runs.
          "\nqlty copies the repo to /tmp/qlty/ first.\n")
    write(project / ".claude/commands/env.sh", "FROM_ENV=1\n")
    write(project / ".claude/settings.local.json", "{}\n")
    write(project / "CLAUDE.md", "# Project rules\n\n" + SAID + "\n")
    write(project / ".gitignore", ".claude/settings.local.json\n")
    commit(project)
    journal_fixture(project / ".claude/session_history.md")
    transcripts = tmp / "transcripts"
    transcript_fixture(transcripts)
    bash_fixture(transcripts, project)
    write(transcripts / "memory/fact.md",
          "---\ndescription: A fact.\n---\nbody\n")
    # A colon forces the quotes, and the quotes must not reach the reader.
    write(home / "commands/quoted.md",
          "---\ndescription: 'Scope: it''s quoted.'\n---\nbody\n")
    return home, project, transcripts


def commit(repo: Path) -> None:
    ident = ["-c", "user.name=t", "-c", "user.email=t@t"]
    for args in (["init", "-q"], ["add", "-A"],
                 [*ident, "commit", "-qm", "fixture"]):
        subprocess.run(["git", "-C", str(repo), *args], check=True)


def journal_fixture(hist: Path) -> None:
    write(hist, "# Log\n")
    env = {**os.environ, "JOURNAL_HIST": str(hist)}
    out = subprocess.run([str(SCRIPTS / "journal.sh"), "-t", "chore: fixture",
                          "-b", "b", "--via", "/alpha",
                          "-n", "make /alpha faster", "-n", "cache the /alpha probe",
                          "-n", "fix /beta later"],
                         env=env, check=True, capture_output=True, text=True)
    cache = re.findall(r"^note opened: ([a-z0-9]{4}) ", out.stdout, re.M)[1]
    # One note naming /alpha placed under a placement naming no item, so the
    # captured list shows a closed note as placed and the rest as open. The
    # entry is written via /alpha, so `fix /beta later` tests that the entry
    # does not attribute a note: it is beta's alone.
    subprocess.run([str(SCRIPTS / "journal.sh"), "-t", "chore: fixture",
                    "-b", "b", "--placed", f"{cache}: - — superseded"],
                   env=env, check=True, capture_output=True)
    subprocess.run([str(SCRIPTS / "journal.sh"), "-t", "chore: fixture",
                    "-b", "b", "--via", "/beta", "-n", "not /alphabet"],
                   env=env, check=True, capture_output=True)
    # Five notes opened and placed five ways: a script named by its file name
    # and by its stem, a memory fact named by its stem, a kind naming no item,
    # and an item that is gone. Their text names nothing, so they test the
    # placement and not the pattern that also attributes a note by what it
    # mentions.
    out = subprocess.run([str(SCRIPTS / "journal.sh"), "-t", "chore: fixture",
                          "-b", "b", "-n", "tidy the shed",
                          "-n", "sweep the yard", "-n", "oil the hinge",
                          "-n", "mend the fence", "-n", "clear the gutter"],
                         env=env, check=True, capture_output=True, text=True)
    ids = re.findall(r"^note opened: ([a-z0-9]{4}) ", out.stdout, re.M)
    subprocess.run(
        [str(SCRIPTS / "journal.sh"), "-t", "chore: fixture", "-b", "b",
         "--placed", f"{ids[0]}: script:gated.sh — the workflow is a script now",
         "--placed", f"{ids[1]}: memory:fact — checked and written",
         "--placed", f"{ids[2]}: script — every script drives itself",
         "--placed", f"{ids[3]}: script:renamed.sh — renamed since",
         "--placed", f"{ids[4]}: script:gated — named without its extension"],
        env=env, check=True, capture_output=True)


def transcript_fixture(root: Path) -> None:
    agent = {"type": "tool_use", "id": "t1", "name": "Agent"}
    load = {"type": "tool_use", "id": "t2", "name": "Skill",
            "input": {"skill": "alpha"}}
    small = {"input_tokens": 100, "cache_read_input_tokens": 900,
             "output_tokens": 10}
    jsonl(root / "s1.jsonl", [
        {"type": "user", "uuid": "u0", "timestamp": "2026-04-01T00:00Z",
         "message": {"content": "<command-name>/alpha</command-name>"}},
        {"type": "user", "uuid": "u1", "timestamp": "2026-05-01T00:00Z",
         "message": {"content": "<command-name>/alpha</command-name>"}},
        # One message, two records: the tool call is the later block, as
        # the harness writes it.
        assistant("a1", "m1", "2026-05-01T00:01Z", small, "alpha"),
        assistant("a1b", "m1", "2026-05-01T00:01Z", small, "alpha", [agent]),
        {"type": "user", "uuid": "r1", "toolUseResult": {"agentId": "g1"},
         "message": {"content": [{"type": "tool_result",
                                  "tool_use_id": "t1"}]}},
        assistant("a2", "m2", "2026-05-01T00:02Z",
                  {"cache_read_input_tokens": 1500, "output_tokens": 20},
                  "alpha"),
        # A model with no list price is counted, not priced at zero.
        assistant("a2c", "m2c", "2026-05-01T00:02Z", {"output_tokens": 7},
                  "alpha", model="claude-nonesuch"),
        assistant("a3", "m3", "2026-05-01T00:03Z", {"input_tokens": 5}),
        assistant("a3b", "m3", "2026-05-01T00:03Z",
                  {"input_tokens": 5}, None, [load]),
        assistant("a4", "m4", "2026-06-02T00:00Z",
                  {"cache_read_input_tokens": 300000, "output_tokens": 5},
                  "alpha", model="claude-opus-5[1m]"),
    ])
    # Typing a command again starts a second run even when nothing else
    # was attributed in between.
    jsonl(root / "s2.jsonl", [
        {"type": "user", "uuid": "v1", "timestamp": "2026-05-10T00:00Z",
         "message": {"content": "<command-name>/beta</command-name>"}},
        assistant("b1", "n1", "2026-05-10T00:01Z", small, "beta"),
        {"type": "user", "uuid": "v2", "timestamp": "2026-05-11T00:00Z",
         "message": {"content": "<command-name>/beta</command-name>"}},
        assistant("b2", "n2", "2026-05-11T00:01Z", small, "beta"),
    ])
    jsonl(root / "s1/subagents/agent-g1.jsonl", [
        assistant("g", "gm", "2026-05-01T00:01Z",
                  {"input_tokens": 50, "output_tokens": 50},
                  model="claude-haiku-4-5-20251001")])


def bash(uuid, ts, cwd, tid, command) -> dict:
    call = {"type": "tool_use", "id": tid, "name": "Bash",
            "input": {"command": command}}
    return {**assistant(uuid, uuid, ts, {}, None, [call]), "cwd": cwd}


def bash_fixture(root: Path, project: Path) -> None:
    """Script runs, each a case the reader must tell apart: a run behind a cd,
    assignments and launchers; a cat of the same file; a path inside a heredoc;
    a call copied into a second transcript; a run before the window; a script
    of the same name elsewhere; a self-test and a help request, which are not
    uses; and a run from a subagent."""
    run = (f"cd {project} && FOO=1 timeout 5 bash .claude/scripts/probe.sh"
           " --go | head; cat .claude/scripts/probe.sh")
    with open(root / "s2.jsonl", "a") as f:
        for rec in [
            bash("c1", "2026-05-12T00:00Z", "/", "x1", run),
            bash("c2", "2026-05-13T00:00Z", str(project), "x2",
                 "~/.claude/scripts/gated.sh <<'EOF'\n.claude/scripts/probe.sh\nEOF"),
            bash("c3", "2026-05-13T00:00Z", "/", "x1", run),
            bash("c4", "2026-04-01T00:00Z", str(project / ".claude/scripts"),
                 "x3", "./probe.sh"),
            bash("c5", "2026-05-14T00:00Z", "/", "x4",
                 "python3 /elsewhere/tool.py && echo x.sh"),
            bash("c6", "2026-05-15T00:00Z", str(project), "x6",
                 ".claude/scripts/probe.sh --self-test; .claude/scripts/probe.sh -h")]:
            f.write(json.dumps(rec) + "\n")
    with open(root / "s1/subagents/agent-g1.jsonl", "a") as f:
        f.write(json.dumps(bash("g2", "2026-05-02T00:00Z", "/", "x5",
                                "python3 -I $HOME/.claude/scripts/tool.py")) + "\n")


# A bash block, and the variables it uses without setting them, read as bash
# reads it: each case is one way a text-only reader got the answer wrong.
PROBE_CASES = {
    "jq variable in single quotes": ("jq --arg s \"$X\" '.a == $s'\nX=1", []),
    "assignment after if": ("if W=$(cmd a); then echo \"$W\"; fi", []),
    "prefix reads itself": ('A="$A" cmd', ["A"]),
    "prefix sets nothing after": ("P=1 cmd; echo $P", ["P"]),
    "prefix across continuations": ('Q=x \\\n  R="$R" \\\n  cmd', ["R"]),
    "quoted heredoc is literal": ("cat <<'EOF'\n$NOPE\nEOF", []),
    "plain heredoc expands": ("cat <<EOF\n$YES\nEOF", ["YES"]),
    "comment": ("echo hi  # uses $C\n# $D", []),
    "export": ("export E=1\necho $E", []),
    "read loop": ("while IFS= read -r L; do echo $L; done", []),
    "for loop": ("for f in a b; do echo $f; done", []),
    "array": ("A=(x y)\necho $A", []),
    "quoted value with a space": ('V="a b"\necho $V', []),
    "default expansion": ("echo ${X:-d}", []),
}


EXPECTED = {
    "census": [("command", "global", "mine"),
               ("command", "global", "quoted"),
               ("command", "project", "beta"),
               ("memory", "project", "fact.md"),
               ("rules", "global", "CLAUDE.md"),
               ("rules", "global", "credo.md"),
               ("rules", "global", "x_guidelines.md"),
               ("rules", "project", "CLAUDE.md"),
               ("script", "global", "gated.sh"),
               ("script", "global", "selftest.sh"),
               ("script", "global", "tool.py"),
               ("script", "project", "probe.sh"),
               ("settings", "global", "settings.json"),
               ("settings", "project", "settings.local.json"),
               ("skill", "project", "alpha")],
    "kinds": sorted(KINDS),
    "kind.flag": (2, True, True),
    "kind.narrowed": (["script"], ["alpha"]),
    "kind.header": True,
    "name.parsed": {"name": "alpha", "scope": "project", "kind": "skill"},
    "scope.alone": (2, "skill_inventory.py: error: --scope picks between"
                       " items that share a name; give the name"),
    "hint.gaps": [],
    "desc": {"project:alpha": "Alpha.", "project:beta": "Beta heading",
             "global:mine": "Mine.", "global:gated.sh": "Gated.",
             "global:tool.py": "Tool.", "global:settings.json": "",
             "global:CLAUDE.md": "Global Preferences",
             "global:quoted": "Scope: it's quoted.",
             "project:fact.md": "A fact."},
    "named_by": {"gated.sh": ["alpha"],
                 "probe.sh": ["alpha"],
                 "selftest.sh": [], "tool.py": ["alpha", "selftest.sh"]},
    "alpha.usage": {"runs": 2, "sessions": 1, "typed": 1, "loaded": 1,
                    "first_run": "2026-05-01", "last_run": "2026-06-02",
                    "runs_by_month": {"2026-05": 1, "2026-06": 1}},
    # Run one: opus-5-5 at $4 input, $0.20 cache read, $20 output per MTok,
    # $0.00148, plus a haiku-4-5 subagent at $1 and $5, $0.0003. Run two:
    # opus-5 at $0.50 cache read and $25 output, $0.150125, and it starts past
    # LATE_ENTRY, so it is the late share.
    "alpha.cost": {"dollars": 0.151905, "median_run": 0.0759525,
                   "subagent": 0.0003, "median_growth": 250,
                   "late_share": 98.8, "unpriced": {"claude-nonesuch": 1}},
    "attention.unpriced": ["alpha"],
    # Each a rule of the price list: a 1-hour write costs more than a
    # 5-minute one; Haiku 5.5 past 100K tokens of prompt charges its higher
    # rates; fast mode, US-only inference and an unsplit cache write have no
    # price here; a message with no tokens costs nothing whatever its model.
    "price.cases": [0.000005, 0.000008, 0.0050005, 0.00100009,
                    None, None, None, 0.0],
    "alpha.upkeep": {"tracked": "yes", "commits": 1, "edits_90d": 1,
                     "uncommitted": False},
    "mine.upkeep": {"tracked": "no repo"},
    "ignored.upkeep": {"tracked": "ignored"},
    "attention.untracked": ["CLAUDE.md (global)", "credo.md", "fact.md", "gated.sh",
                            "mine", "quoted", "selftest.sh", "settings.json",
                            "settings.local.json", "tool.py",
                            "x_guidelines.md"],
    "attention.missing": ["gone.sh"],
    "attention.untested": ["probe.sh", "tool.py"],
    "attention.unused": ["selftest.sh"],
    "unused.once_run": [],
    "script.runs": {"gated.sh": (1, 1, "2026-05-13"),
                    "probe.sh": (1, 1, "2026-05-12"),
                    "selftest.sh": (0, 0, None),
                    "tool.py": (1, 1, "2026-05-02")},
    "attention.notes": [],
    "note.states": ["open 3d", "placed", "drained", "no id"],
    "notes.item": {"alpha": ["make /alpha faster", "cache the /alpha probe"],
                   "beta": ["fix /beta later"]},
    "census.json": True,
    "census.kinds": (2, True, False),
    "columns": {"memory.title": "== Items",
                "memory": ["name", "kind", "scope", "what", "it", "is"],
                "script.months": True, "script.cost": [],
                "script.named": True},
    "all.gone": (2, "skill_inventory.py: error: unrecognized arguments: --all"),
    "named_by.cut": "named by 5: a, b, c +2 more",
    "months": ["2025-11", "2025-12", "2026-01", "2026-02"],
    "gated.probes": [],
    "emit.piped": 141,
    "alpha.scripts": [("probe.sh", True, False),
                      ("gated.sh", True, True),
                      ("tool.py", True, False),
                      ("gone.sh", False, False)],
    "alpha.bundled": ["scripts/local.sh"],
    "probe.bundled": (["probe.list"], 1),
    "probe.bundle_edit": True,
    "alpha.journal": {"via_entries": 1,
                      "captured": ["open    make /alpha faster",
                                   "placed  cache the /alpha probe"],
                      "open": 1},
    "alpha.captured_ids": 2,
    "beta.usage": {"runs": 2, "last_run": "2026-05-11"},
    "placed": {"gated.sh": ["script:gated.sh — the workflow is a script now",
                            "script:gated — named without its extension"],
               "fact.md": ["memory:fact — checked and written"]},
    "placed.ids": 3,
    "placements": {"item": 3, "kind": 1, "gone": ["script:renamed.sh"]},
    "placements.line": "notes placed: 3 into an item, 1 into a kind and no item,"
                       " 1 into an item gone: script:renamed.sh",
    "beta.todos": 1,
    "probe.cases": {k: v for k, (_, v) in PROBE_CASES.items()},
    "beta.probes": ["block 1 uses unset DAY", "block 3 uses unset FROM_GONE",
                    "fixed path /tmp/k-$(id -u)", "fixed path /tmp/out",
                    "fixed path /tmp/r-$(id -u)/x"],
    "alpha.probes": [],
    "restate.cases": {k: v for k, (_, v) in RESTATE_CASES.items()},
    "beta.restates": [(15, "CLAUDE.md", 3, 1.0)],
    "attention.restates": ["beta"],
    "restates.view": True,
    "candidates": 2,
    "scoped": 1,
    "missing": "skill_inventory: no item named gamma",
    "view": True,
    "view.state": ["missing", "no self-test", "no self-test", "self-test"],
    "blurb": ["x" * BLURB_CHARS, "one…",
              "Log billable time to Jira for work that…"],
}


def piped_away() -> int:
    """emit's status when the reader closed the pipe, with fd 1 put back."""
    sys.stdout.flush()   # pending output must not be written into a dead pipe
    read_end, write_end = os.pipe()
    os.close(read_end)
    saved = os.dup(1)
    try:
        os.dup2(write_end, 1)
        return emit("x" * 4096)
    finally:
        os.dup2(saved, 1)
        os.close(saved)
        os.close(write_end)


def refused(*argv: str) -> tuple:
    """Status and last stderr line of a run argparse ends before the census.
    A run it fails to end is a census, which writes nothing to stderr."""
    p = subprocess.run([sys.executable, __file__, *argv],
                       capture_output=True, text=True)
    return p.returncode, (p.stderr.strip().splitlines() or [""])[-1]


def parsed(*argv: str) -> dict | None:
    """What the parser makes of argv, or None where it refuses it: argparse
    exits on a refusal, which would end the self-test unnamed."""
    try:
        return vars(parser().parse_args(argv))
    except SystemExit:
        return None


def kind_flag() -> tuple:
    """Status, and whether argparse named the kinds it would have accepted."""
    status, line = refused("--kind", "nonesuch")
    return status, "invalid choice" in line, all(k in line for k in KINDS)


def hint_grammar(hint: str) -> set[str]:
    """The choice lists, flags and positional names a hint's text states.
    Each is cut out before the next is read, so the words of a choice list
    are not also names; a metavar such as DIR is upper case, a name is not."""
    rest = HINT_CHOICES.sub(" ", hint)
    return (set(HINT_CHOICES.findall(hint)) | set(HINT_FLAG.findall(rest))
            | set(HINT_NAME.findall(HINT_FLAG.sub(" ", rest))))


def parser_grammar() -> set[str]:
    """The same three things, as the parser has them. --self-test is left
    out: it is the gate's flag, not the reader's."""
    have = set()
    for a in parser()._actions:
        if {"-h", "--self-test"} & set(a.option_strings):
            continue
        have.add(a.option_strings[-1] if a.option_strings else a.dest)
        if a.choices:
            have.add("|".join(a.choices))
    return have


def hint_gaps(command: Path) -> list[str]:
    """Where the command's argument-hint and the parser disagree.

    The hint is the only grammar a reader sees at the prompt, and it is text
    that nothing else checks, so it is compared with the parser both ways: a
    name, flag or kind on one side and not the other is a gap. A hint that
    cannot be read is a gap too, so the self-test names it instead of dying."""
    lines = command.read_text().splitlines() if command.is_file() else []
    line = next((ln for ln in lines if ln.startswith("argument-hint:")), None)
    if line is None:
        return [f"no argument-hint in {command}"]
    hint, have = hint_grammar(line.split(":", 1)[1]), parser_grammar()
    return ([f"hint only: {w}" for w in sorted(hint - have)]
            + [f"parser only: {w}" for w in sorted(have - hint)])


def narrowed(inv: dict, kind: str) -> tuple:
    """What survives --kind: one kind, and every measurement about it."""
    kept = narrow(inv, kind)["items"]
    return (sorted({i["kind"] for i in kept}),
            next(i["named_by"] for i in kept if i["name"] == "gated.sh"))


def observed(inv: dict) -> dict:
    by = {i["name"]: i for i in inv["items"]}
    a, up = by["alpha"], by["alpha"]["upkeep"]
    return {
        "census": sorted((i["kind"], i["scope"], i["name"])
                         for i in inv["items"]),
        "kinds": sorted({i["kind"] for i in inv["items"]}),
        "kind.flag": kind_flag(),
        "kind.narrowed": narrowed(inv, "script"),
        "kind.header": "kind script only" in render(narrow(inv, "script")),
        "name.parsed": {k: v for k, v in (parsed(
            "alpha", "--scope", "project", "--kind", "skill") or {}).items()
            if k in ("name", "scope", "kind")},
        "scope.alone": refused("--scope", "global"),
        "hint.gaps": hint_gaps(COMMAND),
        "desc": {f"{i['scope']}:{i['name']}": i["description"]
                 for i in inv["items"]},
        "named_by": {i["name"]: i["named_by"] for i in inv["items"]
                     if i["kind"] == "script"},
        "alpha.usage": a["usage"],
        "script.runs": {i["name"]: (i["usage"]["runs"], i["usage"]["sessions"],
                                    i["usage"]["last_run"])
                        for i in inv["items"] if i["kind"] == "script"},
        "alpha.cost": {k: round(v, 7) if isinstance(v, float) else v
                       for k, v in a["cost"].items()},
        "price.cases": [None if d is None else round(d, 9) for d in (
            dollars("claude-opus-5-5", {"cache_creation_input_tokens": 1,
                    "cache_creation": {"ephemeral_5m_input_tokens": 1}}),
            dollars("claude-opus-5-5", {"cache_creation_input_tokens": 1,
                    "cache_creation": {"ephemeral_1h_input_tokens": 1}}),
            dollars("claude-haiku-5-5", {"input_tokens": 1,
                    "cache_read_input_tokens": 100_000}),
            dollars("claude-haiku-5-5", {"input_tokens": 1,
                    "cache_read_input_tokens": 99_999}),
            dollars("claude-opus-5-5", {"input_tokens": 1, "speed": "fast"}),
            dollars("claude-opus-5-5", {"input_tokens": 1,
                                        "inference_geo": "us"}),
            dollars("claude-opus-5-5", {"cache_creation_input_tokens": 1}),
            dollars("<synthetic>", {"input_tokens": 0}))],
        "alpha.upkeep": {k: up[k] for k in
                         ("tracked", "commits", "edits_90d",
                          "uncommitted")},
        "mine.upkeep": by["mine"]["upkeep"],
        "ignored.upkeep": by["settings.local.json"]["upkeep"],
        "emit.piped": piped_away(),
        "alpha.scripts": [(Path(s["script"]).name, s["exists"],
                           s["tested"]) for s in a["scripts"]],
        "alpha.bundled": a["bundled"],
        "probe.bundled": (by["probe.sh"]["bundled"],
                          by["probe.sh"]["upkeep"]["commits"]),
        # The id is minted per run, so the text is compared with it normalised
        # away and its presence asserted separately — otherwise a reader that
        # silently dropped the id would still pass.
        "alpha.journal": {"via_entries": a["journal"]["via_entries"],
                          "captured": [f"{c['state']:<7} {c['text']}"
                                       for c in a["journal"]["captured"]],
                          "open": len(a["journal"]["open"])},
        "alpha.captured_ids": sum(1 for c in a["journal"]["captured"]
                                  if c["id"]),
        # A placement is asserted by the item it named, so a close that names a
        # kind and no item must appear against nothing.
        "placed": {i["name"]: [p["close"] for p in i["journal"]["placed"]]
                   for i in inv["items"] if i["journal"]["placed"]},
        "placed.ids": sum(1 for i in inv["items"]
                          for p in i["journal"]["placed"] if p["id"]),
        # The two no item answers to are counted, not lost, and survive --kind.
        "placements": inv["placements"],
        "placements.line": render(narrow(inv, "skill")).splitlines()[3],
        "beta.todos": len(by["beta"]["journal"]["open"]),
        "beta.usage": {k: by["beta"]["usage"][k] for k in ("runs", "last_run")},
        "probe.cases": {k: sorted(used_in(b) - set_in(b))
                        for k, (b, _) in PROBE_CASES.items()},
        "beta.probes": by["beta"]["probes"],
        "alpha.probes": a["probes"],
        "restate.cases": restate_cases(),
        "beta.restates": [(r["line"], Path(r["path"]).name, r["at"], r["share"])
                          for r in by["beta"]["restates"]],
        "restates.view": "restates    line 15 ~ " in render_one(inv, by["beta"]),
        "candidates": len(chosen(inv["items"], "CLAUDE.md", None)),
        "scoped": len(chosen(inv["items"], "CLAUDE.md", "project")),
        "missing": unknown(inv["items"], "gamma"),
        "view": "fixed path /tmp/out" in render_one(inv, by["beta"]),
        "view.state": sorted(
            ln.split("—")[1].strip()
            for ln in render_one(inv, a).splitlines()
            if ln.startswith("names ")),
        "blurb": [blurb("x" * BLURB_CHARS), blurb("one" + " " * 99),
                  blurb("Log billable time to Jira for work that hasn't"
                        " been logged yet.")],
        "gated.probes": by["gated.sh"]["probes"],
        "all.gone": refused("--all"),
        "named_by.cut": named_by(list("abcde")),
        "months": month_span("2025-11-30", "2026-02-01"),
        "note.states": note_states(),
        "columns": columns(inv),
    }


def columns(inv: dict) -> dict:
    """Each narrowed view's title and headers. Memory has no runs, cost or
    commits here, so only what it is remains, under a title with no notes;
    scripts ran in one month only, and every month of the span stays."""
    def heads(kind):
        lines = render(narrow(inv, kind)).splitlines()
        at = next(n for n, ln in enumerate(lines) if ln.startswith("== Items"))
        return lines[at], lines[at + 1].split()
    title, memory = heads("memory")
    _, script = heads("script")
    span = month_span(inv["attribution_since"], inv["generated"])
    return {"memory.title": title, "memory": memory,
            "script.months": sum(h in [m[2:] for m in span] for h in script)
                             == len(span),
            "script.cost": [h for h in script if h.startswith("$")],
            "script.named": "named" in script}


def attention_facts(inv: dict) -> dict:
    """Which items each kind of attention row names, and the census view."""
    rows = attention(inv["items"])
    names = lambda problem: sorted(r[1] for r in rows if r[0] == problem)
    view = render(inv)
    listed = {ln.split()[0] for ln in
              view.split("\n== Items", 1)[-1].splitlines()[2:] if ln.strip()}
    return {
        "attention.untracked": names("untracked"),
        "attention.missing": [Path(r[2]).name for r in rows
                              if r[0] == "missing script"],
        "attention.untested": names("no self-test"),
        "attention.unused": names("unused"),
        "attention.unpriced": names("unpriced"),
        "attention.restates": names("restates"),
        # A script nothing names but someone runs is used, so it is no row.
        "unused.once_run": [r[1] for r in attention(
            [{**i, "usage": {**i["usage"], "runs": 1}} for i in inv["items"]])
            if r[0] == "unused"],
        # The census lists no note: the queue's reader is /notes.
        "attention.notes": [r for r in rows if "note" in r[0]],
        # The one-item report lists the notes whose text names the item, and
        # only those: `not /alphabet` names neither alpha nor beta.
        "notes.item": {name: [n["text"] for n in notes([i])]
                       for name in ("alpha", "beta")
                       for i in inv["items"] if i["name"] == name},
        # The census is the attention rows and one table holding every kind
        # there is. No note is in it.
        # The JSON census holds the rows the text view's attention lists.
        "census.json": census_json(inv)["attention"] == rows != [],
        "census.kinds": (view.count("\n== "),
                 sorted({i["kind"] for i in inv["items"] if i["name"] in listed})
                 == sorted({i["kind"] for i in inv["items"]}),
                 "== Notes" in view),
    }


def note_states() -> list[str]:
    """captured_note's four answers: queued, closed, neither, and no id."""
    queue = {"abcd": {"age": "3d", "ticket": "-"}}
    got = [captured_note("[abcd] x", set(), queue),
           captured_note("[efgh] x", {"efgh"}, queue),
           captured_note("[ijkl] x", set(), queue),
           captured_note("x", set(), queue)]
    return [" ".join([g["state"], g.get("age", "")]).strip() for g in got]


def repeated_keys() -> list[str]:
    """The string keys any dict literal in this file names twice."""
    tree = ast.parse(Path(__file__).read_text())
    keys = [[k.value for k in d.keys if isinstance(k, ast.Constant)]
            for d in ast.walk(tree) if isinstance(d, ast.Dict)]
    return sorted({k for ks in keys for k in ks if ks.count(k) > 1})


def bundle_edit(inv: dict) -> bool:
    """An edit to a script's bundled file leaves the script uncommitted. It
    edits the fixture, so it runs after every other observation."""
    probe = next(i for i in inv["items"] if i["name"] == "probe.sh")
    (Path(probe["path"]).parent / "probe.list").write_text("y\n")
    return upkeep({"root": probe["path"]}, dt.date(2026, 6, 1),
                  probe["bundled"])["uncommitted"]


def self_test() -> int:
    with tempfile.TemporaryDirectory() as d:
        home, project, transcripts = fixture(Path(d))
        inv = inventory(home, project, transcripts, dt.date.today())
        seen, extra = observed(inv), attention_facts(inv)
        got = {**seen, **extra, "probe.bundle_edit": bundle_edit(inv)}
        render_choice(chosen(inv["items"], "CLAUDE.md", None))
    got["desc"] = {k: got["desc"][k] for k in EXPECTED["desc"]}
    # A dict keeps the last of two equal keys without a word, so a check that
    # reuses a key replaces the older one and both still read as passing.
    twice = sorted(set(seen) & set(extra) | set(repeated_keys()))
    for k in twice:
        print(f"FAIL {k}: the key is used twice, so one of its checks never runs")
    # An assertion is only an assertion once EXPECTED names it, so a key on one
    # side and not the other fails: otherwise a new check passes without running.
    only_got, only_exp = sorted(set(got) - set(EXPECTED)), sorted(set(EXPECTED) - set(got))
    for k in only_got:
        print(f"FAIL {k}: computed but absent from EXPECTED, so it was never checked")
    for k in only_exp:
        print(f"FAIL {k}: expected but never computed")
    bad = twice + only_got + only_exp + [k for k in EXPECTED if k in got and got[k] != EXPECTED[k]]
    for k in dict.fromkeys(k for k in bad if k not in twice):
        print(f"FAIL {k}: expected {EXPECTED[k]!r} got {got[k]!r}")
    print("skill_inventory self-test: " + ("FAIL" if bad else "ok"))
    return 1 if bad else 0


# --------------------------------------------------------------------- main

def chosen(items: list[dict], name: str, scope: str | None) -> list[dict]:
    hits = [i for i in items if i["name"] == name]
    return [i for i in hits if i["scope"] == scope] if scope else hits


def unknown(items: list[dict], name: str) -> str:
    near = sorted({i["name"] for i in items
                   if name.lower() in i["name"].lower()})
    hint = f"; did you mean {', '.join(near)}?" if near else ""
    return f"skill_inventory: no item named {name}{hint}"


def emit(text: str) -> int:
    """Print a report, or leave quietly when the reader has gone away.

    Python raises BrokenPipeError instead of dying on SIGPIPE, so `| head`
    would end in a traceback. 141 is the status a shell reports for a process
    killed by SIGPIPE, and pointing stdout at devnull keeps the interpreter's
    own final flush from printing a second complaint.
    """
    try:
        print(text, flush=True)
        return 0
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 141


def census_json(inv: dict) -> dict:
    return {**inv, "attention": attention(inv["items"])}


def one(inv: dict, name: str, scope: str | None, as_json: bool) -> int:
    hits = chosen(inv["items"], name, scope)
    if not hits:
        print(unknown(inv["items"], name), file=sys.stderr)
        return 2
    if len(hits) > 1:
        return emit(render_choice(hits))
    return emit(json.dumps(hits[0], indent=1) if as_json
                else render_one(inv, hits[0]))


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("name", nargs="?")
    ap.add_argument("--scope", choices=("global", "project"))
    ap.add_argument("--kind", choices=KINDS)
    ap.add_argument("--project", type=Path)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    return ap


def main() -> int:
    ap = parser()
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.scope and not args.name:
        ap.error("--scope picks between items that share a name; give the name")
    project = (args.project or find_project(Path.cwd())).resolve()
    inv = narrow(inventory(HOME, project, transcripts_for(HOME, project),
                           dt.date.today()), args.kind)
    if args.name:
        return one(inv, args.name, args.scope, args.json)
    return emit(json.dumps(census_json(inv), indent=1) if args.json
                else render(inv))


if __name__ == "__main__":
    sys.exit(main())

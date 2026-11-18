#!/usr/bin/env python3
"""jira_remaining_decide.py — the decision jira-remaining.sh prints: the
remaining-estimate argument for one issue and one effort, and why. That
script's header states the rules; this file applies them.

Usage:
    jira_remaining_decide.py <effort> <hours-per-day> <days-per-week> < issue.json
    jira_remaining_decide.py --self-test

The issue is jira-issue.sh's flat object on stdin. Prints "<arg>\\t<rendering>",
<arg> empty when the argument must be omitted. Exit 0 decided, 2 the effort is
not a Jira duration (named on stderr), or usage.
"""
import json
import re
import sys
from typing import NamedTuple

TOKEN = re.compile(r"(\d+(?:\.\d+)?)([wdhm])", re.I)
# Tokens must be whitespace-separated. `2h30m` is unambiguous arithmetic and
# still refused, because REST v3 refuses it: reading it here would only move
# the failure to the POST, where a worklog is already half-made.
SPACED = re.compile(r"^\s*\d+(?:\.\d+)?[wdhm](?:\s+\d+(?:\.\d+)?[wdhm])*\s*$", re.I)


def units(hpd: float, dpw: float) -> dict[str, float]:
    """Minutes per unit, in this instance's working day and week."""
    return {"m": 1.0, "h": 60.0, "d": hpd * 60.0, "w": dpw * hpd * 60.0}


def minutes(s, unit: dict[str, float]) -> float | None:
    """A Jira duration in minutes, or None when the whole string is not one.
    A partial reading is a wrong estimate, and a wrong estimate is the thing
    this script exists to stop."""
    if s is None or not SPACED.match(str(s)):
        return None
    return sum(float(m.group(1)) * unit[m.group(2).lower()]
               for m in TOKEN.finditer(str(s)))


def render(mins: float, hpd: float) -> str:
    """Minutes as the spaced Jira form, in this instance's days and hours."""
    mins = int(round(mins))
    if mins <= 0:
        return "0h"
    d, rest = divmod(mins, int(hpd * 60))
    h, m = divmod(rest, 60)
    parts = (f"{d}d" if d else "", f"{h}h" if h else "", f"{m}m" if m else "")
    return " ".join(p for p in parts if p)


class Estimate(NamedTuple):
    """An issue's time tracking, each duration as written and in minutes."""
    status: str
    done: bool
    orig_s: str | None
    rem_s: str | None
    spent_s: str | None
    orig: float | None
    rem: float | None
    spent: float | None

    @classmethod
    def of(cls, issue: dict, unit: dict[str, float]) -> "Estimate":
        orig_s, rem_s, spent_s = (issue.get("timeOriginalEstimate"),
                                  issue.get("timeRemainingEstimate"),
                                  issue.get("timeSpent"))
        return cls(issue.get("status") or "?",
                   (issue.get("statusCategory") or "").lower() == "done",
                   orig_s, rem_s, spent_s,
                   minutes(orig_s, unit), minutes(rem_s, unit), minutes(spent_s, unit))


def decide(issue: dict, effort_s: str, hpd: float, dpw: float) -> tuple[str, str] | None:
    """(argument, rendering), or None when the effort is not a duration."""
    unit = units(hpd, dpw)
    effort = minutes(effort_s, unit)
    if effort is None or effort <= 0:
        return None
    est = Estimate.of(issue, unit)
    arg, text = verdict(est, effort, hpd)
    return arg, text + overrun(est, effort, effort_s)


def verdict(est: Estimate, effort: float, hpd: float) -> tuple[str, str]:
    if est.orig is None and est.rem is None:
        return "", ("not set — no estimate on this ticket, so logging leaves it at 0h. "
                    "Suggest a real original estimate if it is sprint-bound.")
    if est.done:
        return "0h", f"0h — {est.status} is a Done status, so the clock closes with the worklog."
    if est.rem is None:
        return "", (f"unreadable ({est.rem_s!r}) — argument omitted, so Jira subtracts from the "
                    "original.")
    if est.rem <= 0:
        return "", (f"0h already — {est.status} is open but the burndown is spent "
                    f"({est.spent_s or '0h'} logged against an original of {est.orig_s or 'none'}). "
                    "Argument omitted: any number would raise it.")
    left = est.rem - effort
    if left <= 0:
        return "", (f"this effort exhausts the {est.rem_s} left — argument omitted so Jira floors it "
                    "at 0h. Set a real estimate if the work is not finished.")
    return render(left, hpd), f"{render(left, hpd)} (was {est.rem_s}; original {est.orig_s or 'not set'})"


def overrun(est: Estimate, effort: float, effort_s: str) -> str:
    """The OVER clause when what is spent plus this effort passes the original."""
    if est.orig is None or (est.spent or 0) + effort <= est.orig:
        return ""
    return f" — OVER: {est.spent_s or '0h'} spent plus {effort_s} exceeds the {est.orig_s} original"


# ---------------------------------------------------------------- self-test

def self_test_issue(status: str, category: str, orig, rem, spent) -> dict:
    return {"status": status, "statusCategory": category, "timeOriginalEstimate": orig,
            "timeRemainingEstimate": rem, "timeSpent": spent}


def self_test() -> int:
    # Imported here so the decision runs from a copy with no tap.py beside it.
    sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
    from tap import Tap
    t = Tap()
    live = self_test_issue("In Progress", "indeterminate", "8h", "4h", "4h")
    cases = [
        ("a ticket with no estimate omits the argument",
         self_test_issue("Backlog", "new", None, None, None), "2h", 8, ""),
        ("remaining already 0h on an open ticket omits it",
         self_test_issue("Testing", "indeterminate", "8h", "0h", "81h"), "1h", 8, ""),
        ("effort that exhausts what is left omits it", live, "4h", 8, ""),
        ("effort just short of what is left keeps a minute", live, "3h 59m", 8, "1m"),
        ("an unreadable remaining omits it rather than guessing",
         self_test_issue("In Progress", "indeterminate", "8h", "about a day", "4h"), "1h", 8, ""),
        ("a remaining with no original is still subtracted from",
         self_test_issue("In Progress", "indeterminate", None, "4h", None), "1h", 8, "3h"),
        ("an ordinary subtraction", live, "2h", 8, "2h"),
        ("a decimal effort", live, "1.5h", 8, "2h 30m"),
        ("days use this instance's working day, not 24h",
         self_test_issue("In Progress", "indeterminate", "2d", "1d", "1d"), "2h", 8, "6h"),
        ("a six-hour working day gives a different answer",
         self_test_issue("In Progress", "indeterminate", "2d", "1d", "1d"), "1h", 6, "5h"),
        ("weeks carry the working week",
         self_test_issue("In Progress", "indeterminate", "2w", "1w", "1w"), "2.5h", 8, "4d 5h 30m"),
        ("a Done ticket closes the clock",
         self_test_issue("Done", "Done", "8h", "2h", "6h"), "1h", 8, "0h"),
    ]
    for name, issue, effort, hpd, want in cases:
        got = decide(issue, effort, hpd, 5)
        t.check(got is not None and got[0] == want, name, f"want: {want!r}", f"got:  {got!r}")
    spent = self_test_issue("Testing", "indeterminate", "8h", "0h", "81h")
    t.check(decide(spent, "1h", 8, 5)[1]
            == "0h already — Testing is open but the burndown is spent (81h logged against an "
               "original of 8h). Argument omitted: any number would raise it. — OVER: 81h spent "
               "plus 1h exceeds the 8h original",
            "a spent burndown says so, with the overrun", decide(spent, "1h", 8, 5)[1])
    t.check(decide(live, "2h", 8, 5)[1] == "2h (was 4h; original 8h)",
            "the rendering names what it was and the original, and no overrun at the original")
    t.check("OVER" in decide(live, "4h 1m", 8, 5)[1], "a minute past the original is an overrun")
    t.check("OVER" not in decide(live, "4h", 8, 5)[1], "reaching the original exactly is no overrun")
    t.check([decide(live, e, 8, 5) for e in ("two hours", "2h30m", "0h", None)] == [None] * 4,
            "an effort that is no duration, unspaced, zero or absent is refused")
    t.check(render(0.4, 8) == "0h", "under half a minute renders as 0h")
    t.check(main(["jira_remaining_decide.py", "2h"]) == 2, "the wrong number of arguments is a usage error")
    return t.end()


# --------------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    if argv[1:2] == ["--self-test"]:
        return self_test()
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    effort_s, hpd, dpw = argv[1], float(argv[2]), float(argv[3])
    hit = decide(json.load(sys.stdin), effort_s, hpd, dpw)
    if hit is None:
        print(f"jira-remaining.sh: effort is not a Jira duration: {effort_s!r}", file=sys.stderr)
        return 2
    print(f"{hit[0]}\t{hit[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

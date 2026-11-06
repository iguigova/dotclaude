---
name: timelog
description: "Log billable time to Jira for session-history entries with no `**Billed:**` mark, across every ticket touched, in one confirmation. Writes only those marks to the journal. Invoke ONLY on explicit request (`/timelog`, \"log my time\"). Bare bills this session's entries, a Jira key that ticket's from every session, `--all` every session's."
argument-hint: "[TICKET | --all]   (default: the entries this session wrote)"
---

# /timelog — bill unlogged work to Jira

Logs time to Jira for every ticket with work not yet logged. What it writes to the journal is one `**Billed:**` mark on every entry it settled, through `journal.sh --bill`.

**One rule: every entry whose outcome is settled gets a mark.** Settled means the money is decided: billed, dropped in the confirmation, or not billable because its heading names no ticket. A billed entry names its worklog; the others say why they were not billed. An entry whose POST failed is not settled — it stays unmarked, and the next run is what gets it paid.

## 1. Find the unlogged work

Run the reader:

```bash
set -o pipefail
TICKET=""   # /timelog XYZ-1234 → TICKET="XYZ-1234"
SESSION="${CLAUDE_CODE_SESSION_ID:?/timelog: no session id; use --all}"
            # /timelog XYZ-1234 or /timelog --all → SESSION=""
~/.claude/scripts/journal_scan.sh ${TICKET:+"$TICKET"} | jq --arg session "$SESSION" '
  def open: map(select(.billed == null and .id != null));
  def mine: map(select($session == "" or .session == $session));
  def others: [.tickets[][], .no_ticket[]] | open
              | map(select($session != "" and .session != $session));
  { tickets:   (.tickets | map_values(open | mine)
                         | with_entries(select(.value | length > 0))),
    no_ticket: (.no_ticket | open | mine),
    others:    (others | {entries: length, sessions: (map(.session) | unique | length)}) }'
```

Both scopes are set **in this block**, never in an earlier one.
`pipefail` is load-bearing: the reader exits non-zero when the history holds headings it cannot read, and that is an error, not an empty result. Stop and show it — a missing result is never nothing to bill.

It returns JSON, each entry shaped as `journal_scan.sh --help` states:

- `.tickets` — this scope's open entries, by the key in each entry's header.
- `.no_ticket` — this scope's open entries whose header names no key.
- `.others` — `{entries, sessions}`: the open entries the session scope left out, and how many sessions wrote them. Zero when `SESSION` is empty.

Both buckets empty → tell the user "All caught up — every entry is marked." and stop. When `.others.entries` is above zero, say instead "Nothing unbilled from this session; `N` entries from `M` other sessions — `/timelog --all` to include them." and stop.

## 2. Scope, and the no-ticket split

The scope is set on §1's own lines, and it is also what the run marks:

- `/timelog` — this session's entries, ticketed or not. The default, so a run never bills another session's work unasked.
- `/timelog XYZ-1234` — pass the key as `TICKET` and set `SESSION=""`. That ticket's entries from every session come back, and `.no_ticket` is empty: naming the ticket is the scope.
- `/timelog --all` — set `SESSION=""`. Every session's entries come back.

Entries in `.no_ticket` are never billed on their own — §4 names how many, so writing that work off is a decision rather than a default, and §6 marks each with the reason its heading gives. Most are `chore:` or `docs:`: `journal.sh` heads work on the tooling that way even when a ticket's session surfaced it, so the reason is `chore work, not billed` (or `docs work`), never `no ticket`. Any other heading without a key, such as a review of a PR that names no ticket, is marked for what it is: `PR review, the PR names no ticket`. To bill some of it instead, name the key as an edit in §4; `the project's `jira-create.sh` helper` raises a ticket that does not exist yet.

## 3. Per ticket — fetch state, estimate, describe

For each ticket, silently (no questions):

- **State:** `~/.claude/scripts/jira-issue.sh <TICKET>` returns a **flat** JSON object (keys at top level — use `.summary`, not `.fields.summary`). Read `summary, status, timeOriginalEstimate, timeRemainingEstimate, timeSpent`.
- **Effort** — focused engineering effort the entries represent, NOT wall-clock. Round to 15 min; min `15m`. Calibration:
  - small bug/config: `15m`–`30m` · new function + tests: `45m`–`1h 30m` · new module/feature + tests: `2h`–`4h` · deep debugging / protocol work: `3h`–`6h`
  - Write the time in the format `jira-worklog.sh --help` states.
- **Remaining:** don't work it out. Once the effort is settled, `jira-remaining.sh` decides it:

  ```bash
  ~/.claude/scripts/jira-remaining.sh XYZ-1273 "2h"
  ```

  **stdout** is the argument §5 passes, and empty means omit it. **stderr** is one line saying what was decided and why — show that line in §4 verbatim, so the user approves the number that will actually be posted.

  Don't second-guess its answer.
- **Description:** one line per deliverable, drawn from that ticket's entries: `Topic — concise outcome`. Link commits and PRs (`git remote get-url origin` → GitHub URL) in the markup `jira-worklog.sh --help` states. Items can be code, PR/Greptile replies, decisions ("considered X, rejected for Y" with a link), or doc updates. No headers, date stamps, or filler.

## 4. One combined confirmation

Present a single block — one section per ticket — then one prompt:

> **Ready to log (`N` ticket(s)):**
>
> **`XYZ-1273`** (`<summary>`) — **`2h`** · remaining 2h (was 4h; original 8h)
> 1. <item>
> 2. <item>
>
> **`XYZ-1267`** (`<summary>`) — **`1h`** · remaining 0h already — In Progress is open but the burndown is spent (14.5h logged against an original of none). Argument omitted: any number would raise it.
> 1. <item>
>
> _`N` entries name no ticket in their heading and will be marked skipped, each with its reason: "<topic>" (`chore work, not billed`), …_
> _Name a key to bill any of them instead._  ← only if any
>
> _`N` unbilled entries from `M` other sessions — `/timelog --all` to include them._  ← only if `.others.entries` > 0
>
> Reply **`go`** to log all, or correct anything ("XYZ-1273 1h30m instead", "drop XYZ-1267", "skip").

The text after `remaining` is `jira-remaining.sh`'s stderr line from §3, copied verbatim.

Proceed only on explicit approval. `go`/`yes`/`ship it` = log as-is. Anything else is an edit — re-render the block with edits applied and re-ask. `skip` = stop without logging.

## 5. Log — loop the helper, one call per ticket

```bash
REMAINING=$(~/.claude/scripts/jira-remaining.sh XYZ-1273 "2h")
if WORKLOG=$(~/.claude/scripts/jira-worklog.sh --quiet XYZ-1273 "2h" ${REMAINING:+"$REMAINING"} <<'EOF'
Topic — concise outcome. See [PR #31](https://github.com/AcmeLabs/events-service/pull/31).
EOF
); then echo "XYZ-1273 worklog $WORKLOG"; else echo "XYZ-1273 failed — its entries stay unmarked"; fi
```

Args: `[--quiet] <issue-key> <time-spent> [remaining-estimate]`. A worklog already posted is corrected with `--edit <worklog-id>` on the same arguments, never by posting a second one, which would bill the time twice. `${REMAINING:+"$REMAINING"}` is what passes the argument or omits it — never pass `""`. Re-run `jira-remaining.sh` here rather than reusing §3's value. Capture the id `--quiet` prints: §6 marks each entry with it.

The `if` is what decides whether that ticket gets a mark at all. The helper prints the id before it checks the HTTP code, and on a failure prints nothing, so the capture is empty and the exit code is the only thing that says a POST happened. A ticket that failed is reported and the batch continues — don't abort it.

## 6. Mark what settled + confirm

Every entry §1 returned whose outcome is settled gets a mark, in one call per run. Three kinds settle, one does not:

- **billed** — `"<entry-id>: XYZ-1273 worklog 41233"`, naming the id §5 captured.
- **dropped in §4** — `"<entry-id>: skipped — <why the user dropped it>"`.
- **no ticket in the heading** — `"<entry-id>: skipped — <reason>"`, the reason §2 gives for that heading: `chore work, not billed` for the common case.
- **not settled — no mark** — the entries of a ticket whose POST failed (§5), and any entry whose worklog id came back empty (below). Nothing was paid, so nothing is recorded.

```bash
~/.claude/scripts/journal.sh \
  --bill "<entry-id>: XYZ-1273 worklog 41233" --bill "<entry-id>: XYZ-1273 worklog 41233" \
  --bill "<entry-id>: XYZ-1267 worklog 41234" \
  --bill "<entry-id>: skipped — chore work, not billed"
```

The ids come from `.tickets[…][].id` and `.no_ticket[].id`. An entry left unmarked is offered again on the next run.

The writer takes each mark on its own: it names the ones it refuses — malformed, an entry already billed, an id not in the file — writes the rest, and exits 1. Re-run the call with only the marks it named, corrected; never re-post the worklog, which exists already.

One refusal has no correction: a mark whose worklog number is empty, because the worklog does not exist. Leave those entries unmarked and say so; the next run offers the work again, which is what gets it paid.

Then confirm to the user: per ticket — time logged, new remaining, total on ticket; plus the count marked skipped, and any warnings (over estimate, no estimate, failed tickets).

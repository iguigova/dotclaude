---
name: review:pr
description: Review a GitHub PR — read the merge gate and your own review history, fetch the diff, check against coding standards, the team's security incident classes, codebase consistency, and import boundaries, produce educational insights, and (on confirmation) post the review with selected Critical/Medium inline findings back to GitHub.
argument-hint: <PR-URL or REPO#NUMBER>
---

Review this PR: $ARGUMENTS

## Mission

**Answer: "Is this change safe to merge?"**

This is a change-oriented review. Focus on the diff, not the entire file. Do not nitpick style in unchanged code. A restructuring of the code the diff touches is in scope, and §4 **Structure** asks for one; a refactor of code the diff does not touch is not.

## 1. Start

**Where the writes are.** §1–§5 read GitHub and write scratch into the PR's private working directory, with one exception: §1 names the session, which appends a title record to this session's transcript. §6 (post) and §7 (worklog, journal, title) are the only other steps that change anything outside the directory. Under plan mode, a read-only invocation, or any instruction to make no changes, pass `--no-name` and stop at §6 with the review delivered in chat. That is a complete deliverable, and §7 bills it once the session can write again.

```bash
~/.claude/scripts/gh-pr-start.sh [<pr-ref>]
```

Show what it prints; its `pr:` URL is `<pr-ref>` below.

Each later block recomputes `D` with `gh-pr-workdir.sh`. `"$D/pr.json"` is the fetch every later step reuses; `gh-pr-fetch.sh --help` states its JSON. The reviewer's login is `author`; there is no `user` field.

## 2. Read the Merge Gate and Your Own History

Two mechanical questions, answered before reading a single line of diff, because either can change what the review is for:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
jq -c '.gate' "$D/pr.json"
~/.claude/scripts/gh-pr-prior-review.sh < "$D/pr.json" > "$D/prior.json"
jq -c '{prior, delta_range, blocking_others,
        findings: [.findings[] | {id, path, line, replies: (.replies | length)}],
        others_threads: [.others_threads[] | {id, author, path, line, replies: (.replies | length)}]}' "$D/prior.json"
```

**The gate** answers the mission question in ways the diff cannot:

- **A failed check is a finding.** Name it in the review. If the diff plausibly caused it, that is **Critical** — say which change and why. If it is unrelated or flaky, say that instead of diagnosing it line by line; a red suite you did not cause is context, not your finding.
- **Pending checks** mean the evidence is incomplete. Say so rather than implying the suite is green.
- **`mergeable: CONFLICTING`** blocks the merge regardless of code quality. Report it.
- **A green suite is worth one line.**

**Your own history** comes from `gh-pr-prior-review.sh`; its `--help` states each field:

- `prior: null` — a first pass. Proceed to §3.
- `prior.stale: true` — **a second pass.** The PR has moved since you last reviewed it. `delta_range` is the range to read, `findings` are what you said last time, and each carries the `replies` it drew. `findings` sits at the top level of `"$D/prior.json"`, beside `prior`, not inside it. §4 has the rules.
- `prior.stale: false` — you have already reviewed this exact commit. Say so, show what you concluded last time — the `body` of your latest entry in `.reviews[]` in `"$D/pr.json"`, since `prior` carries only its state, commit and time — and ask whether to re-review before doing the work again. Do not silently redo it, and do not bill for it twice.
- **The reviewers in `blocking_others`** still gate this merge. **Approving does not clear them, and it is not your place to.** When you believe such a block is unnecessary, state the mechanism and the evidence, address it to its author, and leave the decision with them (§5, Open questions).
- **`others_threads`** is what §4 checks each finding against before calling it new.
- **When your own prior review is a stale `CHANGES_REQUESTED` and its findings are now fixed, an `APPROVE` is what clears it; a `COMMENT` leaves it standing.**

## 3. Load Relevant Coding Guidelines

The selector reads the step-1 fetch and prints the guideline files that apply:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
~/.claude/scripts/gh-pr-guidelines.sh < "$D/pr.json"
```

`Read` each path it prints **silently** — do not output their contents. Apply them during review.

A guideline states a general rule; the repo states what it actually uses. Where the two disagree — a guideline section written for a major version the repo does not pin, a convention the repo abandoned — **the repo wins, and the guideline is itself a finding** worth raising separately. Before applying a version-specific rule, check the pin in the repo's dependency manifest (requirements*.txt, pyproject.toml, Gemfile.lock, package.json).

## 4. Review the Diff

Build the diff index once — it is the source of truth for every line number you cite and for the import check below (and it's what the post step validates against). Pass the head SHA through from the fetch, so §6 can tell whether the PR moved under the review:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
jq -r '.diff' "$D/pr.json" > "$D/pr.diff"   # reuse the step-1 fetch, no re-download
~/.claude/scripts/gh-pr-diff-index.sh \
  --diff-file "$D/pr.diff" \
  --head-sha "$(jq -r '.head_sha' "$D/pr.json")" > "$D/pr-index.json"
```

**Read line numbers from it — never hand-compute `hunk_start + offset`.** A finding's line is the `new_line` of the line it concerns; in a `deleted` file, which has none, it is the `old_line` with `"side": "LEFT"`.

### Diff siblings horizontally

Where a directory holds several implementations of one interface, lay their bodies
side by side and look for a shared *shape*, not shared *names* — a common
decode-fetch-process-persist skeleton, a repeated control-flow staircase.

Rank before reading, too: a structural smell is what a metric catches and an eye
misses. The structure helper parses each changed source file at the merge base and
the head: per file, its size and a 1000-line crossing; per function the diff touches,
lines, complexity, nesting, exits and parameters at both commits. `--help` states
every field and every rule:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
~/.claude/scripts/gh-pr-structure.sh <pr-ref> \
  --index-file "$D/pr-index.json" > "$D/structure.json"
jq -r '.files[] | "\(.path) \(.lines_base)->\(.lines_head) cross=\(.crosses_threshold)",
       (.parse_errors // [] | .[] | "  parse error at \(.commit) lines \(.lines) in \(.function // "no function")"),
       (.functions // [] | .[] | "  \(.status) \(.name) complexity=\(.complexity) nesting=\(.nesting) exits=\(.exits) params=\(.params)")' \
  "$D/structure.json"
```

Start reading at the top of that ranking, not at the first file in the diff. A count
is where to look, never a finding. `functions: null` is a language the helper cannot
parse: read its functions by eye. A parse error is a text its grammar misread. One
inside a function makes that function's counts unreliable: read it by eye. One in no
function can hide a function the helper missed: read those lines by eye.

### Verify, don't infer

- **Read code at `head_sha`, never from the working tree.** The local checkout sits on whatever branch the session left it on — reviewing a PR branch while the tree is on `main` reads code where the PR's changes do not exist, and produces confident, wrong findings. **Never use Grep, Glob, Read or an Explore agent to reach repo code during a review.** Two helpers cover it:

  ```bash
  # a path you can already name
  ~/.claude/scripts/gh-pr-file.sh <pr-ref> <path> [<path>...]

  # finding which paths to name
  ~/.claude/scripts/gh-pr-grep.sh <pr-ref> --list [<glob>]
  ~/.claude/scripts/gh-pr-grep.sh <pr-ref> <ere-pattern> [<glob>]
  ```

  Both are pinned to the PR's head, and refuse when the author has pushed since `$D/pr.json` was fetched: the diff and the files would describe two commits, so re-run §1. This applies to everything you cite: the changed file, its callers, the model it constructs, the config it reads, the sibling that already solved the same problem.

- **When a finding turns on library or runtime semantics, run it.** Type coercion, truthiness, rounding, ORM lazy-loading, timezone arithmetic: reason about these and you will be wrong often enough to matter. Find the version the repo pins, reproduce the behaviour in a throwaway script, and quote the output in the finding.

Both cut the other way too: if you could not check something, it belongs in **Open questions** (§5), not in a finding stated as fact.

### Second pass — when `prior.stale` is true

The PR moved under your last review. Before reading the delta:

- **Re-verify every prior finding against the head.** `findings` in `"$D/prior.json"` are what you said; the `replies` are what the author says they did. **A reply is a claim, not evidence.** "Fixed: cast to int" is a starting point for a check, never a substitute for one. Confirm each against the code at `head_sha`, and report each as verified fixed, partly fixed, or still live — naming what you checked.
- **A finding that is still live keeps its severity.** Do not soften a Critical because the author engaged with it, and do not let four fixes out of five carry the fifth.
- **Do not re-post what is fixed.** Fixed findings belong in the summary as verified, not as fresh inline comments on the author's own fix.
- **Then read `delta_range` as its own diff** — a fix commit can introduce new defects, and it is reviewed on its own merits, not graded against the finding it answers.
- **Watch for fixes that move a defect rather than remove it.** A cast added at one call site and not its sibling, a guard added to the path you named and not the one you didn't.

### Acknowledge, don't duplicate

Before a finding goes into the report, compare it with `others_threads` in `"$D/prior.json"`. When another reviewer has already raised the same defect — same mechanism, even if anchored a few lines away — it is theirs to have raised and yours to confirm. The author should answer one thread per defect, not two:

- **It is still reported in full in chat**, with its severity and your evidence, marked `(confirms <author>'s <thread URL>)`. The thread URL is `https://github.com/<owner>/<repo>/pull/<N>#discussion_r<id>`.
- **It is posted as a reply in their thread**, not as a new inline comment (§6). The reply says it was confirmed independently and adds only what the thread lacks — a reproduction, a measurement, a test that pins the defect, a better fix. When it adds nothing, say so in one line.
- **Their read is a claim like any reply** — a bot's finding in particular. Verify it against the head before confirming. Where their mechanism or severity is wrong, the reply says what is actually true. Where the finding does not hold, it goes under **Checked and cleared** with the thread linked.
- **A thread the author has already answered** with a fix is a second-pass check of *their* finding: verify the fix against the head and reply only when it falls short.

Evaluate the changed code against these, roughly in order of impact — correctness first, process and docs last:

### Correctness — does it do what it says?
- Read the PR description, linked Jira ticket title, and any acceptance criteria
- Walk through the diff and verify the implementation matches the stated goal
- Flag anything that's described but not implemented, or implemented but not described
- Read the diff's own comments and docstrings as a spec, then check **every exit** of the function against what they claim. A guard that one branch applies and a sibling branch returns before reaching is the highest-yield defect in an otherwise careful PR — the author has already written down the rule the code breaks
- **A comment asserting a guarantee is a claim to test.** "This is typed, so bad values can't reach here", "the framework validates this" — check what the validator actually does with each input shape

### Defects — could it introduce a bug?
- Logic errors in the new code
- Edge cases not handled (nulls, empty collections, boundary values, concurrent access)
- Regressions — does it break existing behavior?
- Off-by-one errors, incorrect operator (AND vs OR, < vs <=)
- Resource leaks, missing error handling on I/O
- **Failure handling.** `coding_guidelines.md` → **Failure** states the rules. Each is found by tracing, not by reading the line it is on:
  - Follow a neutral default (`[]`, `{}`, `0`, `None`) from the failed read to its consumer, and name what the consumer does with it
  - Follow the exception to the handler that catches it, and say what state it leaves behind
  - A successful read that returns nothing is not settled either. "Nothing yet" (never configured, not synced) and "nothing wanted" (deliberately emptied) look the same, and code that treats the first as the second wipes data. A feature-flag or migration transition is where the two diverge: check what the newly enabled path does on its first run

### Security — can someone who should not, do this?

The SDLC reviews a change twice, the Reviewer then Security, and a blocking flaw from either goes back to the author. This section is the second pass. It reads the diff against two sources the team owns, fetched at run time:

```bash
~/.claude/scripts/gh-pr-security.sh <pr-ref>
```

- **`classes:`** is the team's incident classes, from the source the project names in `.claude/security_classes`. `Read` it, map the diff to every class it touches, and run each touched class's *Check in the diff* list in full. Name the classes in scope in the report. `classes: none` means the project keeps no list: review security from the persona and the guidelines alone, and say so in the report.
- **`persona:`** is the repository's Teambuild Security persona, its threat model and security standard. When one exists, `Read` it and review against its assets, attackers and standard. `none` means the repository has not generated one: review against the classes alone, and say so in the report.
- **Exit 2** means a source could not be read. Say which in the report, under **Open questions**, rather than presenting a short pass as a full one.

Every write path the diff adds or changes to persistent state is in scope, the ones no user directly triggers first: callbacks, jobs, cascades, admin overrides, migrations. For each, ask:

- **Access.** Is it gated server-side, by owner and by tenant? Hidden in the UI is not gated.
- **Input.** Does a request value reach a query, a shell, a path, a redirect or a template unbound?
- **Secrets and personal data.** Does a token, key or personal field reach a log, a response, an error or the repository?
- **Repetition.** Does a retried request, a double submit or a second callback charge, create or send again?

A security finding names who can reach the flaw, what they send and what they get. A suspicion with no attacker and no path is an **Open question**, not a finding.

### Testing — is it tested?
- **A change with no test is rejected.** Each new or changed behaviour the diff adds needs a test that exercises it. One without is a **Critical** finding, whatever else the PR does well: the SDLC rejects a PR without unit tests, with no exceptions. Legacy code the diff changes is held to the same rule: its tests land in this PR.
- Are the new behaviors covered by tests?
- Are edge cases and error paths tested?
- Do the tests actually assert meaningful things (not just "it doesn't crash")?
- Does any test **pin a defect in place**? Name such a test in the finding and say it needs inverting, or the fix will look like it breaks the suite
- **Does the test construct values production cannot produce, or skip the boundary it claims to cover?** A suite that builds models in-process never sees what the database returns; a `setattr` that skips validation plants a state the loader could never produce. Such a test passes for a reason unrelated to the behaviour it names
- Are mocks appropriate and not over-mocking?

### Structure — does it leave the code it touches harder to change?

Working code is not the bar. Before writing any other finding on a changed function, ask the larger question first:

- **Is there a reframing that deletes rather than moves?** A different state model, ownership boundary or default flow under which the branches, flags, modes or layer the diff adds never need to exist. Name it concretely, with a few lines sketching its shape. "Could be cleaner" is not a finding.
- **Does a refactor lower the number of concepts a reader must hold?** Code moved into new helpers or files with the same branches, the same flags and the same special cases is rearranged, not simplified.
- **Spaghetti growth** — a new conditional, boolean, nullable mode or early return inserted into an existing flow to serve one case. Its bar is one occurrence (`coding_guidelines.md` → **Two Bars**); the fix is a home of its own: a dispatcher, a policy, a typed model, a separate path.
- **A file the PR carries past 1000 lines** (`crosses_threshold`) asks whether it should be decomposed first. It stands as a finding unless the file stays clearly sectioned and the PR states why it should not be split.
- **Indirection that buys nothing** — a wrapper or pass-through that adds a name without removing a concept; a cast, `any`, optional parameter or silent fallback standing where the boundary could state its invariant.

Extracting shared code keeps its own bar of three (`coding_guidelines.md` → **Two Bars**); a structural finding is never a DRY finding in disguise.

### Efficiency — can it be done better?
- Unnecessary database queries or API calls
- N+1 query patterns
- Algorithmic inefficiency on hot paths
- DynamoDB-specific: scan vs query, missing indexes, unbounded scans, FilterExpression on key attributes
- Duplicated logic within the diff (DRY violations in new code)

### Standards — does it follow coding guidelines?
- Apply the loaded guidelines to **changed lines only**
- Focus on substantive violations, not cosmetic preferences

### Codebase consistency — does it match existing patterns?

Sample how the **rest of the repo** handles the same concerns the PR touches, and flag deviations that introduce inconsistency without clear justification. `gh-pr-grep.sh` (above) is how you sample:

```bash
~/.claude/scripts/gh-pr-grep.sh <pr-ref> --list          # what is there
~/.claude/scripts/gh-pr-grep.sh <pr-ref> '<ere>'         # who already does this
```

A search that returns nothing is evidence only once you have seen the listing — an empty result over a candidate set you never inspected is indistinguishable from searching the wrong place.

Check for:
- **Naming conventions** — do new files, components, functions, variables, and routes follow the naming patterns already established in sibling files?
- **File / folder structure** — is the new code placed where similar code lives? Are new directories justified or should the code land in an existing one?
- **API & BFF route patterns** — do new API routes follow the same middleware, error handling, auth, and response shape as neighbouring routes?
- **State management & data fetching** — does the PR use the same hooks, query patterns, or state patterns (e.g., react-query, formik, custom hooks) as the rest of the codebase, or does it introduce a one-off approach?
- **Test patterns** — do new tests follow the same setup/teardown, mocking strategy, and assertion style as existing tests in the same directory?
- **Component patterns** — do new UI components follow the same prop conventions, styling approach (CSS modules vs. utility classes vs. inline), and composition patterns as existing components?
- **Error handling** — is the error handling approach (try/catch, error boundaries, user-facing messages) consistent with how the rest of the app handles similar failures?
- **A convention the file states in a comment is still a convention.** Where a file documents a rule — a cast that must be applied, an ordering that must hold — new code in that file that ignores it is a deviation, cited against the comment

When flagging, reference the existing pattern you compared against (file + line or directory) so the author can see the precedent.

### Import boundaries — does the dependency direction stay legal?

There's no import-linter/ruff/ESLint boundary config in these repos, so check this by hand. The diff index already extracted the imports the diff **adds** (Python `import`/`from`, TS/JS `import … from`/`require()`), each with its file and `new_line`:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
jq '.files[] | {path, imports: [.imports[] | select(.in_docstring | not)]}
    | select(.imports | length > 0)' "$D/pr-index.json"
```

`in_docstring` marks an import that parses but sits inside a triple-quoted string — a restore snippet or a usage example, which is text, not a dependency. The filter above drops them; read them only when the docstring itself is what you are reviewing. Detection starts from "outside a string" per file, so a hunk opening mid-docstring leaves the flag unset rather than hiding a real import.

The extraction is mechanical; the boundary judgment is yours. Flag an added import that crosses a boundary the codebase keeps:
- **Layering direction.** Entry layers (`controllers`, `workers`, `schedulers`) import inward to `domains`/`services` and clients; inner layers must not import back out. A `domain`/`service` importing a controller/worker/scheduler — or a shared client/SDK importing an `app.*` layer — is a violation.
- **Module visibility.** A single-leading-underscore name or module (`_utils`, `_internal_helper`) imported from *outside* its own package is a violation — import the public surface instead.
- **No new cycles.** Sibling modules must not import each other into a loop (e.g. `rest_client` ↔ `ws_soap_client`). A `TYPE_CHECKING`-guarded import hides the import-time cycle but not the design-time coupling — flag the coupling, don't accept the guard as the fix.
- **Style boundaries** (Python guidelines): wildcard imports (`from x import *`) and relative imports where absolute is the norm, regardless of direction.

A layering or cycle violation is **Medium** — **Critical** if it forces a build-breaking cycle or crosses a packaging boundary. Cite the offending import line and the boundary it crosses.

### Documentation — do the docs still tell the truth?

When the diff changes behavior, commands, config, env vars, API shapes, defaults, or setup steps, verify the repo's README and other docs still match reality:
- **Truthfulness** — flag any README still describing behavior, flags, commands, examples, or outputs this PR changed or removed. Stale instructions and examples that would now fail are defects, not nits.
- **Completeness** — if the PR adds a feature, flag, endpoint, env var, or script that warrants docs, is the relevant README updated where comparable things are already documented?
- Check both the README nearest the changed files (service/package level) and the repo-root README. A doc that contradicts the code is **Medium** — or **Critical** if it would mislead an operator into a destructive or security-relevant action.

## 5. Report Back

There's no required format — structure the review however reads best for this PR. Two hard rules: be **truthful** (don't soften real problems, don't invent issues to pad the report) and be **thorough** (cover everything below that applies).

Cover:
- **Summary** — a sentence or two: what the PR does and your overall read. On a second pass, say so and name the range.
- **Merge gate** — failed or pending checks, a conflicting merge state, and whose `CHANGES_REQUESTED` still stands (§2). One line when everything is green.
- **Security** — the incident classes in scope, whether the repository's Security persona was used or there is none, and any source that could not be read (§4). Its findings sit with the rest under **Issues**.
- **Verified fixed** (second pass only) — each prior finding with what you checked to confirm it. This is the point of the pass; do not reduce it to "addressed".
- **Issues, worst first**, at three severities: **Critical** (bug, logic error, security flaw, data-loss risk → blocks merge), **Medium** (missing edge case, dead code, structural regression, DRY/perf concern, stale docs → should fix), **Low/Nit** (style, naming → optional). Give each a new-file line reference and a concrete fix.
- **What's good** — name what the PR does well; don't skip this. Include what you checked and **cleared**: a suspicion chased down and killed against a sibling precedent or a downstream grep is evidence the review was thorough, and it stops the author re-litigating it.
- **Confirmed from other reviewers** — each finding that matches an `others_threads` entry (§4) is marked with that thread's link, so the user sees which inline items become replies.
- **Open questions** — anything whose severity, or existence, you could not settle from the code: an external API's real response shape, a live data distribution, a deploy-time value, another reviewer's block whose basis you cannot see. Say what you could not verify, what it would change, and how to settle it. Never resolve one by guessing and never drop it silently — a Critical whose blast radius depends on an unread external contract is still a Critical, stated with its condition.
- **Codebase-consistency deviations** (cite the pattern broken), **import-boundary violations** (cite the crossing), and **documentation/README issues** — only when present.
- **Verdict** — one of four, with a one-line reason. Each maps to the GitHub event §6 posts. The events are `APPROVE` and `COMMENT` only: a review never formally requests changes:

  | Verdict | Event | When |
  |---|---|---|
  | Approve | `APPROVE` | No findings. |
  | Approve with Nits | `APPROVE` | Only Low/Nit findings; none is worth a round trip. |
  | Approve with follow-up | `APPROVE` | Mediums stand on evidence you checked, and none changes what the merged code does — a doc, example or test the author can fix after the merge. A §4 **Structure** finding never qualifies (§5, **Choosing a severity**). Each goes under **Should fix** in the body. |
  | Comment | `COMMENT` | A Critical stands on evidence you checked, or a Medium the author should not merge past — each under **Must fix before merge** in the body. Also when an **Open question gates a severity**: a Critical or Medium whose weight depends on a document, contract or data you could not read. |

  When other reviewers' blocks stand, say plainly that approving does not clear them (§2).
- **`★ Insight` blocks** wherever there's something genuinely worth learning — architecture, DynamoDB behavior, idioms, trade-offs. Be generous.

### Choosing a severity

The definitions above settle most findings. For the rest, in order:

1. **Does it move money, data, access, or availability the wrong way?** If yes and it reaches production, it is **Critical** — irrespective of how small the delta is or how narrow the trigger. A security finding with a named attacker and path always qualifies, and so does a new or changed behaviour with no test.
2. **Would a reader acting on it make a wrong decision?** A false comment, docstring, README line or test name is **Medium**, because its damage is that the next person stops checking. Wrong-but-harmless prose is a Nit.
3. **Does it leave the code it touches harder to change?** A finding under §4 **Structure** is **Medium**, and one the author should not merge past unless the PR already states why: once callers depend on a shape, restructuring it costs more than it does now. A naming or layout preference is a Nit.
4. **Does it self-correct?** A defect the system absorbs — a rounding difference that still reconciles, a value a downstream schema discards — drops one level. Say *why* it drops, so the author can disagree with the reasoning rather than the label.

A finding you cannot place after these four is an **Open question**, not a guessed severity.

## 6. Post the Review to GitHub (draft → confirm → post)

Posting is **never automatic** — a PR review is public and addressed to a colleague. Default flow:

1. **Show the full review** (§5) in chat first.
2. **Ask the user** which Medium findings to post inline, the overall **event** (`COMMENT` / `APPROVE`), and confirm they want it posted. If they decline, stop — the chat review is the deliverable.
   - **Every Critical finding is posted inline**, not offered as a choice. A Critical anchored on no diff line goes in the body instead, and says why.
   - **Medium findings are the user's choice** — offer each as an inline candidate. One not chosen gets a line under **Should fix** in the body.
   - **Low/Nit findings are never posted inline** and never offered as inline candidates.
   - **A finding that confirms another reviewer's thread is offered as a reply there**, never as a new inline comment (§4, **Acknowledge, don't duplicate**).
   - **The summary body ends with one `**Nits:**` line** — each Low/Nit finding in a few words with its `file:line`. Omit it when there are none.
   - On a second pass, note that an `APPROVE` replaces your own standing `CHANGES_REQUESTED` but leaves anyone else's in place (§2).
   - On a PR the `gh` user authored, GitHub accepts only `COMMENT`. The helper posts an `APPROVE` there as `COMMENT`, and its dry run shows `requested_event`, `event` and `event_note`. Tell the user before posting that the verdict will appear in the body only and will not count toward the merge gate.
3. On confirmation, write the **summary body** to `"$D/review-body.md"` and the **selected inline findings** to `"$D/review-findings.json"` as a JSON array `[{path, line, side, body}]`, `line` and `side` as §4 states, `side` defaulting to `RIGHT`. A reply to another reviewer's thread is `{in_reply_to, body}`, where `in_reply_to` is the thread's `id` from `others_threads`. Both follow **Posted text** below. Then post **one atomic review**:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
~/.claude/scripts/gh-pr-review-post.sh <pr-ref> \
  --event COMMENT \
  --body-file "$D/review-body.md" \
  --index-file "$D/pr-index.json" \
  --findings-file "$D/review-findings.json" \
  --dry-run            # validate line anchors first; drop --dry-run to post
```

`--index-file` is not optional. Invalid anchors abort with a list (fix the `line`), or pass `--drop-invalid` to fold them into the summary body instead. A reply that fails exits non-zero with the review already up; re-post only that reply. `--allow-shared-anchor` is only for a genuinely different defect on another reviewer's anchor. Run once with `--dry-run` to confirm the payload, then again without it. If it refuses on a moved head, re-run §1, §2 and §4 against the new head and re-check every finding.

### Posted text

What gets posted is an executive summary written fresh for the author, in the shape the `draft` skill sets. It is never the chat review pasted in: the mechanism walkthroughs, evidence, `★ Insight` blocks and severity codes (C1, M2) stay in chat.

The **summary body** is one line per finding plus the two sections that tell the author where the review's authority ends — roughly 20–25 lines:

```markdown
<One sentence: overall read of the PR.>

**Verified fixed** (second pass only)
- <prior finding, one line>: <what you checked to confirm it, one clause>.

**Must fix before merge**
1. **<Critical finding>** (inline): <what breaks, one line>. <Fix, one clause.>

**Should fix**
- <Medium finding, one line> (`file:line`). <Fix, one clause.>

**Open questions** (can't settle from the code)
- <what you could not verify>: <what it would change>, <how to settle it>.

**Checked and cleared:** <suspicions chased down and killed, semicolon-separated>.

**Nits:** <each Low/Nit in a few words, `file:line`>.
```

Omit a section that has no findings. A finding posted inline gets one line in the body marked `(inline)`, never a second full explanation. A finding posted as a reply is marked `(confirms [<author>](<thread URL>))` instead.

**Open questions and Checked-and-cleared both belong in the posted body**, not just in chat.

Each **inline comment** is **at most 60 words**, in three parts: the defect, its consequence, the fix. A **reply** to another reviewer's thread has the same budget. It opens with "Confirmed independently", and then says only what the thread does not already say.

## 7. After the Review

Journal and log the 15 minutes to the ticket. Both always run — a review delivered in chat but not posted is still billable work. The worklog is skipped only when the PR carries no ticket key (`.ticket` is empty); say so when you skip it.

A second pass is its own 15 minutes: it re-verifies every prior finding against new code and reads a new diff. Bill it.

The worklog items, in the markup `jira-worklog.sh --help` states. Omit the remaining-estimate argument — a review doesn't consume the ticket's estimate. Include:

- the PR ref and title
- the verdict with Critical/Medium/Nit counts
- the single headline must-fix finding, when there is one — omit the line on a clean approve
- on a second pass, the range reviewed and how many prior findings were verified fixed
- the posted review URL, or `Review delivered in chat; not posted at the author's request.` when §6 was declined

Journal, bill, then mark the entry billed — in **one** block:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
TICKET=$(jq -r '.ticket' "$D/pr.json")

cat > "$D/worklog.md" <<'EOF'
PR review — Org/repo#123 "<PR title>".
Verdict: Comment — 1 Critical, 2 Medium, 3 Nits.
Must fix: <the headline must-fix finding, one clause>.
Review posted: [Org/repo#123 review](<url printed by gh-pr-review-post.sh>)
EOF

ENTRY=$(~/.claude/scripts/journal.sh -t "PR Review: <repo>#<NN> (<TICKET> <title>)" --via /review:pr \
  -b "<verdict + key findings>" -b "Posted: <url>" \
  | sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p')

if [ -n "$TICKET" ] && WORKLOG=$(~/.claude/scripts/jira-worklog.sh --quiet "$TICKET" 15m < "$D/worklog.md"); then
  ~/.claude/scripts/journal.sh --bill "$ENTRY: $TICKET worklog $WORKLOG"
fi
```

**Tell the user whenever the mark was not written**, and why.

Then re-assert the session title:

```bash
~/.claude/scripts/gh-pr-name-session.sh <pr-ref>
```

Show the line it prints.

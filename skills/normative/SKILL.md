---
name: normative
description: Edit a document so it reads as the current source of truth, with no trace of how it evolved. Use for specs, API docs, READMEs, runbooks, contracts, policies — anything that should describe what IS, not what changed. Triggered by `/normative` or by the bare word "normative" in a request to edit a document.
argument-hint: <page-id-or-url-or-file-path> [edit instruction]
---

# Normative Edit Mode

Rewrite the target so a reader landing on it next month cannot tell, from the body alone, that any prior version existed.

## When this applies

Any document whose job is to declare the **current contract**:

- API specifications, schemas, OpenAPI docs
- README files
- Runbooks and operational procedures
- Architecture / design docs
- Policies, conventions, coding standards
- Confluence reference pages (KB articles, integration docs)

It does **not** apply to: release notes, changelogs, postmortems, retrospectives, ADR records, migration guides, deprecation announcements — these are *by design* historical and should retain evolution markers.

## The rules

### 1. No evolution language

Strip phrasing that references prior state — a "(formerly X)" aside, a "this page was updated to reflect…" preface, every phrase `normative_lint.py --help` lists.

If the spec currently says X, write X plainly. The history of *how* the doc got to X belongs in:
- The page revision history
- The PR description and commit message
- A separate release-notes / changelog page (linked, not inlined)

### 2. No transitional scaffolding

Remove sentences whose only function is to bridge from old behaviour to new:

- "Note: the legacy field is still accepted for backward compatibility." → either it's part of the contract (state it as a current rule) or it's a migration concern (move to a release note).
- "Clients should migrate by X." → release note, not spec.
- "The old endpoint will be removed in v3." → deprecation notice, not spec.

If a transitional rule is genuinely part of the *current* contract (e.g. "the API accepts both `from_date` and `from`, treating them as aliases"), state it as a present-tense rule with no historical framing.

### 3. Declarative, not defensive

State what a thing is or does, directly:

- No justifying a choice by what it is not: "analysis/ holds audits over src/newton", not "this is not product code, which is why it lives in analysis/". A crisp definitional contrast stays ("decay per event, not globally").
- No hedges ("arguably", "I think"), no commentary about the document itself, and no conversational second person ("you can't…"). First person belongs only in a message to people, never in a reference document.
- A recommendation is an imperative: "Expose a recent-impacts view".
- No sales labels on a deliverable ("Submit this", "the one to submit"): name it and describe it.
- No apology for the writer's setup: "narration is on-screen captions, so the video plays silently", never "there is no text-to-speech on this machine".

### 4. Knock-on cleanup

After removing the obsolete content, scan for **everything else that referenced it**:

- Examples that illustrated the removed behaviour → rewrite to illustrate something still present.
- Error codes, fields, or enum values that only existed because of the removed behaviour → remove or fold into surviving codes.
- Tables / lists / diagrams that called out the removed item → renumber or restructure as if it was never there.
- Cross-references in other sections → update or delete.
- Inline comments / review markers anchored to deleted text → named in the report.

A normative edit is **not** done until the document is internally consistent under the new rules.

### 5. Preserve everything not affected

Sections, tables, code blocks, headings unrelated to the change stay byte-for-byte identical. Don't reflow, reword, or "improve" surrounding content unless the edit logically forces it.

## Procedure

### 1. Resolve the target

- Confluence page → its ID or URL
- File path → that file
- No target given → the page or file the user just referenced
- If ambiguous, ask once before editing

### 2. Fetch current content

**Always** fetch fresh, never relying on an earlier read in the session.

- Confluence → `~/.claude/scripts/confluence-page.sh <id-or-url> --to <scratchpad>`. The path it prints is the body every later step edits and writes back.
- File → read it with the Read tool.

### 3. Identify everything affected

Before editing, list out:

- The primary text/section that needs to change
- Every example that uses the affected concept
- Every table row / error code / field that only exists because of the affected concept
- Every cross-reference elsewhere in the document
- Any inline-comment markers that anchor to the affected text

Edit *all* of these in one pass.

### 4. Apply the edits

Use targeted `Edit` calls, one per logical change.

Then run `~/.claude/scripts/normative_lint.py <path>` and judge each hit: rewrite it, or name the benign case it is. Re-read the result end-to-end (or grep for the removed concept) to confirm no orphan references survived.

### 5. Write back

- Confluence → `~/.claude/scripts/confluence-safe-update.sh --from <path>`, the path step 2 printed.

### 6. Report

Surface a table of what changed by section/location. Do **not** narrate the history of the edit ("first I removed X, then I…"). State the final outcome:

| Section | Change |
|---|---|
| §3 param table | Dropped "Maximum 30 days" constraint on `to`. |
| §8 error table | Removed `INVALID_DATE_RANGE` row; folded `from >= to` into `INVALID_PARAMETER`. |

Name every inline comment whose anchor text was removed.

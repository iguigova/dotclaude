---
name: benchmark
description: "Assess whatever we're working on against industry best practice, then give a grounded, trustworthy opinion. Produces a consistent shape every time — verified standards (cited or tagged), where practitioners disagree, my take conditioned on our context, and a clear recommendation. Triggered by `/benchmark` or the bare word \"benchmark\" when used to request an assessment (not when it means performance measurement)."
argument-hint: "[the approach/decision/topic to assess — defaults to whatever we're working on]"
---

# Benchmark Mode

Deliver the same trustworthy answer every time the user asks "what's the industry standard here, and what do you think?" — for whatever we're currently working on or stuck on. The value is **consistency and verifiability**: the user must be able to build on the output without re-checking it.

## The contract

Every response, regardless of topic, obeys these rules.

### 1. Two buckets, never smeared

Keep **fact** and **judgment** visibly separate. "What's standard" is a claim about the outside world. "My take" is a derivation from those facts.

### 2. Cite-or-tag every factual claim

Any factual claim about a standard, spec, tool default, version, or "what most teams do" must either cite its source inline (URL, doc, `file:line`) or be tagged `[unverified]`. A citation recalled from memory is a hypothesis, not evidence — verify before asserting. No bare "it's best practice to…" sentences.

### 3. Search when it's time-sensitive

If the claim can drift — framework/library defaults, tool versions, security guidance, pricing, "current" recommendations — **search the web before answering** rather than reciting from training. If a claim is stable and foundational (e.g. "parameterize SQL to prevent injection"), memory is fine, but say so. When in doubt, verify.

Read `currentDate` from the env block first and say it out loud. That date is "now", and the training cutoff sits months behind it, so recall about anything that ships is recall about a past. Search with an explicit recency filter, and for a claim about one vendor's product fetch that vendor's newsroom directly — search ranking favours the popular result, not the newest one.

A subagent inherits none of this and cannot see the env block. Dispatching research means pasting today's date and this rule into its prompt verbatim.

### 4. Flag recency and confidence

State how current and how confident each factual bucket is: "stable, long-established" vs. "was consensus as of my cutoff — the space moves fast, verified against <source> today." Never present cutoff-era consensus as live fact without this flag.

Cite each source's date, not just its name. An undated source is a stale source and is labelled one. About to write "as of <a year behind currentDate>" for a current-state claim? That is the signal to search again: either find a source within 60 days, or say "best available data: <date>, may be stale".

### 5. Surface disagreement

Where practitioners genuinely split, say so and give the trade-off — don't collapse a contested space into one tidy list.

### 6. Ground it in our context

Condition the assessment on what we're actually doing — our scale, stack, constraints, the specific thing we're struggling with. If context is missing and it changes the answer, ask one sharp question before committing; otherwise state the assumption you're making.

### 7. End with a recommendation, not a survey

Close with a clear "here's what I'd do and why," conditioned on the above. If you genuinely can't recommend without more information, say exactly what's missing.

Where the options are successive generations of one family — instance classes, GPUs, Postgres majors, model versions — the recommendation defaults to the newest GA generation. Naming the newer generation in a footnote and heading the answer with the older one is the failure this rule exists to stop. Departing from the default needs a cited reason: ecosystem support not yet GA, a budget ceiling the user stated, regional availability, or a benchmark showing the new generation regresses on our workload. A slightly higher hourly price is not one when performance per unit cost is better.

## Output shape

Use these headings (adapt wording to the topic, keep the order):

```
## Industry standard
<the established practice, each factual claim cited or [unverified], with recency/confidence flags>

## Where teams diverge
<the contested edges and the trade-off on each — omit only if there's genuinely no meaningful split>

## My take — for our context
<judgment derived from the above, conditioned on our scale/stack/constraints>

## Recommendation
<a clear, actionable call, and what (if anything) I'd verify or decide before acting>
```

Length follows the stakes: a quick call gets a tight version; a load-bearing architectural decision earns the full treatment. Never pad, never truncate the citation discipline to save space.

## Procedure

1. **Resolve the target.** With an argument, assess that. Bare invocation → assess whatever we're currently working on or debugging (the file, PR, design, or decision in play). Ask only if genuinely ambiguous.
2. **Separate what I know from what I must check.** List the factual claims the answer rests on. For each, decide: stable-enough-to-recall, or time-sensitive-must-search. Err toward searching.
3. **Verify.** Run the web searches; capture sources for citation. Read the relevant code/docs for our-context claims.
4. **Assemble in the output shape**, obeying all seven contract rules.
5. **Re-read before sending.** Confirm: no factual sentence is uncited and untagged; fact and opinion are in their own sections; recency/confidence is flagged; a concrete recommendation exists.

When "benchmark" could mean performance measurement instead, ask once which is meant.

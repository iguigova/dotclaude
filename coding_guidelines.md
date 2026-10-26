# Core Programming Principles

The most important properties of code are, in this order:

  1. CORRECT
  2. SIMPLE and READABLE
  3. EXTENSIBLE
  4. PERFORMANT

Always favor the human programmer over the machine. Prefer readability
and clarity of design over performance unless explicitly instructed
otherwise.

Everything here holds in every language. A rule that only makes sense
in one language lives in that language's guide — Clojure, Python, Go,
Haskell — and is never restated here.

## Code Structure and Design

1. Keep functions extremely simple and focused
   - Aim for single-line or maximum 2-line functions
   - Functions should do one thing only
   - Functions should take single arguments where possible
   - Don't combine multiple responsibilities
   - Follow Rich Hickey's definition of "Simple"

2. Build Modular, Composable Solutions
   - Functions should build upon each other
   - Prefer composable functions over complex single functions
   - Keep functions orthogonal (independently extensible)

## Two Bars, Not One

A *DRY* refactor extracts shared structure across call sites, and its bar is three
occurrences: a good abstraction captures a real pattern, carries a meaningful name,
and leaves the code easier to understand. Over-abstraction costs as much as
duplication.

A *clarity* smell lives inside one function — a six-deep conditional staircase, a
forty-line block, error handling threaded by hand — and its bar is one occurrence,
because it is a local comprehension problem and not duplication at all. Dismissing
one as "pragmatic" or "it only appears once" is applying the DRY bar to a clarity
problem. Flag it.

## Code Organization

- Define functions in the order they are called and needed
- Give the code clear entry points and make the flow obvious top to
  bottom
- Group related functions together
- Group related constants together at the top of the file
- Extract regex patterns into named constants at the top of the file
- Extract complex operations into named functions even if used once
- Extract a complex expression into a named binding
- Label sections of the code so they can be discussed and iterated on
  independently

## Naming

- Be brief where brevity costs nothing: add-distance and calc-distance
  over add-distance-to-obj and calculate-distance-info. Where the
  brevity reduces clarity, DON'T apply it
- Don't repeat in a function name a noun its arguments already make
  apparent: order-by-distance takes summaries, so
  order-summaries-by-distance says it twice
- Name an API wrapper for what it does, not for its plumbing:
  call-api, not handle-response
- Name an error-handling function for its primary purpose

## Invariant Args

Place invariant arguments (centroid-vec, centroid-mag) before varying
ones (summary, pgobj). A function whose invariant args come first can
be partially applied and then mapped over; otherwise every call site
needs a wrapper.

## Nesting

Do not nest functions through multiple levels of indentation. Prefer a
single level, and only inside simple constructs. Instead of nesting,
extract simpler helper functions and compose them in one final entry
function: that reads top to bottom and can be tested a piece at a
time, which n levels of branch and try/catch cannot.

## Failure

An error is a value the caller has to handle, not a shape that happens
to be falsy.

This section is the only place these rules live. Language guides add
mechanics — which exception types to catch, how to wrap an error, how
small a try block should be — and never restate the rules below.

- **Absent and unknown are different answers.** A read that failed, was
  missing, or would not parse must raise, or return something the
  caller can tell apart from a real result. Never a neutral `[]`, `{}`,
  `0`, `""` or null. Follow the value to its consumer before deciding:
  where the consumer replaces wholesale — a PUT of a whole collection,
  a field reset, a cache overwrite — no empty value is harmless,
  because "nothing" is the instruction to delete everything.
- **Never swallow an error into a falsy return.** Catching everything
  and returning false makes a transient failure indistinguishable from
  a legitimate "off", and emits no signal that anything went wrong.
- **Raise before the side effect, not after.** A failure that lands
  after a charge, a send or a provisioning call leaves state nobody
  reconciles. Inside a loop over items, guard each item, or one bad
  item abandons the rest half-done.

## Comments

Every comment is normative, concise and useful — or absent.

This section is the only place comment rules live. Language guides add
mechanics (docstring format, godoc requirements) and never restate the
rules below.

- **Useful** — say why, never what. a comment that explains what the
  code does means the code is unclear and needs improving. an unusual
  situation earns a comment; an ordinary one does not. commented-out code
  is never useful: delete it, because version control remembers it.
- **Normative** — state what is true now, and true at the commit that
  ships it. no history, no alternatives considered, no narrating how the
  code got here. equally, no future: naming a step, alarm, module or
  field that does not exist yet is the same defect as changelog voice.
  a sentence that must be deleted next commit fails this too — state the
  contract, which stays true, not the state, which does not.
- **Concise** — as few words as it takes. one that runs long gets cut
  down or deleted.
- **Self-contained** — no ticket keys, PR numbers, URLs, doc names,
  commit hashes, or person names. a reader must never leave the file to
  use it. if the reason lives only elsewhere, state the reason itself or
  say nothing.

Anything that fails these is dead weight: delete it rather than trim it.

## Verification

A change is ready to commit when the checks its CI runs pass locally, and
every source file it changed is fully covered by tests.

- **Run what CI runs.** Take the lint and test commands from the
  repository's CI workflow, and run them over the tree CI runs them on,
  at the tool version CI resolves. A clean check on the files you touched
  is no evidence that a whole-tree gate passes, and a whole-tree failure
  blocks every open change in the repository.
- **100% line coverage of every changed source file** — the whole file,
  not only the changed lines. A file no test loads is at 0%. Add tests
  until it holds.
- **Never loosen a check to pass it.** No skipped step, suppressed rule,
  deselected failing test, excluded line or lowered threshold: fix the
  cause. A tool that is not installed is a failure, never a pass.
- **Format, then verify.** Formatters write files and verifiers read
  them, so formatters run first and one at a time. The verifiers are
  independent and can run together.
- **The verdict carries counts** — tests passed, lines covered, offences
  found — so it can be checked against the run.
- **See a command's failure before suppressing it.** `2>/dev/null` on a
  tool whose usage error goes to stderr turns a refusal into an empty
  result, and an empty result reads as an answer: a 62-note queue
  reported as zero, 30 review apps as none. Check the status of the
  command itself, not of a pipe's last stage — `cmd | head` reports
  `head`'s. Redirect a stream only once you have read what it says.

## Implementation Best Practices

1. Code Quality
   - Test individual functions in isolation before combining
   - Consider edge cases and error conditions
   - Test code before suggesting it

2. Simplification
   - Question whether multiple steps are really needed
   - Look for opportunities to use existing services, libraries
   - Consider whether existing infrastructure can be reused
   - Question whether abstractions are really needed
   - Don't over-complicate solutions
   - Always prefer pure functions where possible, unless it will make
     the code ugly

## Anti-patterns to Avoid

- Don't combine code into large functions when smaller functions could
  be composed
- Don't write functions that do too many things
- Avoid disjointed and illogical organization
- Don't reach for shared mutable state when a simpler construct will do

## Communication and Problem-Solving

1. Interaction Style
   - Listen carefully to what the user is actually asking for
   - Confirm you understand the problem before rushing into writing code
   - Don't rewrite working code unnecessarily
   - Stay focused on the specific question asked
   - When corrected, adjust approach rather than defending
   - Match the surrounding code's style, even where you would do it
     differently
   - Address specific issues rather than trying to rebuild everything
   - When asked to JUSTIFY your code, often the user isn't criticizing, but trying to learn
   - Always look and see if your code can be made SIMPLER or MORE READABLE

2. Problem-Solving Approach
   - Think step by step through problems
   - Start small and build up complexity as needed
   - When something isn't working, acknowledge it quickly
   - Look for simpler solutions when encountering repeated errors
   - Focus on practical, working solutions over theoretical elegance
   - Address exact error messages directly
   - Fix specific problems rather than making broad changes

3. Solution Quality
   - Provide complete, working solutions
   - Make sure code examples actually work
   - Output full, complete code when requested; never elide a part of
     it with a comment standing in for what was left out
   - Follow schemas exactly as given
   - Consider implications of all technical decisions
   - Follow the user's preferred development workflow (e.g., REPL-driven)

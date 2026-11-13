# Shell Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

This guide holds what is specific to bash. The universal rules — priorities, function size, naming, nesting, failure, comments, verification — live in `coding_guidelines.md` and `style_guidelines.md` and apply here unchanged. Each section below gives their bash mechanics, with worked examples.

The scripts this guide governs live in `~/.claude/scripts/` and in each project's `.claude/scripts/`. Where a rule is house convention rather than published guidance, its source is the file that holds it.

---

## Scope: Bash, Not POSIX sh

### Bash Only
> *Source: [Google Shell Style Guide §1.1](https://google.github.io/styleguide/shellguide.html#s1.1-which-shell-to-use), [BashFAQ/031](https://mywiki.wooledge.org/BashFAQ/031)*

Bash is the only shell these scripts are written for. Google: "Bash is the only shell scripting language permitted for executables." Bash features — `[[ ]]`, arrays, `mapfile`, process substitution, `local` — are used freely. Portability to `sh`, dash or zsh is not a goal, and is never bought with uglier code.

### The Shebang
> *Source: `~/.claude/scripts/git_fact.sh`, `~/.claude/scripts/selftest.sh`*

An executable starts with `#!/usr/bin/env bash`. Google's guide asks for `#!/bin/bash` ([§1.1](https://google.github.io/styleguide/shellguide.html#s1.1-which-shell-to-use)); the house form is `env`, and every executable here uses it.

### Libraries
> *Source: [Google Shell Style Guide §2.1](https://google.github.io/styleguide/shellguide.html#s2.1-file-extensions), `~/.claude/scripts/tap.sh`, `~/.claude/scripts/gate_lib.sh`*

A file meant to be sourced has a `.sh` extension, no shebang, no executable bit, and a first line of `# shellcheck shell=bash`. Google: "Libraries must have a `.sh` extension and should not be executable." The directive tells ShellCheck the dialect a missing shebang would have named ([shellcheck(1)](https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md)).

A library sets no shell options. Those belong to the script that executes it (`~/.claude/scripts/memory_lib.sh`).

### When a Script Should Be Python
> *Source: [Google Shell Style Guide §1.2](https://google.github.io/styleguide/shellguide.html#s1.2-when-to-use-shell), [Bash manual — Shell Arithmetic](https://www.gnu.org/software/bash/manual/html_node/Shell-Arithmetic.html)*

Shell orchestrates commands: it runs tools, routes their output and acts on their exit codes. Write Python instead when the work is computing on data:

- nested or keyed structures beyond a flat array or one associative array
- parsing a format that `jq`, `awk` or `grep` cannot read in one step
- arithmetic beyond integers: bash evaluates "in fixed-width integers with no check for overflow"

Google puts the line at "more than 100 lines long, or that uses non-straightforward control flow logic." Treat length as a signal to look, and the list above as the test. `tap.py` is `tap.sh`'s Python twin, and `selftest.sh` sweeps both kinds alike, so moving a script to Python costs nothing in the gate (`~/.claude/scripts/gate_lib.sh`, `sweep`).

---

## File Layout

> *Source: [Google Shell Style Guide §4.1](https://google.github.io/styleguide/shellguide.html#s4.1-file-header), `~/.claude/scripts/git_fact.sh`*

A script reads top to bottom in this order:

1. The shebang.
2. The header comment: what the script is for, its exit codes, and a `Usage:` block naming every form, `--self-test` included. Google: "Every file must have a top-level comment including a brief overview of its contents."
3. `set -uo pipefail`.
4. The `--help` handler, which prints the header and exits 0.
5. Constants, then functions in the order they are called.
6. The self-test.
7. Argument parsing, then the body.

```bash
#!/usr/bin/env bash
# git_fact.sh — the verify command for a memory fact claiming something about a
# file in a repository.
#
#   0   every pattern matched
#   1   a file was read and its pattern is absent
#   75  the repo, the ref, or a path is not there — nothing learned
#
# Usage:
#   git_fact.sh <repo> <ref> <path> <pattern> [<path> <pattern> ...]
#   git_fact.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
```

The header is the documentation: `--help` prints it, and nothing else restates it. The handler runs before any network call, credential read or argument check, so `--help` works offline and with no arguments. A project's tooling gate may fail an executable script with no `-h`/`--help` handler.

---

## Shell Options

### `set -uo pipefail`, and No `-e`
> *Source: [Bash manual — The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html), [BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105), [BashPitfalls #60](https://mywiki.wooledge.org/BashPitfalls#set_-euo_pipefail), `~/.claude/scripts/selftest.sh`, `~/.claude/scripts/git_fact.sh`*

Every executable sets `set -uo pipefail` on the line after its header.

- `-u` treats an unset variable as an error, and a non-interactive shell exits on it (Bash manual). A typo stops the script instead of expanding to nothing.
- `pipefail` makes a pipeline's status that of "the last (rightmost) command to exit with a non-zero status" (Bash manual), so a failed producer is not hidden behind a successful `sed`.

Error handling does not rely on `set -e`. The shell ignores it in a `while`/`until` condition, in an `if` test, in any command of an `&&`/`||` list but the last, in any command of a pipeline but the last, and after `!`. If a function runs in one of those contexts, "none of the commands executed within the compound command or function body will be affected by the -e setting" (Bash manual). The same function exits on failure when called bare and runs on past it when called from `if`:

```bash
set -e
f() { false; echo "ran on"; }
if f; then echo t; fi    # prints "ran on", then "t"
```

BashFAQ/105 states the rules "are extremely convoluted, and they still fail to catch even some remarkably simple cases." So each command whose failure matters is checked where it runs (see [Exit Codes and Failure](#exit-codes-and-failure)).

### `-u` in Practice
> *Source: [Bash manual — Shell Parameter Expansion](https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html), `~/.claude/scripts/selftest.sh`*

Under `-u`, an argument that may be absent is read with a default, and a required one with a message:

```bash
# Good
case "${1:-}" in --self-test) self_test ;; esac
root=${2:?--root needs a folder}
dir=${GH_PR_WORKDIR_BASE:-/tmp/gh-pr-review-$(id -u)}

# Bad — exits on "unbound variable" when no argument is given
case "$1" in --self-test) self_test ;; esac
```

`${parameter:?word}` writes `word` to stderr and exits a non-interactive shell when the parameter is null or unset (Bash manual).

### `pipefail` and SIGPIPE
> *Source: [BashPitfalls #60](https://mywiki.wooledge.org/BashPitfalls#pipefail), `~/.claude/scripts/git_fact.sh`, `~/.claude/scripts/gate_lib.sh` (`self_test_of`)*

A reader that quits early — `grep -q`, `head` — closes the pipe, the writer dies of SIGPIPE, and `pipefail` reports the writer's failure. BashPitfalls: with pipefail, a `grep -q` pipeline "will sometimes claim 'foo not found' even when foo was found." Measured under bash 5.2:

```bash
set -uo pipefail
seq 1 100000 | grep -q 5; echo $?     # 141: grep matched, seq died of SIGPIPE
```

So a producer whose output is tested is captured first, and the test reads the capture:

```bash
# Good — the verdict is grep's
content=$(git -C "$dir" show "$ref:$path") || exit 75
grep -q -- "$pat" <<<"$content" || exit 1

# Bad — a match can report failure
git -C "$dir" show "$ref:$path" | grep -q -- "$pat" || exit 1
```

The self-test sweep runs every self-test with SIGPIPE ignored, as GitHub's runners do, so a writer cut off by an early reader fails locally with "Broken pipe" instead of first on a push (`gate_lib.sh`, `self_test_of`).

---

## Quoting

> *Source: [Google Shell Style Guide §5.7](https://google.github.io/styleguide/shellguide.html#s5.7-quoting), [ShellCheck SC2086](https://www.shellcheck.net/wiki/SC2086), [BashPitfalls #2](https://mywiki.wooledge.org/BashPitfalls#cp_.24file_.24target)*

Quote every expansion: `"$var"`, `"$(cmd)"`, `"${arr[@]}"`, `"$@"`. Google: "Always quote strings containing variables, command substitutions, spaces or shell meta characters." SC2086: "Quoting variables prevents word splitting and glob expansion."

```bash
# Good
cp -- "$file" "$target"
printf '%s\n' "$out"

# Bad — splits on spaces, expands globs
cp $file $target
echo $out
```

The gate does not enforce this. ShellCheck rates SC2086 at info severity, below the gate's `-S warning`: measured with shellcheck 0.10.0, `echo $out` raises SC2086 as a `note` and the gate passes it. Quoting is held in review.

Leave an expansion unquoted only where splitting or globbing is the intent, and say why with a ShellCheck directive carrying its reason:

```bash
# shellcheck disable=SC2053  # the pattern is a glob on purpose
if [[ "$2" == $3 ]]; then tap_ok "$1"
```

ShellCheck's directive page: "The comment can also be added at the end of the directive line" ([Directive](https://github.com/koalaman/shellcheck/wiki/Directive)).

A glob over the working directory is written `./*`, since "filenames can begin with a `-`" ([Google §6.5](https://google.github.io/styleguide/shellguide.html#s6.5-wildcard-expansion-of-filenames)). Never iterate over `ls` output ([BashPitfalls #1](https://mywiki.wooledge.org/BashPitfalls#for_f_in_.24.28ls_.2A.mp3.29)).

---

## Tests

### `[[ ]]` for Strings and Files
> *Source: [Google Shell Style Guide §6.3](https://google.github.io/styleguide/shellguide.html#s6.3-tests), [BashFAQ/031](https://mywiki.wooledge.org/BashFAQ/031), [Bash manual — Conditional Constructs](https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html)*

Tests use `[[ … ]]`. Google: "`[[ … ]]` is preferred over `[ … ]`, `test` and `/usr/bin/[`." Inside `[[ ]]`, "No WordSplitting or glob expansion will be done" (BashFAQ/031), `&&` and `||` combine tests directly, `==` matches a pattern, and `=~` matches a regular expression.

```bash
# Good
[[ "$dir" == /* ]] || dir="$ROOT/$dir"
[[ -d "$dir/.git" ]] || { echo "git_fact: no repository at $dir" >&2; exit 75; }
[[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || exit 2

# Bad — [ splits and globs, and has no patterns
[ $dir = /* ]
```

The left side of `[[ ]]` is quoted anyway, so every expansion in the file reads the same; the right side of `==` is quoted unless it is a pattern.

### Integers
> *Source: [Google Shell Style Guide §6.9](https://google.github.io/styleguide/shellguide.html#s6.9-arithmetic), `~/.claude/scripts/tap.sh`, `~/.claude/scripts/gate_lib.sh`*

An integer comparison in a test uses the test operators `-eq`, `-ne`, `-lt`, `-le`, `-gt`, `-ge`. Arithmetic uses `$(( … ))`: Google says "Always use `(( … ))` or `$(( … ))` rather than `let` or `$[ … ]` or `expr`."

```bash
# Good
TAP_N=$((TAP_N + 1))
[[ "$running" -ge "$JOBS" ]] && { wait -n; running=$((running - 1)); }

# Bad
let TAP_N=TAP_N+1
TAP_N=$(expr "$TAP_N" + 1)
```

Avoid `(( … ))` as a standalone statement: its status is 1 when the expression is zero, so `(( i++ ))` from 0 is a failure (Google §6.9).

---

## Arrays

> *Source: [Google Shell Style Guide §6.7](https://google.github.io/styleguide/shellguide.html#s6.7-arrays), [§6.8](https://google.github.io/styleguide/shellguide.html#s6.8-pipes-to-while), [Bash manual — Bash Builtins](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html), `~/.claude/scripts/gate_lib.sh` (`gate_names_changed`)*

A list is an array, never a space-separated string. Google: "Bash arrays should be used to store lists of elements, to avoid quoting complications." Expand it as `"${arr[@]}"`, one word per element.

Fill an array from a command with `mapfile -t` over process substitution. `-t` removes "a trailing DELIM from each line read" (`help mapfile`). Google prefers "process substitution or the `readarray` builtin (bash4+)" to piping into `while`.

```bash
# Good
local -a prose=()
mapfile -t prose < <(git -C "$repo" diff --name-only HEAD -- '*.md' | sort -u)
[[ "${#prose[@]}" -eq 0 ]] && return 0
name_lint.sh --gate "${prose[@]}"

# Bad — splits names on spaces and expands globs
prose=$(git -C "$repo" diff --name-only HEAD -- '*.md')
name_lint.sh --gate $prose
```

A command's arguments built up conditionally go into an array too, so a flag and its value stay separate words:

```bash
local -a args=(--csv)
[[ -n "$since" ]] && args+=(--since "$since")
tool "${args[@]}" "$file"
```

A set of keys is an associative array, declared with `declare -A` (`~/.claude/scripts/gh-pr-guidelines.sh`, `select_guidelines`).

---

## Functions and Locals

### Declaration and the Argument Comment
> *Source: [Google Shell Style Guide §4.2](https://google.github.io/styleguide/shellguide.html#s4.2-function-comments), [§7.1](https://google.github.io/styleguide/shellguide.html#s7.1-function-names), `~/.claude/scripts/tap.sh`, `~/.claude/scripts/gate_lib.sh`*

A function is written `name() {`, lower case with underscores. Its arguments are named in a trailing comment on that line, `# <arg> [<optional>] [<rest>…]`, because bash has no parameter list. When the name does not say what it does, a comment above it does. Google: "Any function that is not both obvious and short must have a function header comment."

```bash
# tap_is — the case holds when what was got is what was wanted.
tap_is() {  # <name> <got> <want>
  if [[ "$2" == "$3" ]]; then tap_ok "$1"
  else tap_not_ok "$1" "got:  $2" "want: $3"; fi
}
```

A function with a short body fits on one line: `lint_of() { shellcheck -S warning "$1"; }  # <script>`.

### Every Variable a Function Sets Is `local`
> *Source: [Google Shell Style Guide §7.5](https://google.github.io/styleguide/shellguide.html#s7.5-use-local-variables), [Bash manual — Shell Functions](https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html)*

Bash scopes variables dynamically: a function sees, and assigns, its callers' variables unless it declares its own. Google: "Declare function-specific variables with `local`." Declare them all on the function's first line, loop variables included:

```bash
each() {  # <fn> <dir> <file…>
  local fn=$1 dir=$2 f running=0; shift 2
  for f in "$@"; do
    ...
  done
}
```

### Declare, Then Assign a Command's Output
> *Source: [ShellCheck SC2155](https://www.shellcheck.net/wiki/SC2155), [BashPitfalls #27](https://mywiki.wooledge.org/BashPitfalls#local_var.3D.24.28cmd.29), `~/.claude/scripts/gh-pr-workdir.sh`*

`local var=$(cmd)` returns `local`'s status, not `cmd`'s. SC2155: "The exit status of the command is overridden by the exit status of the creation of the local variable." The same holds for `export` and `readonly`.

```bash
# Good — the failure reaches the caller
workdir() {  # <pr-ref>
  local refjson owner
  refjson=$("$HERE/gh_pr_ref.py" "$1") || return 1
  owner=$(jq -er .owner <<<"$refjson") || return 1
  ...
}

# Bad — $? is 0 whatever gh_pr_ref.py did
workdir() {
  local refjson=$("$HERE/gh_pr_ref.py" "$1") || return 1
}
```

ShellCheck flags SC2155 at warning severity, so the gate catches it.

---

## Command Substitution

> *Source: [Google Shell Style Guide §6.2](https://google.github.io/styleguide/shellguide.html#s6.2-command-substitution), [Bash manual — The Shopt Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html)*

Use `$(command)`, never backticks: "Use `$(command)` instead of backticks" (Google).

An assignment from `$(…)` takes the command's exit status, so the check goes on the assignment itself:

```bash
out=$("$@" 2>&1) || st=$?
scratch=$(mktemp -d) || { echo "  FAIL shellcheck: no scratch folder"; fail=1; return 0; }
```

Command substitution runs in a subshell: a variable it sets is gone when it returns. A function whose result is a value prints it to stdout; one whose result is a verdict returns a status. Never both through a global.

---

## Pipelines and Loops

### A Loop Reads From a Redirect, Not a Pipe
> *Source: [Google Shell Style Guide §6.8](https://google.github.io/styleguide/shellguide.html#s6.8-pipes-to-while), [BashPitfalls #8](https://mywiki.wooledge.org/BashPitfalls#grep_foo_bar_.7C_while_read_-r.3B_do_.28.28count.2B-.2B-.29.29.3B_done), [#12](https://mywiki.wooledge.org/BashPitfalls#read_.24foo)*

"Pipes create a subshell, so any variables modified within a pipeline do not propagate to the parent shell" (Google). A loop that sets anything reads from `< <(…)`, `<<<"$var"` or a file. Lines are read with `IFS= read -r`, which keeps leading spaces and backslashes (BashPitfalls #12).

```bash
# Good
while IFS= read -r p; do
  path_matches "$p" "$2" || continue
  printf '%s\n' "$p"
done <<<"$1"

# Bad — count is 0 after the loop
git ls-files | while read p; do count=$((count + 1)); done
```

### A Loop's Status Is Its Last Iteration's
> *Source: `~/.claude/scripts/gh-pr-grep.sh`, `~/.claude/scripts/gh-pr-guidelines.sh`*

A `while` or `for` loop exits with the status of the last command it ran. A body ending in `test && action` makes the loop fail whenever the last item fails the test, and a caller that checks the status discards everything printed before it. Filter with `|| continue`:

```bash
# Good
path_matches "$p" "$2" || continue
printf '%s\n' "$p"

# Bad — the loop exits 1 when the last path does not match
path_matches "$p" "$2" && printf '%s\n' "$p"
```

### Checking Every Stage
> *Source: [Google Shell Style Guide §8.1](https://google.github.io/styleguide/shellguide.html#s8.1-checking-return-values), `~/.claude/scripts/gate_lib.sh` (`gate_run`)*

`PIPESTATUS` holds every stage's status and "will be overwritten as soon as you do any other command" (Google), so it is copied on the next line or not used. Where a stage's output must be shown and its status kept, capture first and pipe the capture:

```bash
gate_run() {  # <command…>
  local out st=0
  out=$("$@" 2>&1) || st=$?
  [[ -z "$out" ]] || printf '%s\n' "$out" | sed 's/^/  /'
  [[ "$st" -eq 0 ]] || { echo "  FAIL ${1##*/} exited $st"; fail=1; }
}
```

---

## Exit Codes and Failure

### The Codes
> *Source: `~/.claude/scripts/git_fact.sh`, `~/.claude/scripts/selftest.sh`, `~/.claude/scripts/script_find.py`*

A script's header states every exit code it uses. The house meanings:

| Code | Meaning |
|---|---|
| 0 | done, or the claim holds |
| 1 | refused, or the claim is false; the reason is on stderr |
| 2 | usage error |
| 75 | no answer: the source it reads failed, timed out, or is not there (`EX_TEMPFAIL`) |

A reader of a production source uses 75 for nothing but a failed call to that source, and names the call on stderr (`script_find.py`). 75 is never folded into 1: "absent" and "false" are different answers.

### Check Each Command That Can Fail
> *Source: [BashPitfalls #19](https://mywiki.wooledge.org/BashPitfalls#cd_.2Ffoo.3B_bar), [BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105)*

Check the status where the command runs, with `||` and an action that says what failed:

```bash
cd "$root" || exit 2
git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
  || { echo "git_fact: $repo has no ref $ref; nothing learned" >&2; exit 75; }
```

Inside a function, return the status and let the entry point decide to exit. A function that would fail mid-way returns at the first failure, `|| return 1`, before any later side effect.

### Messages Go to Stderr
> *Source: [Google Shell Style Guide §3.1](https://google.github.io/styleguide/shellguide.html#s3.1-stdout-vs-stderr), `~/.claude/scripts/tap.sh`*

"All error messages should go to `STDERR`" (Google). Stdout carries only the script's result — data a caller parses, or TAP under `--self-test` — so a diagnostic never reads as an answer. A message starts with the script's name: `echo "git_fact: $path is not at $ref" >&2`.

### Trap ERR Only to Change the Code
> *Source: `~/.claude/scripts/gh-pr-grep.sh`, [Bash manual — Bourne Shell Builtins](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html)*

An `ERR` trap runs "each time a command's failure would cause the shell to exit when the -e option is enabled" (`help trap`), so it shares `-e`'s blind spots. Use it only to map an unexpected failure to the script's own code, as `gh-pr-grep.sh` does with `trap 'exit 2' ERR` so a crash never reads as a clean miss.

---

## Temporary Files and Traps

> *Source: [BashFAQ/062](https://mywiki.wooledge.org/BashFAQ/062), `~/.claude/scripts/tap.sh`, `~/.claude/scripts/selftest.sh`*

Create temporary files and folders with `mktemp` or `mktemp -d`, never a fixed or `$$`-based name, and remove them from an `EXIT` trap set on the same line:

```bash
fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
```

BashFAQ/062 notes that in Bash "you can simply use `trap cleanup EXIT`". A trap string is single-quoted, so the variable expands when the trap fires, not when it is set. A script holds one `EXIT` trap: a second `trap … EXIT` replaces the first, so a second resource joins the same cleanup.

---

## Self-Tests

> *Source: `~/.claude/scripts/tap.sh`, `~/.claude/scripts/gate_lib.sh` (`sweep`, `self_test_of`), `~/.claude/scripts/change_gate.py`*

Every script offers `--self-test`, which runs its cases and prints TAP through `tap.sh`: `ok N - <name>` or `not ok N - <name>` per case, detail lines as `# …`, and the plan `1..N` last. The sweep in `selftest.sh` finds every script whose text contains `--self-test` and fails one whose stdout is anything but that format, whose exit disagrees with its cases, or that has no cases.

- **Where it lives.** In a `self_test() {` function, or in an `if [[ "${1:-}" == --self-test ]]; then … fi` block, before argument parsing. Mutation leaves exactly those two forms alone (see below), so test code goes nowhere else.
- **A library guards its block** with `[[ "${BASH_SOURCE[0]}" == "$0" ]]`, so sourcing it never runs the tests.
- **Names.** A case's name says what holds — "a path absent at the ref learns nothing" — is unique in its script, and holds no `#` (`tap.sh`).
- **Stdout is TAP alone.** What the code under test prints goes to stderr; `tap_run` and `tap_fails` send it there.
- **Fixtures** are built in a `mktemp -d` folder, and a case that needs a repository makes a real one with `git init -q`.
- **The script runs as a child** when the test is of its exit code or output: `run() { "$self" "$@" >/dev/null 2>&1; echo $?; }`.

```bash
if [[ "${1:-}" == --self-test ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  tap_fails "nine is not big" big 9
  tap_run "ten is big" big 10
  tap_is "too few arguments is a usage error" "$(run a b)" 2
  tap_end
fi
```

---

## Complexity and mutation

> *Source: `~/.claude/scripts/change_gate.py`, `~/.claude/scripts/gate_lib.sh` (`gate_changed_code`), `~/.claude/scripts/selftest.sh` check 7, [lizard README](https://github.com/terryyin/lizard)*

**Complexity has no counter in the gate.** `change_gate.py` measures cyclomatic complexity with lizard, which reads none of the shells: its README's list of supported languages names thirty, and neither bash nor shell is among them. `change_gate.py` measures Python, JavaScript, TypeScript, Go, Ruby, C# and Dart, and states "Shell, Clojure and Haskell have no counter and are not measured." The bar from `coding_guidelines.md` still holds for shell, and review holds it.

**Every mutant on a changed line is killed.** `change_gate.py`'s mutator swaps, in the code part of each changed line and never inside a quoted string or a comment:

- `-eq`/`-ne`, `-lt`/`-ge`, `-gt`/`-le`, and the boundary forms `-lt`/`-le`, `-gt`/`-ge`
- `-z`/`-n`
- `&&`/`||`, `==`/`!=`
- `true`/`false`, `return 0`/`return 1`

For each mutant it runs the script's own `--self-test`, which passes only by exiting 0 with a TAP plan and no failed case. A surviving mutant fails the gate.

**Test code is not mutated.** The self-test's own code — a `self_test()` function, or an `if [[ "${1:-}" == --self-test ]]; then … fi` block — is left alone, because a weakened assertion is never caught by the assertion. Test code belongs there.

**An equivalent mutant is marked, with its reason.** A mutant no test can tell apart is accepted only when its line carries `# mutation: equivalent — <reason>`, the reason saying why. The marker exempts every mutant on its line, so a marked line carries the one operator it is about.

A boundary needs a case on each side of it:

```bash
big() { [[ "$1" -gt 9 ]]; }  # <n>

if [[ "${1:-}" == --self-test ]]; then
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  tap_fails "nine is not big" big 9    # kills -gt → -ge
  tap_run "ten is big" big 10          # kills -gt → -le
  tap_end
fi
```

`selftest.sh` runs `change_gate.py` over the code changed since HEAD, and `tooling_commit.sh` gates every tooling commit on `selftest.sh`.

---

## Style

> *Source: [Google Shell Style Guide §5.1](https://google.github.io/styleguide/shellguide.html#s5.1-indentation), [§7.2–7.3](https://google.github.io/styleguide/shellguide.html#s7.3-constants-and-environment-variable-names), [§6.6](https://google.github.io/styleguide/shellguide.html#s6.6-eval)*

- Indent two spaces, no tabs: "Indent 2 spaces. No tabs" (Google).
- Variables and functions are `lower_snake_case`. Constants, and anything exported, are `UPPER_SNAKE_CASE` (Google §7.3).
- `eval` is not used: "`eval` should be avoided" (Google §6.6). A command built at runtime is an array, run as `"${cmd[@]}"`.
- `printf '%s\n' "$x"` prints data; `echo` prints only fixed text.
- `case` dispatches on an argument or a file kind, one arm per line; an `if`/`elif` chain over the same value is a `case`.

---

## Tooling

> *Source: `~/.claude/scripts/gate_lib.sh`, `~/.claude/scripts/install_shellcheck.sh`, [shellcheck(1)](https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md)*

| Tool | Gate | What it holds |
|---|---|---|
| `bash -n` | `gate_syntax` | the file parses |
| `shellcheck -S warning` | `gate_shellcheck` | no finding at warning or error severity |
| `--self-test` sweep | `gate_self_tests` | every self-test prints valid TAP and passes |
| `change_gate.py` | `gate_changed_code` | every mutant on a changed line killed |

- **ShellCheck** is pinned at v0.10.0 and installed by `install_shellcheck.sh`. `-S` sets the minimum severity reported, from `error`, `warning`, `info`, `style`; the default is `style` (shellcheck(1)). The gate runs at `warning`, so info and style findings — SC2086 among them — are held in review.
- **A sourced file** is named to ShellCheck with `# shellcheck source=<path>` above the `.`/`source` line (shellcheck(1)).
- **A suppression** names the code and carries its reason on the same line: `# shellcheck disable=SC2053  # the pattern is a glob on purpose`. A directive before the first command is file-wide; otherwise it applies to the next command (shellcheck(1)).
- **A missing tool fails** the gate, naming what did not run and the command that installs it (`gate_lib.sh`, `need`).
- After editing anything in `~/.claude/scripts/`, run `~/.claude/scripts/selftest.sh`.

---

## Sources

This guide is compiled from these sources:

1. **[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)** — Google's bash style guide
2. **[ShellCheck wiki](https://www.shellcheck.net/wiki/)** — [SC2086](https://www.shellcheck.net/wiki/SC2086), [SC2155](https://www.shellcheck.net/wiki/SC2155), [Directive](https://github.com/koalaman/shellcheck/wiki/Directive)
3. **[shellcheck(1)](https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md)** — the ShellCheck manual: severities, directives
4. **[Bash Reference Manual](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)** — The Set Builtin, Shell Parameter Expansion, Conditional Constructs, Shell Functions, Shell Arithmetic, Bash Builtins (`mapfile`, `local`), Bourne Shell Builtins (`trap`)
5. **[BashFAQ/031](https://mywiki.wooledge.org/BashFAQ/031)** — `[` versus `[[`
6. **[BashFAQ/062](https://mywiki.wooledge.org/BashFAQ/062)** — temporary files
7. **[BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105)** — why `set -e` does not do what is expected
8. **[BashPitfalls](https://mywiki.wooledge.org/BashPitfalls)** — the common mistakes, numbered
9. **[lizard](https://github.com/terryyin/lizard)** — the complexity counter `change_gate.py` runs, and its language list
10. **House sources** — `~/.claude/scripts/tap.sh`, `gate_lib.sh`, `selftest.sh`, `change_gate.py`, `git_fact.sh`, `gh-pr-workdir.sh`, `gh-pr-grep.sh`, `script_find.py`

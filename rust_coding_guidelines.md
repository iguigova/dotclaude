# Rust Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

This guide holds only what is specific to Rust. The universal rules live in `coding_guidelines.md` (structure, naming, failure, security, comments, verification) and `style_guidelines.md` (layout on the page). This guide doesn't restate them. It shows them in Rust syntax.

---

## Toolchain and Edition

> *Source: [rustup — Overrides](https://rust-lang.github.io/rustup/overrides.html), [Cargo — rust-version](https://doc.rust-lang.org/cargo/reference/rust-version.html), [Edition Guide — Rust 2024](https://doc.rust-lang.org/edition-guide/rust-2024/index.html)*

A crate pins three things, each in its own place:

| What | Where | Example |
|---|---|---|
| The toolchain every build uses | `<repo>/rust-toolchain.toml` | `channel = "1.100.0"`, `components = ["rustfmt", "clippy"]` |
| The oldest Rust the crate supports | `rust-version` in `[package]` | `rust-version = "1.95"` |
| The language edition | `edition` in `[package]` | `edition = "2024"` |

- The toolchain file names an exact release, never `stable`, so a local build, CI and a teammate all compile with the same compiler and the same Clippy. A new Clippy adds lints; upgrading is its own change, with every new finding fixed in that change.
- `rust-version` "tells cargo what version of the Rust toolchain you support for your package." A feature newer than it is a defect, even when the pinned toolchain compiles it.
- New crates start on the 2024 edition (released with Rust 1.85.0). Moving an edition is its own change, made with `cargo fix --edition`.

---

## Formatting

> *Source: [Rust Style Guide](https://doc.rust-lang.org/style-guide/index.html#indentation-and-line-width), [rustfmt](https://github.com/rust-lang/rustfmt)*

Run `cargo fmt`, and CI runs `cargo fmt --check`. This is non-negotiable, and nobody hand-formats against it.

- "Each level of indentation must be 4 spaces" and "The maximum width for a line is 100 characters" (Style Guide). rustfmt's defaults are the Style Guide; a `rustfmt.toml` that changes them needs a reason.
- rustfmt does not break a long string literal or a long chain inside a macro it cannot parse. Those are broken by hand, by the rules in `style_guidelines.md`.

---

## Naming

> *Source: [API Guidelines — Naming](https://rust-lang.github.io/api-guidelines/naming.html)*

| Item | Case | Example |
|---|---|---|
| Crates, modules, functions, methods, locals, fields | `snake_case` | `review_status`, `fn parse_line` |
| Types, traits, enum variants | `UpperCamelCase` | `ReviewStatus`, `Severity::High` |
| Constants and statics | `SCREAMING_SNAKE_CASE` | `MAX_RETRIES` |
| Type parameters | short `UpperCamelCase` | `T`, `K`, `E` |
| Lifetimes | short `lowercase` | `'a`, `'de` |

- **An acronym is one word** (C-CASE): "use `Uuid` rather than `UUID`, `Usize` rather than `USize` or `Stdin` rather than `StdIn`." In snake case it is lower case: `is_xid_start`.
- **Conversions say their cost** (C-CONV): `as_` is free and borrows, `to_` is expensive or allocates, `into_` consumes `self`.
- **Getters have no `get_`** (C-GETTER): "With a few exceptions, the `get_` prefix is not used for getters in Rust code." `fn name(&self) -> &str`, not `fn get_name`.
- **Iterator methods** are `iter`, `iter_mut` and `into_iter` (C-ITER).
- **A module name is not repeated in its items.** `config::Config` is fine; `config::ConfigLoader::load_config` says "config" three times.

---

## Types

> *Source: [API Guidelines — Type safety](https://rust-lang.github.io/api-guidelines/type-safety.html), [API Guidelines — Interoperability](https://rust-lang.github.io/api-guidelines/interoperability.html), [API Guidelines — Future proofing](https://rust-lang.github.io/api-guidelines/future-proofing.html)*

### Make an invalid value unrepresentable

The type system is the cheapest test. A value that has been checked gets a type that says so, so it is checked once at the boundary and never again.

- **A newtype for a distinction the compiler should enforce** (C-NEWTYPE). A `ReviewId(Uuid)` cannot be passed where a `UserId(Uuid)` is expected.
- **An enum, not a `bool` or an `Option`, for an argument whose meaning the call site can't show** (C-CUSTOM-TYPE). `render(Format::Sarif)` reads; `render(true)` doesn't. Clippy's `fn_params_excessive_bools` and `struct_excessive_bools` catch the habit.
- **Parse, don't validate.** A constructor that checks its input returns `Result<Self, _>`, and the fields are private (C-STRUCT-PRIVATE), so no value skips the check.

```rust
/// A port a server may listen on: never 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Port(u16);

impl Port {
    /// # Errors
    ///
    /// Returns [`PortError::Zero`] for port 0.
    pub const fn new(n: u16) -> Result<Self, PortError> {
        if n == 0 {
            Err(PortError::Zero)
        } else {
            Ok(Self(n))
        }
    }

    pub const fn get(self) -> u16 {
        self.0
    }
}
```

### Derive the common traits

A public type implements `Debug` (C-DEBUG), and every one of `Clone`, `Copy`, `PartialEq`, `Eq`, `Hash`, `PartialOrd`, `Ord` and `Default` that makes sense for it (C-COMMON-TRAITS). Clippy's `derive_partial_eq_without_eq` catches an `Eq` left off. A type is `Send` and `Sync` where possible (C-SEND-SYNC).

A type that holds a secret implements `Debug` by hand, or wraps the secret in `secrecy::SecretString`, so a `{:?}` never prints it. That is the Rust mechanics of `coding_guidelines.md` → **Security**.

### Exhaustive matching

- A `match` on an enum the crate owns lists every variant. A `_ =>` arm turns a new variant from a compile error into a silent default, which is the absent-versus-unknown defect in `coding_guidelines.md` → **Failure**. Clippy's `wildcard_enum_match_arm` holds this.
- A public enum that will grow is `#[non_exhaustive]`, so downstream matches must carry the wildcard they need.

---

## Ownership and Borrowing

> *Source: [The Rust Book — Ownership](https://doc.rust-lang.org/book/ch04-00-understanding-ownership.html), [API Guidelines — Flexibility](https://rust-lang.github.io/api-guidelines/flexibility.html), [Clippy lints](https://rust-lang.github.io/rust-clippy/master/index.html)*

- **Borrow in arguments, own in fields.** A function takes `&str`, `&[T]` or `&Path` and lets the caller decide what to own. Taking `String` or `Vec<T>` is right only when the function keeps it (C-CALLER-CONTROL).
- **A clone is a decision, not a fix for the borrow checker.** Clone when the data really needs two owners. When the error is about lifetimes, restructure: borrow for a shorter scope, return the value instead of a reference, or split the struct. Clippy's `redundant_clone` and `implicit_clone` catch the clones that cost and buy nothing.
- **`Rc`/`Arc` and `RefCell`/`Mutex` are for shared ownership the design needs**, not for silencing the borrow checker. Shared mutable state is the anti-pattern `coding_guidelines.md` warns about; interior mutability makes it legal, not simple.
- **Lifetimes are named only where elision can't infer them.** Clippy's `needless_lifetimes` flags the rest.

---

## Error Handling

> *Source: [std::error::Error](https://doc.rust-lang.org/std/error/trait.Error.html), [The Rust Book — To panic! or Not to panic!](https://doc.rust-lang.org/book/ch09-03-to-panic-or-not-to-panic.html), [API Guidelines — C-GOOD-ERR](https://rust-lang.github.io/api-guidelines/interoperability.html#error-types-are-meaningful-and-well-behaved-c-good-err), [thiserror](https://docs.rs/thiserror), [anyhow](https://docs.rs/anyhow)*

What an error must *be* is governed by `coding_guidelines.md` → **Failure**. These are the Rust mechanics.

### `Result` for failure, `panic!` for a bug

"Returning `Result` is a good default choice when you're defining a function that might fail" (Book). A panic means the program is wrong — an invariant the code itself broke — and never stands for input that was bad, a file that was missing or a server that said no.

- **No `unwrap()` or `expect()` outside tests.** Each is a panic on a path someone will reach. Use `?`, a `match`, or `let … else`. Clippy's `unwrap_used` and `expect_used` deny both. Where an invariant really can't fail, say so three times: the `expect` message names the invariant, an `#[expect(clippy::expect_used, reason = …)]` says why it holds, and the function's `# Panics` section tells the caller.

```rust
/// The first byte of a frame.
///
/// # Panics
///
/// Panics if `frame` is empty, which [`Frame::new`] never allows.
#[expect(clippy::expect_used, reason = "a Frame is never empty")]
pub fn first(frame: &Frame) -> u8 {
    *frame.bytes().first().expect("a Frame is never empty")
}
```
- **No indexing that can panic on untrusted data.** `v[i]` and `&s[a..b]` panic out of range, and a `&str` slice panics off a character boundary. Use `get`, iterators or `split_at_checked`. Clippy's `indexing_slicing` and `string_slice` hold this.
- **No `todo!()`, `unimplemented!()` or `dbg!()` in a commit.** Clippy's `todo`, `unimplemented` and `dbg_macro` deny them.
- **`std::process::exit` only in `main`.** It skips destructors, so buffered output and temp files are lost. Everything else returns an error to `main`. Clippy's `exit` holds this.

### Library errors are types; application errors carry context

- **A library returns its own error enum**, one variant per way the caller can react, derived with `thiserror`. The caller matches on it; it never parses a message.
- **A binary returns `anyhow::Result`** from the code that only reports, and adds context at each step with `.context("reading the config")` / `.with_context(|| format!("reading {}", path.display()))`.
- **An error keeps its cause.** A variant wraps the underlying error with `#[source]` or `#[from]`, so the chain survives to the report. Never turn an error into a `String` mid-flight.
- **Messages are lowercase, with no trailing punctuation.** std: "Error messages are typically concise lowercase sentences without trailing punctuation." The type isn't named `Error` inside a module called `error` (Clippy's `error_impl_error`).

```rust
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("cannot read the config at {path}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("the config at {path} is not valid TOML")]
    Parse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
}

pub fn load(path: &Path) -> Result<Config, ConfigError> {
    let text = fs::read_to_string(path).map_err(|source| ConfigError::Read {
        path: path.to_owned(),
        source,
    })?;
    toml::from_str(&text).map_err(|source| ConfigError::Parse {
        path: path.to_owned(),
        source,
    })
}
```

### Absent is not unknown

`Option` means "there may be none", and `Result` means "this may fail". A read that failed is never returned as `None`, `Vec::new()` or `Default::default()`: `.ok()`, `.unwrap_or_default()` and `.unwrap_or(…)` on a `Result` turn a failure into a believable empty answer. Each of those calls on a `Result` is a decision the line states, not a shorthand.

```rust
// Bad — an unreadable file reads as "no rules"
let rules = fs::read_to_string(path).map(parse).unwrap_or_default();

// Good — the caller learns it failed
let rules = parse(&fs::read_to_string(path)?);
```

### `let … else` for an early return

```rust
let Some(token) = header.strip_prefix("Bearer ") else {
    return Err(AuthError::Scheme);
};
```

It keeps the happy path at the left margin, as `coding_guidelines.md` → **Nesting** asks. Clippy's `manual_let_else` points it out.

---

## Functions and Traits

> *Source: [API Guidelines — Predictability](https://rust-lang.github.io/api-guidelines/predictability.html), [API Guidelines — Flexibility](https://rust-lang.github.io/api-guidelines/flexibility.html)*

- **Constructors are associated functions**, `new` first, `with_…` or `from_…` for the others (C-CTOR). Past three or four optional fields, a builder (C-BUILDER).
- **Conversions are trait impls.** `From` for an infallible one, `TryFrom` for a fallible one, `FromStr` for parsing text, `AsRef` for a cheap borrow. Never `From` that can panic (Clippy's `fallible_impl_from`).
- **Generic over a trait when callers have several types; concrete otherwise.** `fn read(path: impl AsRef<Path>)` earns its generic; a generic with one caller is the premature abstraction `python_coding_guidelines.md` and every other guide warn about.
- **A trait has the fewest methods its users need.** One that grows to match one implementation is that implementation's interface, not an abstraction.
- **`#[must_use]`** goes on a function whose value is the point of calling it, such as a builder method or a pure computation. Clippy's `must_use_candidate` finds them.
- **Too many arguments is a missing type.** Clippy's `too_many_arguments` fires past seven, its default threshold. Group the arguments that travel together into a struct, rather than raising the threshold.

---

## Modules and Visibility

> *Source: [The Rust Book — Packages, Crates and Modules](https://doc.rust-lang.org/book/ch07-00-managing-growing-projects-with-packages-crates-and-modules.html), [API Guidelines — C-STRUCT-PRIVATE](https://rust-lang.github.io/api-guidelines/future-proofing.html#structs-have-private-fields-c-struct-private)*

- **Private by default.** An item is `pub` only when another crate needs it, and `pub(crate)` when only this crate does. The public surface is a promise; every `pub` widens it.
- **A binary crate is a thin `main.rs` over a `lib.rs`.** `main` parses arguments, calls the library and maps its error to an exit code. The library holds the logic, so integration tests can reach it.
- **One module per file**, named for what it holds. A `utils.rs`, `helpers.rs` or `common.rs` is a module whose purpose nobody named.
- **No glob imports** outside a `prelude` and a test's `use super::*` (Clippy's `wildcard_imports`, `enum_glob_use`).
- **Imports are grouped**: `std`, then external crates, then `crate::`. rustfmt keeps each group sorted.

---

## Unsafe

> *Source: [The Rustonomicon](https://doc.rust-lang.org/nomicon/), [rustc lint levels — forbid](https://doc.rust-lang.org/rustc/lints/levels.html#forbid), [Clippy — undocumented_unsafe_blocks](https://rust-lang.github.io/rust-clippy/master/index.html#undocumented_unsafe_blocks)*

- A crate that needs no `unsafe` sets `unsafe_code = "forbid"`. "The 'forbid' level can not be overridden to be anything lower than an error", so no module can opt back in.
- A crate that needs it keeps it in one small module with a safe API over it. Each `unsafe` block carries a `// SAFETY:` comment naming the invariant that makes it sound, and each `unsafe fn` a `# Safety` doc section naming what the caller must uphold (Clippy's `undocumented_unsafe_blocks`, `missing_safety_doc`). With `unsafe_op_in_unsafe_fn` denied, the body of an `unsafe fn` still needs its own `unsafe` blocks.
- An `unsafe` block is tested under Miri (`cargo +nightly miri test`), which catches undefined behaviour the tests alone don't see.

---

## Concurrency and Async

> *Source: [The Rust Book — Fearless Concurrency](https://doc.rust-lang.org/book/ch16-00-concurrency.html), [tokio::task::spawn_blocking](https://docs.rs/tokio/latest/tokio/task/fn.spawn_blocking.html), [Clippy — await_holding_lock](https://rust-lang.github.io/rust-clippy/master/index.html#await_holding_lock)*

- **Never block an async task.** tokio: "issuing a blocking call or performing a lot of compute in a future without yielding is problematic, as it may prevent the executor from driving other futures forward." Blocking I/O or long compute goes to `tokio::task::spawn_blocking`, or to a dedicated thread when it lives long. `std::thread::sleep` in async code is `tokio::time::sleep`; a `clippy.toml` `disallowed-methods` entry holds that.
- **No lock held across an `.await`.** A `std::sync::MutexGuard` held over an await point can deadlock the runtime (Clippy's `await_holding_lock`). Scope the guard in a block that ends before the await, or use `tokio::sync::Mutex` when the critical section must await.
- **A spawned task has an owner.** Keep its `JoinHandle` and await it, or put it in a `JoinSet`, so its error and its panic reach someone. A task nobody awaits is the fire-and-forget defect.
- **A `Mutex` around a counter or a flag is an atomic** (Clippy's `mutex_atomic`, `mutex_integer`). Choose the memory ordering on purpose; `SeqCst` is the safe default when unsure.
- **Prefer a channel to shared state** when threads hand work over. `Arc<Mutex<_>>` is for state that really is shared.

---

## Documentation

> *Source: [rustdoc book](https://doc.rust-lang.org/rustdoc/how-to-write-documentation.html), [API Guidelines — Documentation](https://rust-lang.github.io/api-guidelines/documentation.html)*

This section covers rustdoc mechanics only. What a comment may say at all is governed by `coding_guidelines.md` → **Comments**.

- **Every public item has a `///` doc comment**, its first line a one-sentence summary. `//!` at the top of `lib.rs` or a module says what the crate or module is for.
- **A function that can fail or panic says how** (C-FAILURE): a `# Errors` section for each error it returns, `# Panics` for each panic, and `# Safety` for an `unsafe fn`. Clippy's `missing_errors_doc` and `missing_panics_doc` find the gaps.
- **Examples are tests.** A code block in a doc comment compiles and runs under `cargo test`. It uses `?`, not `unwrap` (C-QUESTION-MARK).
- **Link with intra-doc links**: `` [`Port::new`] ``, never a URL to the same crate's docs. A dead link is only a warning, and `cargo doc` still exits 0, so the check is `RUSTDOCFLAGS="-D warnings" cargo doc --no-deps`.
- **Identifiers in prose go in backticks.** Clippy's `doc_markdown` finds the bare ones, and a `clippy.toml` `doc-valid-idents` list names the project's proper nouns, such as `GitHub` and `OAuth`, so they pass without backticks.

---

## Testing

> *Source: [The Rust Book — Test Organization](https://doc.rust-lang.org/book/ch11-03-test-organization.html), [proptest](https://docs.rs/proptest/latest/proptest/), [cargo-llvm-cov](https://github.com/taiki-e/cargo-llvm-cov)*

### Where tests live

- **Unit tests** sit in the file they test, in a `tests` module marked `#[cfg(test)]`, and reach private items through `use super::*`.
- **Integration tests** go in `<crate>/tests/`, one file per area, and see only the public API. A helper they share goes in `<crate>/tests/common/mod.rs`, so Cargo doesn't run it as a test of its own.
- **Doc tests** are the examples in the docs, and they run too.

### How tests read

- **A test may unwrap.** The Book says panicking is right in tests, and a test that returns `Result<(), Box<dyn Error>>` can use `?`. A `clippy.toml` with `allow-unwrap-in-tests = true` and `allow-expect-in-tests = true` keeps the production lints on.
- **One behaviour per test, named for it**: `fn zero_is_not_a_port()`, not `fn test_port_2()`.
- **`assert_eq!(got, want)` over `assert!(got == want)`**, since it prints both sides on failure. Add a message when the values alone don't say which case failed.
- **A table of cases is a loop over an array of tuples**, with the case's name in the assertion message.

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_is_not_a_port() {
        assert_eq!(Port::new(0), Err(PortError::Zero));
    }

    #[test]
    fn every_other_number_is_a_port() {
        for n in [1, 80, u16::MAX] {
            assert_eq!(Port::new(n).map(Port::get), Ok(n), "port {n}");
        }
    }
}
```

### Properties

`coding_guidelines.md` → **Verification** asks for a property test wherever the code has a law. In Rust the tool is `proptest`:

```rust
proptest! {
    #[test]
    fn parse_undoes_display(n in 1..=u16::MAX) {
        let port = Port::new(n).unwrap();
        prop_assert_eq!(port.to_string().parse::<Port>(), Ok(port));
    }
}
```

### Coverage

`coding_guidelines.md` → **Verification** holds every changed file at 100% line coverage. `cargo llvm-cov` measures it; `cargo llvm-cov --fail-under-lines <MIN>` exits 1 below the floor, and `--lcov --output-path lcov.info` writes a report per file. Install it with `cargo install --locked cargo-llvm-cov`.

### Time and the network

- **A test that sleeps is a flaky test** (`coding_guidelines.md` → **Verification**). Under tokio, `#[tokio::test(start_paused = true)]` and `tokio::time::advance` move time without waiting. Both need tokio's `test-util` feature, enabled in `[dev-dependencies]` only.
- **A test talks to a local server it starts**, such as an `axum` router bound to `127.0.0.1:0`, never to a real service.

---

## Lints

> *Source: [Cargo — the `[lints]` section](https://doc.rust-lang.org/cargo/reference/manifest.html#the-lints-section), [Cargo — `workspace.lints`](https://doc.rust-lang.org/cargo/reference/workspaces.html#the-lints-table), [Reference — the `expect` attribute](https://doc.rust-lang.org/reference/attributes/diagnostics.html#the-expect-attribute), [Clippy lints](https://rust-lang.github.io/rust-clippy/master/index.html), [Clippy configuration](https://doc.rust-lang.org/clippy/lint_configuration.html)*

### The policy lives in the manifest

The lint levels go in `Cargo.toml`, never in a `#![deny(…)]` at the top of `lib.rs`. One table governs every target, tests and examples included, and a reviewer reads one place. In a workspace they go in `[workspace.lints]`, and each member says `[lints] workspace = true` (respected as of Cargo 1.74).

```toml
[lints.rust]
unsafe_code = "forbid"
rust_2018_idioms = { level = "deny", priority = -1 }
unsafe_op_in_unsafe_fn = "deny"
missing_debug_implementations = "deny"
unused_qualifications = "deny"

[lints.clippy]
all = { level = "deny", priority = -1 }
# Restriction lints are picked one at a time, never the whole group.
allow_attributes = "deny"
allow_attributes_without_reason = "deny"
dbg_macro = "deny"
exit = "deny"
expect_used = "deny"
indexing_slicing = "deny"
string_slice = "deny"
todo = "deny"
unimplemented = "deny"
unwrap_used = "deny"
wildcard_enum_match_arm = "deny"
# High-signal pedantic and nursery lints.
cast_lossless = "deny"
derive_partial_eq_without_eq = "deny"
doc_markdown = "deny"
manual_let_else = "deny"
missing_errors_doc = "deny"
missing_panics_doc = "deny"
redundant_clone = "deny"
wildcard_imports = "deny"
```

- `clippy::all` is the default set (correctness, suspicious, style, complexity, perf). The group gets `priority = -1`, so a lint named on its own line overrides it.
- **Restriction lints are chosen one by one.** Clippy's restriction group holds lints that contradict each other, so enabling it whole is never right.
- **Pedantic and nursery lints are chosen one by one too**, each kept only while it is actionable. A lint that mostly produces suppressions is removed from the table, not suppressed across the code.

### A suppression is an `expect` with a reason

`#[allow(…)]` silences a lint forever, even after the code that needed it is gone. `#[expect(…)]` does the same, and "if the expectation is unfulfilled", `unfulfilled_lint_expectations` fires, so a stale suppression is found. Clippy's `allow_attributes` turns every `allow` into an `expect`, and `allow_attributes_without_reason` requires the reason.

```rust
#[expect(
    clippy::cast_possible_truncation,
    reason = "the length is checked against u16::MAX above"
)]
let len = bytes.len() as u16;
```

A suppression is the last resort: `coding_guidelines.md` → **Verification** says never to loosen a check to pass it. Fix the code first.

### `clippy.toml` holds the project's thresholds

```toml
# Names the project writes without backticks; ".." keeps Clippy's own list.
doc-valid-idents = ["GitHub", "OAuth", "PostgreSQL", ".."]
allow-unwrap-in-tests = true
allow-expect-in-tests = true
disallowed-methods = [
    { path = "std::thread::sleep", reason = "blocks the runtime; use tokio::time::sleep" },
]
```

A threshold, such as `too-many-arguments-threshold`, is raised only with a comment saying what in the design needs it.

---

## Dependencies

> *Source: [Cargo — Specifying Dependencies](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html), [Cargo — Features](https://doc.rust-lang.org/cargo/reference/features.html), [cargo-deny](https://embarkstudios.github.io/cargo-deny/)*

These are the Cargo mechanics of `coding_guidelines.md` → **Security** ("Dependencies are pinned and scanned").

- **`Cargo.lock` is committed**, for a binary and a library alike, and every CI command passes `--locked`, so CI builds exactly what was reviewed.
- **No wildcard versions.** `serde = "1"` is a caret range; `serde = "*"` is no constraint at all (Clippy's `wildcard_dependencies`).
- **Features are opted into.** `default-features = false` plus the features used keeps the build small and the attack surface named. For TLS, pick one backend, such as rustls with an explicit crypto provider, rather than whatever a default pulls in.
- **`cargo deny check`** runs in CI with a `deny.toml` covering its four checks: `advisories` (RustSec; `yanked = "deny"`), `licenses` (an allowlist, never a denylist), `bans` (`wildcards = "deny"`, duplicate and banned crates) and `sources` (`unknown-registry` and `unknown-git` denied).
- **A dependency is a cost.** Prefer `std` for anything it does. A new crate needs a reason: what it does that `std` doesn't, who maintains it, and how much it pulls in (`cargo tree -e normal -i <crate>`).

---

## Performance

> *Source: [The Rust Performance Book](https://nnethercote.github.io/perf-book/), [Clippy — perf group](https://rust-lang.github.io/rust-clippy/master/index.html?groups=perf)*

`coding_guidelines.md` → **Performance** holds the rules. The Rust mechanics:

- **Measure release builds.** A debug build can be many times slower and tells nothing about production. Benchmark with `criterion`, profile with `cargo flamegraph` or `perf`, and compare on the same input before and after.
- **Allocation is usually the cost.** `Vec::with_capacity` when the size is known, `&str` over `String` in arguments, iterators over collecting into a `Vec` only to iterate again (Clippy's `needless_collect`), and `write!` into one `String` over `format!` in a loop (Clippy's `format_push_string`).
- **Clippy's `perf` group is part of `clippy::all`**, so those findings already fail the build.

---

## Complexity and Mutation

> *Source: [Verification](coding_guidelines.md#verification), `~/.claude/scripts/change_gate.py`, [lizard](https://github.com/terryyin/lizard), [cargo-mutants](https://mutants.rs/), [cargo-mutants — exit codes](https://mutants.rs/exit-codes.html), [cargo-mutants — skipping](https://mutants.rs/attrs.html)*

`~/.claude/scripts/change_gate.py` holds a change to both bars.

- **No function above cyclomatic complexity 10**, counted by lizard over every changed `.rs` file.
- **Every mutant on a changed line is killed.** The gate hands cargo-mutants the change's own diff, untracked files included, with `cargo mutants --workspace --in-diff`. cargo-mutants copies the tree, replaces function bodies with a default value of the return type and swaps operators (`>` with `>=`, `+` with `-`) in the functions that diff touches, and runs `cargo test` on each mutant. A missed mutant or one that times out fails the gate. A mutant that doesn't compile is unviable and doesn't count. Install it with `cargo install --locked cargo-mutants`.
- **Each workspace runs on its own.** `cargo locate-project --workspace` names the workspace of each changed file, so a repo may hold several crates and workspaces at any depth. cargo-mutants runs once in each, under the toolchain its `rust-toolchain.toml` names, over the diff of the files under it. A file whose workspace cargo can't find, or finds outside the repo, fails the gate.
- **Test the way CI does:** `--test 'rust=cargo test --locked --all-features'`. The options before `--` reach every cargo call, so the mutants build as they are tested; what follows `--` goes to the test binaries. A command that isn't `cargo test` fails the gate.
- **No member folder named `b`.** cargo-mutants strips the `b` prefix git puts on each new path in a diff, and a top-level folder named `b` with it, so it would mutate nothing there. The gate refuses such a change rather than pass it unmutated.
- **Unit tests in `#[cfg(test)]` modules and files under `<crate>/tests/` are never mutated.**
- **An equivalent mutant is marked on its line:** `// mutation: equivalent — <reason>`. The gate reads this marker. cargo-mutants' own `#[mutants::skip]` skips the whole function and needs the `mutants` crate as a dependency, so it isn't the way to accept one mutant.

---

## Tooling

> *Source: [Cargo commands](https://doc.rust-lang.org/cargo/commands/index.html), [Clippy usage](https://doc.rust-lang.org/clippy/usage.html)*

| Command | Purpose |
|---|---|
| `cargo fmt --check` | Formatting, as CI checks it |
| `cargo clippy --locked --all-targets -- -D warnings` | Lints on the library, binaries, tests, benches and examples |
| `cargo test --locked` | Unit, integration and doc tests |
| `cargo deny check` | Advisories, licenses, bans and sources |
| `cargo llvm-cov --fail-under-lines <MIN>` | Line coverage |
| `RUSTDOCFLAGS="-D warnings" cargo doc --no-deps` | Docs build, intra-doc links resolve |
| `~/.claude/scripts/change_gate.py` | Complexity and mutation gate on the changed lines |

- `--all-targets` matters: without it, Clippy skips the tests, and a lint the tests break passes locally and fails in CI.
- Pin each tool CI installs to an exact version (`cargo install --locked cargo-deny --version <v>`), as the toolchain is pinned.
- Run them in the order `coding_guidelines.md` → **Verification** gives: `cargo fmt` first and alone, then the verifiers.

---

## Sources

This guide is compiled from these authoritative sources:

1. **[The Rust Programming Language](https://doc.rust-lang.org/book/)**: ownership, error handling (ch. 9), test organization (ch. 11), concurrency (ch. 16), modules (ch. 7)
2. **[Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)**: naming, interoperability, type safety, documentation, predictability, flexibility, future proofing; the C-* rule IDs cited above
3. **[Rust Style Guide](https://doc.rust-lang.org/style-guide/)** and **[rustfmt](https://github.com/rust-lang/rustfmt)**: indentation, line width, formatting
4. **[std::error::Error](https://doc.rust-lang.org/std/error/trait.Error.html)**: the error message convention
5. **[The Rust Reference — Diagnostic attributes](https://doc.rust-lang.org/reference/attributes/diagnostics.html)**: `allow`, `expect`, `reason`
6. **[rustc lint levels](https://doc.rust-lang.org/rustc/lints/levels.html)** and **[allowed-by-default lints](https://doc.rust-lang.org/rustc/lints/listing/allowed-by-default.html)**: `forbid`, `unsafe_code`
7. **[Clippy lint list](https://rust-lang.github.io/rust-clippy/master/index.html)** and **[Clippy configuration](https://doc.rust-lang.org/clippy/lint_configuration.html)**: every Clippy lint and `clippy.toml` key named above
8. **[The Cargo Book](https://doc.rust-lang.org/cargo/)**: `[lints]`, `workspace.lints`, `rust-version`, dependencies, features
9. **[Edition Guide — Rust 2024](https://doc.rust-lang.org/edition-guide/rust-2024/index.html)** and **[rustup overrides](https://rust-lang.github.io/rustup/overrides.html)**: editions and the toolchain file
10. **[The Rustonomicon](https://doc.rust-lang.org/nomicon/)**: unsafe code
11. **[rustdoc book](https://doc.rust-lang.org/rustdoc/how-to-write-documentation.html)**: doc comments, doc tests, intra-doc links
12. **[tokio](https://docs.rs/tokio)**: blocking in async, paused time in tests
13. **[thiserror](https://docs.rs/thiserror)**, **[anyhow](https://docs.rs/anyhow)**, **[secrecy](https://docs.rs/secrecy)**: error types, error context, secrets
14. **[proptest](https://docs.rs/proptest/latest/proptest/)** and **[cargo-llvm-cov](https://github.com/taiki-e/cargo-llvm-cov)**: property tests, coverage
15. **[cargo-deny](https://embarkstudios.github.io/cargo-deny/)**: dependency checks
16. **[cargo-mutants](https://mutants.rs/)** and **[lizard](https://github.com/terryyin/lizard)**: the mutation tester and the complexity counter `change_gate.py` runs
17. **[The Rust Performance Book](https://nnethercote.github.io/perf-book/)**: measuring and allocation

For updates, refer to the original sources as Rust conventions evolve.

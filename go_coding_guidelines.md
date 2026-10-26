# Go Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

## Core Principles

**Priority Order** (from general coding principles):
1. **CORRECT** - Code does what it's supposed to do
2. **SIMPLE and READABLE** - Code reads like documentation
3. **EXTENSIBLE** - Easy to modify without rewriting
4. **PERFORMANT** - Fast enough for the use case

**Go Proverbs** (Rob Pike, Gopherfest 2015):
- "Clear is better than clever."
- "The bigger the interface, the weaker the abstraction."
- "Make the zero value useful."
- "Errors are values."
- "Don't panic."
- "A little copying is better than a little dependency."

---

## Formatting

### Gofmt
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#gofmt)*

Run `gofmt` (or `goimports`) on your code. This is non-negotiable.

### Line Length
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#line-length)*

There is no rigid line length limit in Go, but avoid uncomfortably long lines. Don't add line breaks just to keep lines short when they are more readable long (e.g., repetitive struct literals).

---

## Naming

### Variable Names
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#variable-names)*

Variable names should be **short rather than long**. This is especially true for local variables with limited scope.

```go
// Good
for i, v := range items { }
c := new(Client)

// Bad
for index, value := range items { }
client := new(Client)
```

**Rule:** The further from its declaration a name is used, the more descriptive it must be.

### Initialisms
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#initialisms)*

Words in names that are initialisms should have consistent case:
- `URL` not `Url`
- `ID` not `Id`
- `HTTP` not `Http`
- `userID` not `UserId` or `userId`

### MixedCaps
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#mixed-caps)*

Use `MixedCaps` or `mixedCaps` rather than underscores. Even for constants: `MaxLength`, not `MAX_LENGTH`.

### Receiver Names
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#receiver-names)*

Receiver names should be short (one or two letters), consistent across methods, and **never** use generic names like `this` or `self`.

```go
// Good
func (s *Store) Get(id string) {}
func (s *Store) Set(id string) {}

// Bad
func (store *Store) Get(id string) {}
func (self *Store) Set(id string) {}
```

### Package Names
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#package-names), [Uber Guide](https://github.com/uber-go/guide/blob/master/style.md)*

- All lowercase, no underscores or mixedCaps
- Short and succinct
- **Avoid**: `util`, `common`, `misc`, `api`, `types`, `interfaces`, `helpers`
- Don't stutter: use `store.New()`, not `store.NewStore()`

### Function Names
> *Source: [Google Go Style](https://google.github.io/styleguide/go/best-practices#naming)*

- **Noun-like** for functions returning values: `User()`, `Config()`
- **Verb-like** for functions performing actions: `Save()`, `Process()`
- Avoid repetition: omit package name, receiver type from function name

---

## Error Handling

The sections below are the Go mechanics — how to wrap with `%w`, how an error string reads, when a panic is warranted. What an error must *be* is governed by `coding_guidelines.md` → **Failure**, the single source for those rules.

### Always Handle Errors
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#handle-errors)*

Do not discard errors using `_`. If a function returns an error, check it.

```go
// Good
if err := db.Connect(); err != nil {
    return fmt.Errorf("connecting to database: %w", err)
}

// Bad
db.Connect() // error ignored
_ = db.Connect() // explicitly ignored but still bad
```

### Error Strings
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#error-strings)*

Error strings should:
- **Not be capitalized** (unless proper nouns/acronyms)
- **Not end with punctuation**

```go
// Good
fmt.Errorf("something bad happened")
fmt.Errorf("loading config: %w", err)

// Bad
fmt.Errorf("Something bad happened.")
```

### Indent Error Flow
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#indent-error-flow)*

Handle the error case first, then the success case. Return early. Keep the "happy path" at minimal indentation.

```go
// Good
if err != nil {
    return err
}
// happy path continues here

// Bad
if err == nil {
    // happy path deeply nested
}
```

### Error Wrapping
> *Source: [Google Go Style Best Practices](https://google.github.io/styleguide/go/best-practices#error-handling)*

- Use `%w` for errors callers should inspect: `fmt.Errorf("loading user: %w", err)`
- Use `%v` for simple annotation where callers won't inspect
- Place `%w` at the end of error strings

### Don't Panic
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#dont-panic), [Go Proverbs](https://go-proverbs.github.io/)*

Don't use panic for normal error handling. Use error and multiple return values.

---

## Interfaces

### Interface Size
> *Source: [Go Proverbs](https://go-proverbs.github.io/), [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#interfaces)*

"The bigger the interface, the weaker the abstraction."

- Keep interfaces small (1-3 methods)
- Use `-er` suffix for single-method interfaces: `Reader`, `Writer`, `Stringer`
- Define interfaces at point of use, not with implementation

### Verify Interface Compliance
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Verify interface compliance at compile time:

```go
var _ http.Handler = (*Server)(nil)
var _ io.Reader = (*MyReader)(nil)
```

### Accept Interfaces, Return Structs
> *Source: [Effective Go](https://go.dev/doc/effective_go)*

- Accept interfaces in function parameters (for flexibility)
- Return concrete types (structs) from functions
- Don't create interfaces "just in case"

---

## Concurrency

### Goroutine Lifetimes
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#goroutine-lifetimes)*

Keep concurrent code simple enough that goroutine lifetimes are obvious. If not feasible, **document when and why goroutines exit**.

### Don't Fire-and-Forget Goroutines
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Always have a way to stop goroutines. Use context cancellation or done channels.

```go
// Bad
go func() {
    for {
        process() // runs forever, no way to stop
    }
}()

// Good
go func() {
    for {
        select {
        case <-ctx.Done():
            return
        default:
            process()
        }
    }
}()
```

### Channel Size
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Channel size should be either **one** or **none** (unbuffered). Any other size requires careful analysis.

```go
c := make(chan int)    // unbuffered - preferred
c := make(chan int, 1) // acceptable
c := make(chan int, 64) // needs justification
```

### Channels vs Mutexes
> *Source: [Go Proverbs](https://go-proverbs.github.io/)*

"Channels orchestrate; mutexes serialize."

- Use channels for coordination between goroutines
- Use mutexes for protecting shared state
- Document which mutex protects which fields

```go
type Store struct {
    mu      sync.RWMutex
    devices map[string]*Device // protected by mu
}
```

### Zero-value Mutexes
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

The zero value of `sync.Mutex` and `sync.RWMutex` is valid, so you don't need a pointer to a mutex.

---

## Types and Values

### Zero Values
> *Source: [Go Proverbs](https://go-proverbs.github.io/), [Effective Go](https://go.dev/doc/effective_go)*

"Make the zero value useful."

Design types so their zero value is ready to use without initialization.

```go
// Good: zero value is useful
var buf bytes.Buffer
buf.WriteString("hello") // works immediately

// sync.Mutex zero value is ready to use
var mu sync.Mutex
mu.Lock()
```

### Declaring Empty Slices
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#declaring-empty-slices)*

Prefer `var` over `make` for declaring empty slices:

```go
// Good
var s []string

// Acceptable (when you need non-nil for JSON)
s := []string{}

// Avoid
s := make([]string, 0)
```

### Copy Slices and Maps at Boundaries
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Slices and maps contain pointers to underlying data. Copy them when receiving or returning to avoid unexpected mutations.

```go
func (s *Store) SetItems(items []Item) {
    s.items = make([]Item, len(items))
    copy(s.items, items) // defensive copy
}
```

### Type Assertions
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Always use the "comma ok" idiom for type assertions to avoid panics:

```go
// Good
t, ok := i.(string)
if !ok {
    // handle error
}

// Bad - panics if wrong type
t := i.(string)
```

### Avoid Built-in Names
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Never shadow Go's predeclared identifiers: `error`, `string`, `int`, `true`, `false`, `nil`, `make`, `new`, `len`, `cap`, `append`, `copy`, `delete`, etc.

### Start Enums at One
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Start enums at 1 so zero value indicates "unset":

```go
type Status int

const (
    StatusUnknown Status = iota // 0 = unset/invalid
    StatusActive                // 1
    StatusInactive              // 2
)
```

---

## Functions

### Synchronous Functions
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#synchronous-functions)*

Prefer synchronous functions over asynchronous ones. Let the caller decide about concurrency.

```go
// Good - caller controls concurrency
func Process(ctx context.Context, data []byte) error { }

// Avoid - forces async on caller
func ProcessAsync(data []byte) <-chan error { }
```

### Context
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#contexts)*

- Context should be the **first parameter**, named `ctx`
- Don't store Context in struct types
- Pass Context explicitly through call chain

```go
func (s *Server) Handle(ctx context.Context, req *Request) error { }
```

### Named Return Values
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#named-result-parameters)*

Use named return values only when:
- They improve documentation (clarify what's returned)
- You need them for deferred cleanup

Avoid "naked returns" (return without arguments) except in very short functions.

### Pass Values vs Pointers
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#pass-values)*

- Pass small structs by value
- Pass large structs, or structs you need to modify, by pointer
- Be consistent within a type's methods

---

## Imports

### Import Organization
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#imports), [Uber Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Group imports in this order, separated by blank lines:
1. Standard library
2. Third-party packages
3. Local/internal packages

```go
import (
    "context"
    "fmt"

    "github.com/pkg/errors"
    "go.uber.org/zap"

    "mycompany/myproject/internal/store"
)
```

### Import Blank
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#import-blank)*

Blank imports (`import _ "pkg"`) should only be in `main` or test files, with a comment explaining why:

```go
import _ "image/png" // register PNG decoder
```

### Import Dot
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#import-dot)*

Avoid dot imports (`import . "pkg"`) except in tests for the package being tested.

---

## Documentation

This section covers godoc mechanics only. What a comment may say is governed by `coding_guidelines.md` → **Comments**, the single source for those rules.

### Doc Comments
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#doc-comments)*

All exported names should have doc comments. Comments should be **complete sentences** starting with the name being documented.

```go
// Server handles HTTP requests for device telemetry.
type Server struct { }

// NewServer creates a Server with the given store.
// If configErr is non-nil, all requests return 500.
func NewServer(store *Store, configErr error) *Server { }
```

### Comment Sentences
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#comment-sentences)*

Comments should be complete sentences with proper punctuation. This makes them render well in godoc.

### Package Comments
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#package-comments)*

Every package should have a package comment. For multi-file packages, it should appear in only one file (usually `doc.go`).

```go
// Package store provides thread-safe storage for device statistics.
package store
```

---

## Testing

### Table-Driven Tests
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md), [Go Wiki](https://go.dev/wiki/TableDrivenTests)*

Use table-driven tests for multiple scenarios:

```go
func TestValidate(t *testing.T) {
    tests := []struct {
        name    string
        input   string
        wantErr bool
    }{
        {name: "valid", input: "hello", wantErr: false},
        {name: "empty", input: "", wantErr: true},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := Validate(tt.input)
            if (err != nil) != tt.wantErr {
                t.Errorf("Validate(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
            }
        })
    }
}
```

### Useful Test Failures
> *Source: [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments#useful-test-failures)*

Test failures should provide enough context to diagnose without reading the test code:

```go
// Good
t.Errorf("GetUser(%q) = %v, want %v", id, got, want)

// Bad
t.Errorf("wrong result")
```

### Test Helpers
> *Source: [Google Go Style Best Practices](https://google.github.io/styleguide/go/best-practices#tests)*

- Call `t.Helper()` in test helper functions
- Use `t.Fatal` only for setup failures, not assertions
- Never call `t.Fatal` from goroutines

---

## Struct Tags

### Use Field Tags in Marshaled Structs
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Any struct used in JSON/XML/etc. marshaling should have explicit field tags:

```go
type Response struct {
    Uptime        float64 `json:"uptime"`
    AvgUploadTime string  `json:"avg_upload_time"`
}
```

---

## Performance

> *Source: [Uber Go Style Guide - Performance](https://github.com/uber-go/guide/blob/master/style.md)*

### Prefer strconv over fmt

```go
// Good - faster
s := strconv.Itoa(42)

// Slower
s := fmt.Sprintf("%d", 42)
```

### Specify Container Capacity

```go
// Good - avoids reallocations
m := make(map[string]int, len(keys))
s := make([]int, 0, len(items))
```

### Avoid Repeated String-to-Byte Conversions

```go
// Bad - converts on every iteration
for i := 0; i < n; i++ {
    w.Write([]byte("hello"))
}

// Good - convert once
data := []byte("hello")
for i := 0; i < n; i++ {
    w.Write(data)
}
```

---

## Anti-Patterns

### Avoid init()
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Avoid `init()` functions. When unavoidable:
- Be completely deterministic
- Avoid depending on ordering or side effects
- Avoid accessing global state

### Avoid Mutable Globals
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Avoid mutable global state. Use dependency injection instead.

### Exit Only in main()
> *Source: [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)*

Call `os.Exit` or `log.Fatal` only in `main()`. Other functions should return errors.

### interface{} Says Nothing
> *Source: [Go Proverbs](https://go-proverbs.github.io/)*

Avoid empty `interface{}` when specific types would work. With Go 1.18+, consider generics.

---

## Tooling

### Required
- `gofmt` or `goimports` - automatic formatting
- `golangci-lint run` - must pass with 0 issues
- `go test ./...` - all tests must pass
- `go build` - must compile

### Recommended Linters (via golangci-lint)
- `errcheck` - unchecked errors
- `govet` - suspicious constructs
- `staticcheck` - static analysis
- `unused` - unused code
- `ineffassign` - ineffective assignments
- `gosimple` - simplifications

---

## Sources

This guide is compiled from these authoritative sources:

1. **[Effective Go](https://go.dev/doc/effective_go)** - Official Go team guide (2009, foundational)
2. **[Go Code Review Comments](https://go.dev/wiki/CodeReviewComments)** - Official wiki, common code review feedback
3. **[Google Go Style Guide](https://google.github.io/styleguide/go/)** - Google's comprehensive style guide
4. **[Google Go Style Best Practices](https://google.github.io/styleguide/go/best-practices)** - Additional recommendations
5. **[Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md)** - Widely-adopted industry guide
6. **[Go Proverbs](https://go-proverbs.github.io/)** - Rob Pike's guiding principles (Gopherfest 2015)

For updates, refer to the original sources as Go conventions evolve.

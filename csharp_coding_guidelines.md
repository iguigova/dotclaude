# C# Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

The rules every language shares, from the priority order to failure, comments, naming and verification, live in `coding_guidelines.md` and `style_guidelines.md`. This guide doesn't repeat them. It adds only the C# and .NET mechanics, with worked examples in C#.

---

## Platform

### Target Framework
> *Source: [.NET support policy](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)*

The supported releases are .NET 11 (STS, released November 10, 2026) and .NET 10 (LTS, released November 11, 2025). .NET 10 is supported until November 14, 2028, and .NET 11 for two years from its release. New code targets `net10.0`.


### SDK-Style Projects
> *Source: [Code analysis in .NET](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/overview)*

Every project is SDK-style (`<Project Sdk="Microsoft.NET.Sdk">`). The legacy project format needs extra steps before the analyzers run. It doesn't understand `AnalysisLevel`.

### Language Version
> *Source: [Configure language version](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/configure-language-version)*

Leave `LangVersion` unset, so the target framework picks the default. Never set it to `latest`: "The value of `latest` can change from machine to machine, making builds unreliable."

---

## Formatting

### EditorConfig and dotnet format
> *Source: [dotnet format](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-format), [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

`dotnet format` "applies style preferences and static analysis recommendations to a project or solution", and it reads its preferences from `.editorconfig`. Each repository has one `.editorconfig` at its root. Start from the [`dotnet/docs` .editorconfig](https://github.com/dotnet/docs/blob/main/.editorconfig).

- `dotnet format` rewrites the files.
- `dotnet format --verify-no-changes` "terminates with a non zero exit code if any files would have been formatted". This is the check CI runs.
- `--severity` defaults to `warn`.

### Layout
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

- Indent with four spaces, never tabs.
- Use Allman braces: each brace on its own line.
- One statement per line, and one declaration per line.
- Use file-scoped namespaces.
- Put `using` directives outside the namespace. Inside it, a directive "is context-sensitive and complicates name resolution".

```csharp
// Good
using System.Text;

namespace Fiff;

public sealed class Report
{
}

// Bad
namespace FIFFConsole
{
    using System.Text;

    public class Report { }
}
```

---

## Naming

### Casing and Prefixes
> *Source: [Identifier names](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/identifier-names)*

| Symbol | Style | Example |
|---|---|---|
| Type, namespace, method, property, event, local function | PascalCase | `TokenStream`, `ReadToken` |
| Constant, at any access level and as a local | PascalCase | `MaxCategoryId` |
| Interface | `I` + PascalCase | `ITokenStream` |
| Parameter, local | camelCase | `bufferSize` |
| Private or internal instance field | `_` + camelCase | `_stream` |
| Private or internal static field | `s_` + camelCase | `s_httpClient` |
| Thread-static field | `t_` + camelCase | `t_buffer` |
| Primary constructor parameter on a class or struct | camelCase | `class Broker(ITokenStream left)` |
| Positional record parameter | PascalCase | `record Token(long Position)` |

Never use two consecutive underscores. That form is "reserved for compiler-generated identifiers".

```csharp
// Good
private const int MaxCategoryId = 100;

// Bad
private const int LOGMSG_MAXCATEGORYID = 100;
```

### Type Names
> *Source: [Names of Classes, Structs, and Interfaces](https://learn.microsoft.com/en-us/dotnet/standard/design-guidelines/names-of-classes-structs-and-interfaces)*

- Name classes and structs with nouns. Never give a class a prefix such as `C`.
- Prefix generic type parameters with `T`: `TSession`, or a bare `T` when one letter says it all.
- An exception type ends in `Exception`, an attribute in `Attribute`, and an `EventArgs` subclass in `EventArgs`.
- Name an enum in the singular. A flags enum is plural.
- No `Enum`, `Flag` or `Flags` suffix on an enum name, and no prefix on its value names.

```csharp
// Good
public enum Priority { None, Low, Medium, High }

// Bad
public enum LogMsgPriority { lmpNone, lmpLow, lmpMedium, lmpHigh }
```

### Async Methods
> *Source: [Task-based Asynchronous Pattern](https://learn.microsoft.com/en-us/dotnet/standard/asynchronous-programming-patterns/task-based-asynchronous-pattern-tap)*

A method that returns an awaitable type ends in `Async`. A synchronous method never does.

### Enforcing Names
> *Source: [Code-style naming rules](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/naming-rules)*

Naming rules live in `.editorconfig`, and every violation reports as `IDE1006`.

A naming rule's own `severity` is respected only in the IDE. To make a violation fail the build, set `dotnet_diagnostic.IDE1006.severity` to `warning` or `error`.

```ini
[*.cs]
dotnet_naming_symbols.private_fields.applicable_kinds = field
dotnet_naming_symbols.private_fields.applicable_accessibilities = private, internal
dotnet_naming_style.underscored.capitalization = camel_case
dotnet_naming_style.underscored.required_prefix = _
dotnet_naming_rule.private_fields_underscored.symbols = private_fields
dotnet_naming_rule.private_fields_underscored.style = underscored
dotnet_naming_rule.private_fields_underscored.severity = warning
dotnet_diagnostic.IDE1006.severity = warning
```

---

## Language Features

### Types and var
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

- Use the keyword types: `string`, not `String`, and `int`, not `Int32`.
- Use `var` only when the right-hand side shows the type: a `new`, a cast or a literal. A method name doesn't show the type.
- Declare the type of a `foreach` variable explicitly.
- Use `var` for LINQ query results.

```csharp
// Good
var buffer = new StringBuilder();
int bufferSize = int.Parse(text);

// Bad
var bufferSize = Convert.ToInt32(text);
```

### Strings
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

- Interpolate short strings.
- Build text in a loop with `StringBuilder`.
- Write fixed multi-line text as a raw string literal, not as escape sequences.

```csharp
// Good
var text = new StringBuilder();
foreach (string chunk in chunks)
{
    text.Append(chunk);
}

// Bad
result += encoding.GetString(b);
```

### Collection Expressions and new()
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

Initialise collections with collection expressions. Use target-typed `new()` when the variable's type is the object's type.

```csharp
string[] vowels = ["a", "e", "i", "o", "u"];
List<Token> tokens = [];
Stopwatch watch = new();
```

### Required Members
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

To force a property to be initialised, mark it `required` instead of adding another constructor.

---

## Nullable Reference Types

### Enable Everywhere
> *Source: [Nullable reference types](https://learn.microsoft.com/en-us/dotnet/csharp/nullable-references)*

Every project sets `<Nullable>enable</Nullable>`. Recent templates set it already.

With it enabled, `string` means never null and `string?` means it may be null. The compiler warns when the code contradicts the annotation.

### Absent Is a Type, Not a Sentinel
> *Source: [Nullable reference types](https://learn.microsoft.com/en-us/dotnet/csharp/nullable-references); rule: `coding_guidelines.md` → **Failure***

Say "absent" with `T?` or a `Try` method, never with a magic value the caller can mistake for a real one.

```csharp
// Good
public long? PositionAt(int index) =>
    index >= 0 && index < _tokens.Count ? _tokens[index].Position : null;

// Bad: a sentinel a caller can mistake for a position
public static long Undefined = -1;
```

### The ! Operator
> *Source: [Nullable reference types](https://learn.microsoft.com/en-us/dotnet/csharp/nullable-references)*

"Use `!` sparingly. Each occurrence is a place the compiler can no longer protect you."

Prefer a null check, a restructure, or a nullable-analysis attribute such as `[NotNullWhen(true)]` on the API.

### Pitfalls the Compiler Misses
> *Source: [Nullable reference types](https://learn.microsoft.com/en-us/dotnet/csharp/nullable-references)*

The compiler doesn't warn about these two:

- A `default` struct leaves its non-nullable reference fields null.
- `new string[3]` holds three nulls.

Initialise every element when the array is created, for example with a collection expression.

---

## Records and Immutability

### Data Is a Record
> *Source: [Records](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/record)*

A type that carries data is a record.

- Records compare by value: "two objects are equal if they are of the same type and store the same values."
- Positional properties are init-only on a `record class` and on a `readonly record struct`.
- Positional properties are read-write on a plain `record struct`, so a value record is `readonly record struct`.

```csharp
// Good
public readonly record struct Token(long Position, long Hash, long Length)
{
    public long End => Position + Length;
}

// Bad
public long T1 = FIFFConst.Undefined;
public long T2 = FIFFConst.Undefined;
public long T3 = FIFFConst.Undefined;
```

### Change by Copy
> *Source: [Records](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/record)*

"Change" a record with a `with` expression. It makes a new instance and leaves the old one alone.

`with` copies shallowly, and init-only is shallow too: an array inside a record stays mutable. Hold collections in a record as read-only types.

Compute a derived property on access (`=>`), never in an initialiser. Otherwise a `with` copy keeps the old value.

### No Mutable Statics
> *Source: [CA2211](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2211)*

"Static fields that are neither constants nor read-only are not thread-safe." "Applications should not expose any fields."

Settings are an immutable record, built once in `Main` and passed in.

```csharp
// Good
public sealed record CompareOptions(
    char Delimiter = ' ',
    bool Ordered = true,
    bool IgnoreCase = true,
    int BufferSize = 4096);

// Bad: mutable statics, set from Main
public static char Delimiter = (char)32;
public static int Buffer = 4096;
```

---

## LINQ

### Prefer Queries to Hand-Written Loops
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

"Use LINQ queries and methods for collection manipulation to improve code readability."

A query has no loop index to forget. The loop below never advances `id`, so it never ends once `categoryIDs[0]` is 0.

```csharp
// Good
public bool IsEmpty() => !_categoryIds.Any(flag => flag == 1);

// Bad
while ((id < categoryIDs.Length) && (!categoryIDFound))
{
    categoryIDFound = (categoryIDs[id] == 1);
}
```

### Query Style
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

- Give query variables meaningful names: `seattleCustomers`, not `q`.
- Put `where` before the other clauses, so they work on the filtered set.
- Name anonymous-type members in PascalCase. Rename them when two would both be `Name`.

### Deferred Execution
> *Source: [Introduction to LINQ Queries](https://learn.microsoft.com/en-us/dotnet/csharp/linq/get-started/introduction-to-linq-queries)*

A query variable "takes no action and returns no data". It runs each time it is enumerated, and it reads the source as the source is at that moment.

Call `ToList()` or `ToArray()` to run a query once and keep the results. Do that when you enumerate it more than once, or when the source can change in between.

---

## Async and Cancellation

### Task-Based Methods
> *Source: [Task-based Asynchronous Pattern](https://learn.microsoft.com/en-us/dotnet/standard/asynchronous-programming-patterns/task-based-asynchronous-pattern-tap)*

- Return `Task` or `Task<T>`.
- Use `ValueTask` "only when measurements show allocation pressure".
- Never use `out` or `ref` parameters. Return a tuple or a record instead.

### Validate Before the First await
> *Source: [Best practices for exceptions](https://learn.microsoft.com/en-us/dotnet/standard/exceptions/best-practices-for-exceptions)*

An `async` method stores every exception in the task it returns, including one thrown before its first `await`. To make a usage error throw at the call site, validate in a non-`async` method that returns the inner `async` method's task.

```csharp
public Task<string> ReadTokenAsync(Stream stream, int length, CancellationToken cancellationToken)
{
    ArgumentNullException.ThrowIfNull(stream);
    ArgumentOutOfRangeException.ThrowIfNegativeOrZero(length);
    return ReadCoreAsync(stream, length, cancellationToken);
}

private static async Task<string> ReadCoreAsync(Stream stream, int length, CancellationToken cancellationToken)
{
    byte[] buffer = new byte[length];
    await stream.ReadExactlyAsync(buffer, cancellationToken);
    return Encoding.UTF8.GetString(buffer);
}
```

### Cancellation
> *Source: [Task-based Asynchronous Pattern](https://learn.microsoft.com/en-us/dotnet/standard/asynchronous-programming-patterns/task-based-asynchronous-pattern-tap), [CA2016](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2016)*

- A method that can cancel takes `CancellationToken cancellationToken` as its last parameter.
- A method that can't cancel takes no token.
- Pass the token to every call that accepts one. CA2016 flags a token that isn't passed on.
- Ending early through cancellation surfaces as `OperationCanceledException`. Catch that type, not `TaskCanceledException`.

### Never Block, Never async void
> *Source: [Asynchronous programming scenarios](https://learn.microsoft.com/en-us/dotnet/csharp/asynchronous-programming/async-scenarios)*

- Use `await` instead of `.Result` or `.Wait()`.
- Use `await Task.WhenAll` instead of `Task.WaitAll`.
- Use `await Task.Delay` instead of `Thread.Sleep`.
- Use `async void` only on event handlers. Its exceptions "can't be caught outside of that method".
- When LINQ starts tasks, end the query with `ToArray()` or `ToList()`, so the tasks start and run concurrently.

```csharp
// Good
Task<User>[] lookups = ids.Select(id => GetUserAsync(id, cancellationToken)).ToArray();
User[] users = await Task.WhenAll(lookups);

// Bad
User user = GetUserAsync(id, cancellationToken).Result;
```

---

## Exceptions

The sections below are the C# mechanics. What an error must *be* is governed by `coding_guidelines.md` → **Failure**, the single source for those rules.

### Catch Only What You Handle
> *Source: [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions), [Best practices for exceptions](https://learn.microsoft.com/en-us/dotnet/standard/exceptions/best-practices-for-exceptions)*

- Catch a specific type.
- Never catch `System.Exception` without an exception filter (`when`).
- Order `catch` clauses from most derived to least derived.
- When the code can't recover, it doesn't catch.

```csharp
// Good
if (!int.TryParse(args[4], out int bufferSize))
{
    throw new ArgumentException($"Buffer size '{args[4]}' is not an integer.", nameof(args));
}

// Bad: drops every bad argument without a word
catch { }
```

### Rethrow with throw;
> *Source: [Best practices for exceptions](https://learn.microsoft.com/en-us/dotnet/standard/exceptions/best-practices-for-exceptions), [CA2200](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2200)*

Inside a `catch`, rethrow with a bare `throw;`. `throw e;` restarts the stack trace at the current method.

To wrap an error, pass the original as `innerException`.

### Throw Helpers and Types
> *Source: [Best practices for exceptions](https://learn.microsoft.com/en-us/dotnet/standard/exceptions/best-practices-for-exceptions)*

- Validate with the static helpers: `ArgumentNullException.ThrowIfNull`, `ArgumentException.ThrowIfNullOrEmpty`, `ArgumentOutOfRangeException.ThrowIfNegative` and the others, and `ObjectDisposedException.ThrowIf`. CA1510–CA1513 find hand-written checks these helpers replace.
- Throw `InvalidOperationException` for a call the object's state doesn't allow.
- Throw `ArgumentException` or one of its subclasses for a bad argument.
- Never throw a reserved type such as `NullReferenceException` or `IndexOutOfRangeException` (CA2201).
- A custom exception ends in `Exception` and has the three standard constructors: none, message, and message plus inner exception.
- Never throw from `finally`, `Equals`, `GetHashCode`, `ToString`, a static constructor or an equality operator.

---

## Resources

### IDisposable and using
> *Source: [Using objects that implement IDisposable](https://learn.microsoft.com/en-us/dotnet/standard/garbage-collection/using-objects), [.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)*

"The GC does ***not*** dispose your objects."

- Dispose every `IDisposable` with a `using` declaration. Use `await using` for `IAsyncDisposable`.
- A `try`/`finally` whose only job is `Dispose` is a `using`.
- A class that owns a disposable field is itself `IDisposable`. Disposing replaces hand-written `Open`/`Close` pairs.

```csharp
// Good
public sealed class TokenStream(string path) : IDisposable
{
    private readonly FileStream _stream = File.OpenRead(path);

    public void Dispose() => _stream.Dispose();
}

using var left = new TokenStream(leftPath);

// Bad: a class that owns a FileStream exposes Close(),
// so every caller closes it by hand in a finally block
```

### Read Exactly
> *Source: [CA2022](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2022)*

`Stream.Read` "might return fewer bytes than requested". Check its return value, or call `ReadExactly`/`ReadExactlyAsync`. The rule says not to suppress it: "your app might hang".

```csharp
// Good
stream.ReadExactly(buffer);

// Bad
stream.Read(b, 0, b.Length);
```

---

## Collections

### Typed, Read-Only at the Boundary
> *Source: [Guidelines for Collections](https://learn.microsoft.com/en-us/dotnet/standard/design-guidelines/guidelines-for-collections)*

- A parameter or return value that holds a collection's items has the exact item type, never `object`.
- Don't put `List<T>` or `Dictionary<TKey,TValue>` in a public API. Take the least specialized parameter type, usually `IEnumerable<T>`. Return `ReadOnlyCollection<T>` for a read-only result.
- No settable collection properties.
- Return an empty collection when the true answer is "none". A read that failed throws (`coding_guidelines.md` → **Failure**).

```csharp
// Good
void Add(Token token);

// Bad: object parameters, converted on every use
void Add(object pos, object hash, object len);
```

### Hash Codes Are Not Identities
> *Source: [String.GetHashCode](https://learn.microsoft.com/en-us/dotnet/api/system.string.gethashcode)*

"Different strings can return the same hash code."

Equal hashes don't prove equal content. A hash code is never persisted, never a dictionary key, and never shared across processes. Compare the values themselves, or use a `System.Security.Cryptography.HashAlgorithm` when you need a digest.

```csharp
// Bad: treats equal hashes as equal chunks,
// so a collision hides a real difference
if (stream1.Read(...).GetHashCode() != stream2.Read(...).GetHashCode())

// Bad: uses the FileStream object's hash as the file's hash
get { return (stream != null) ? stream.GetHashCode() : FIFFConst.Undefined; }
```

---

## Complexity and mutation

- No method has a cyclomatic complexity above 10. `~/.claude/scripts/change_gate.py` measures every changed `.cs` file with lizard, and a method above 10 fails the gate.
- The IDE shows the same limit through CA1502. Its default threshold is 25, and it is not enabled by default ([CA1502](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca1502)). `AnalysisMode` `All` doesn't turn it on either ([Code analysis in .NET](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/overview)). Enable it with `dotnet_diagnostic.CA1502.severity = warning`. Set it to 10 with a `CodeMetricsConfig.txt` that holds `CA1502: 10`, included as `AdditionalFiles`.
- Every mutant on a changed line must be killed. `change_gate.py` has no C# mutation runner yet, so any change to a `.cs` file fails the gate until one is added (`change_gate.py`, docstring: "C# … no runner yet: a changed C# file fails the gate").
- That runner will call Stryker.NET. It is installed with `dotnet tool install -g dotnet-stryker`, or per repository with `dotnet new tool-manifest` and `dotnet tool install dotnet-stryker`. It runs as `dotnet stryker` from the test project ([Stryker.NET getting started](https://stryker-mutator.io/docs/stryker-net/getting-started/)). `--since:<committish>` limits the report to mutants in code changed since that commit ([Stryker.NET configuration](https://stryker-mutator.io/docs/stryker-net/configuration/)).
- A surviving mutant that no test can tell apart is accepted only when its line carries `// mutation: equivalent — <reason>`, where the reason says why no test can distinguish it.

---

## Testing

### Framework
> *Source: [Testing in .NET](https://learn.microsoft.com/en-us/dotnet/core/testing/), [xUnit.net v3 getting started](https://xunit.net/docs/getting-started/v3/getting-started)*

Microsoft lists MSTest, NUnit, TUnit and xUnit.net as the popular frameworks and recommends none of them. All four run on Microsoft.Testing.Platform (MTP).

This house uses xUnit.net v3. The guidance below is written for it.

- Install the templates with `dotnet new install xunit.v3.templates`, then create a test project with `dotnet new xunit3`.
- A v3 test project is a stand-alone executable (`OutputType` `Exe`).
- The tests for `Foo.cs` live in `FooTests.cs`. `change_gate.py` recognises a test file by the `Tests?\.cs$` pattern.

### Shape of a Test
> *Source: [Best practices for writing unit tests](https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-best-practices)*

- Name a test `Method_Scenario_ExpectedBehavior`.
- Lay the body out as Arrange, Act, Assert, with one Act per test.
- No `if`, `for` or `while` in a test. A table of cases is a `[Theory]` with `[InlineData]`.
- Build what a test needs in the test, or in a helper it calls.
- Test private methods through the public method that calls them.
- Unit tests touch no file system, database or network. Put a seam in front of those, and in front of `DateTime.Now`.

```csharp
public class TokenTests
{
    [Theory]
    [InlineData(0, 3, 3)]
    [InlineData(10, 0, 10)]
    public void End_PositionAndLength_ReturnsTheirSum(long position, long length, long expected)
    {
        var token = new Token(position, 0, length);

        long actual = token.End;

        Assert.Equal(expected, actual);
    }
}
```

### Coverage
> *Source: [Use code coverage for unit testing](https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-code-coverage)*

Measure coverage with the Microsoft code coverage extension on MTP:

1. Add the `Microsoft.Testing.Extensions.CodeCoverage` package to the test project.
2. With the .NET 10 SDK or later, put `{"test": {"runner": "Microsoft.Testing.Platform"}}` in `<solution>/global.json`. Without it, `dotnet test` doesn't recognise `--coverage`.
3. Run `dotnet test --coverage --coverage-output-format cobertura`.

---

## Analyzers

### Configuration
> *Source: [Code analysis in .NET](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/overview)*

The .NET analyzers ship with the SDK and are on for .NET 5 and later. Their default mode turns on only "a small number of rules" as build warnings.

- `AnalysisLevel` `latest-Recommended` turns on the recommended set for the latest release.
- `EnforceCodeStyleInBuild` runs the `IDE` rules on the command line, at the severities `.editorconfig` gives them.
- `-warnaserror` turns analyzer warnings into errors.

These settings go in one `Directory.Build.props` at the repository root:

```xml
<Project>
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <AnalysisLevel>latest-Recommended</AnalysisLevel>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
  </PropertyGroup>
  <ItemGroup>
    <AdditionalFiles Include="$(MSBuildThisFileDirectory)CodeMetricsConfig.txt" />
  </ItemGroup>
</Project>
```

### Rules Worth Raising
> *Source: the rule pages linked*

- [CA2022](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2022): `Stream.Read` return value not checked. It is a warning by default.
- [CA2211](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2211): visible non-constant static fields. It is only a suggestion by default, so set its severity to `warning`.
- [CA2200](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2200): rethrow that loses the stack. It is a warning by default.
- [CA2016](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2016): cancellation token not passed on. It is a suggestion by default, so set it to `warning`.
- [CA1502](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca1502): complexity, set up as in [Complexity and mutation](#complexity-and-mutation).

Fix the cause. Never `#pragma warning disable` a rule to get a change through.

---

## Tooling

### Required
- `dotnet format --verify-no-changes`: formatting and style match `.editorconfig`.
- `dotnet build -warnaserror`: compiles with zero warnings, analyzers included.
- `dotnet test --coverage --coverage-output-format cobertura`: every test passes, with coverage collected.
- `~/.claude/scripts/change_gate.py`: complexity and mutation on the changed files.

### Recommended
- The xUnit analyzers ([xunit.analyzers](https://www.nuget.org/packages/xunit.analyzers/)), which Microsoft lists as a third-party analyzer.

---

## Sources

This guide is compiled from these authoritative sources:

1. **[.NET Coding Conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)**: Microsoft's C# conventions, adopted from the runtime and Roslyn teams
2. **[Identifier names](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/identifier-names)**: naming rules and conventions
3. **[Framework Design Guidelines: names](https://learn.microsoft.com/en-us/dotnet/standard/design-guidelines/names-of-classes-structs-and-interfaces)** and **[collections](https://learn.microsoft.com/en-us/dotnet/standard/design-guidelines/guidelines-for-collections)**
4. **[Code analysis in .NET](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/overview)** and **[code-style naming rules](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/naming-rules)**
5. **[dotnet format](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-format)**
6. **[Nullable reference types](https://learn.microsoft.com/en-us/dotnet/csharp/nullable-references)**
7. **[Records](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/record)**
8. **[Introduction to LINQ Queries](https://learn.microsoft.com/en-us/dotnet/csharp/linq/get-started/introduction-to-linq-queries)**
9. **[Task-based Asynchronous Pattern](https://learn.microsoft.com/en-us/dotnet/standard/asynchronous-programming-patterns/task-based-asynchronous-pattern-tap)** and **[Asynchronous programming scenarios](https://learn.microsoft.com/en-us/dotnet/csharp/asynchronous-programming/async-scenarios)**
10. **[Best practices for exceptions](https://learn.microsoft.com/en-us/dotnet/standard/exceptions/best-practices-for-exceptions)**
11. **[Using objects that implement IDisposable](https://learn.microsoft.com/en-us/dotnet/standard/garbage-collection/using-objects)**
12. **[String.GetHashCode](https://learn.microsoft.com/en-us/dotnet/api/system.string.gethashcode)**
13. **[Testing in .NET](https://learn.microsoft.com/en-us/dotnet/core/testing/)**, **[unit testing best practices](https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-best-practices)** and **[code coverage](https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-code-coverage)**
14. **[xUnit.net v3 getting started](https://xunit.net/docs/getting-started/v3/getting-started)**
15. **[Stryker.NET](https://stryker-mutator.io/docs/stryker-net/getting-started/)**: mutation testing for .NET
16. **[.NET support policy](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)**, **[C# version history](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-version-history)** and **[Configure language version](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/configure-language-version)**

For updates, refer to the original sources as .NET conventions evolve.

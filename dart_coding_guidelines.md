# Dart and Flutter Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

This guide holds only what is specific to Dart and Flutter. The universal rules live in `coding_guidelines.md` (structure, naming, failure, comments, verification) and `style_guidelines.md` (layout on the page). This guide doesn't restate them. It shows them in Dart syntax. UI code also follows `accessibility_guidelines.md`.


---

## Language Version

> *Source: [Dart language versioning](https://dart.dev/language/versioning), [Language evolution](https://dart.dev/resources/language/evolution)*

"Each package has a default language version equal to the **lower bound** of the SDK constraint in the `<package>/pubspec.yaml` file." A package that declares `sdk: ">=3.0.0 <4.0.0"` is at **language version 3.0**, even when it compiles with Dart 3.9.

At 3.0 a package has patterns, records, class modifiers, switch expressions and if-case. These later features are not available until the lower bound is raised:

| Feature | Language version |
|---|---|
| Promotion of private final fields | 3.2 |
| Digit separators (`1_000_000`) | 3.6 |
| Wildcard variables (`_`), tall formatter style | 3.7 |
| Null-aware collection elements (`?value`) | 3.8 |

Raising the lower bound is a deliberate change of its own, not a side effect of another edit. When you raise it, reformat the whole package (see [Formatting](#formatting)).

---

## Formatting

### dart format
> *Source: [Effective Dart: Style](https://dart.dev/effective-dart/style), [dart format](https://dart.dev/tools/dart-format)*

DO format code with `dart format`. PREFER lines of 80 characters or fewer, which is the formatter's default `page_width`.

The formatter's style follows the language version. Code at 3.6 or lower gets the "short" style, and code at 3.7 or later gets the "tall" style ([dart_style CHANGELOG 3.0.0](https://dart.googlesource.com/dart_style/+/refs/tags/v3.1.1/CHANGELOG.md)). Below 3.7, trailing commas decide where a call splits. Put a trailing comma after the last argument of any widget constructor that spans lines, so the formatter keeps one argument per line.

### Braces
> *Source: [Effective Dart: Style](https://dart.dev/effective-dart/style#do-use-curly-braces-for-all-flow-control-statements)*

DO use curly braces for all flow control statements. The core lint `curly_braces_in_flow_control_structures` allows a braceless `if` only when the whole statement fits on one line and has no `else` ([rule](https://dart.dev/tools/linter-rules/curly_braces_in_flow_control_structures)). This guide is stricter: every `if` gets braces, because the mutation gate only negates an `if` condition that is followed by a brace (see [Complexity and Mutation](#complexity-and-mutation)).

```dart
// Good
if (paymentPermitId != null) {
  return null;
}

// Bad: the gate never negates this condition
if (paymentPermitId != null) return null;
```

---

## Naming

> *Source: [Effective Dart: Style](https://dart.dev/effective-dart/style), [Effective Dart: Design](https://dart.dev/effective-dart/design)*

- `UpperCamelCase` for types and extensions.
- `lowercase_with_underscores` for packages, directories, source files and import prefixes.
- `lowerCamelCase` for everything else, **constants included**: `defaultTimeout`, not `DEFAULT_TIMEOUT`.
- Capitalise acronyms longer than two letters like words: `HttpClient`, `DioErrorUtil`. Two-letter acronyms keep their case: `IO`, `ID`.
- A leading `_` means private and nothing else. DON'T use prefix letters such as `kTimeout` or `mStore`.
- Booleans get a positive, non-imperative verb phrase: `isLoading`, `hasActivePermit`.
- Name a side-effecting method with an imperative verb (`loadPermits`). Name a value-returning one with a noun phrase (`activePermit`).
- AVOID starting a method name with `get`. Use a getter, or a noun.
- Name a method `toX()` when it copies state into a new object, and `asX()` when it returns a view backed by the original.

```dart
// Good
SubscriptionModel? subscriptionFor(String permitId) => ...;

// Bad: "get" prefix, and the name describes its parameter
SubscriptionModel? getSubscriptionForPermit(String permitId) => ...;
```

---

## Imports

> *Source: [Effective Dart: Style](https://dart.dev/effective-dart/style#ordering), [Effective Dart: Usage](https://dart.dev/effective-dart/usage#libraries)*

1. `dart:` imports first, then `package:` imports, then relative imports, then exports in a section of their own. Sort each section alphabetically.
2. DON'T import another package's `src/` directory. The recommended lint `implementation_imports` enforces this.
3. Effective Dart prefers relative paths within `<package>/lib/`. A package that already imports its own code as `package:` paths keeps that form. Symmetry wins: keep a package on one form, the one it already uses.

```dart
// Good
import 'dart:developer' as developer;

import 'package:mobx/mobx.dart';
import 'package:my_app/features/permits/data/permits_repo.dart';

// Bad: dart: import last
import 'package:mobx/mobx.dart';
import 'dart:developer' as developer;
```

---

## Null Safety

> *Source: [Understanding null safety](https://dart.dev/null-safety/understanding-null-safety), [Effective Dart: Usage](https://dart.dev/effective-dart/usage#null)*

Types are non-nullable by default. Make a type nullable only when absence is a real state the caller must handle.

- `!` "always throws if the value is `null`." Every `!` is a runtime assertion. Prefer a null check that promotes the value, or a pattern.
- `late` means "enforce this variable's constraints at runtime instead of at compile time." AVOID `late` when you need to check whether it was initialised. DON'T use `late` where a constructor initialiser list will do.
- DON'T initialise a variable to `null` explicitly, and DON'T write `= null` as a default value.
- Local variables promote after a null check. Public fields and non-final fields don't. At language 3.0, private final fields don't promote either (that needs 3.2), so copy the field into a local first.

```dart
// Good: copy into a local, then promote
final credentials = _authStore.credentials;
if (credentials == null) {
  return;
}
load(credentials.user.id);

// Good: an if-case pattern
if (_authStore.credentials case final credentials?) {
  load(credentials.user.id);
}

// Bad: asserts twice, and throws on the second read if the field changed in between
if (_authStore.credentials != null) {
  load(_authStore.credentials!.user.id);
}
```

A nullable value that hides a missing input behind a default is a failure-handling smell (`coding_guidelines.md` → **Failure**). `credentials?.user.id ?? ''` asks the backend for the permits of the user `''`.

---

## Immutability and const

> *Source: [Effective Dart: Design](https://dart.dev/effective-dart/design#members), [Effective Dart: Usage](https://dart.dev/effective-dart/usage#constructors), [flutter_lints](https://pub.dev/packages/flutter_lints)*

- PREFER `final` for fields and top-level variables. A field that is assigned once is `final`.
- CONSIDER a `const` constructor whenever the class allows one. Every widget whose fields are final gets one.
- DO use initializing formals (`this.plate`) and super parameters (`super.key`).
- DON'T write `new`. DON'T write `const` where the context is already constant.
- AVOID defining custom `==` for mutable classes. If you override `==`, DO override `hashCode`.

`flutter_lints` enforces the const rules: `prefer_const_constructors`, `prefer_const_constructors_in_immutables`, `prefer_const_declarations` and `prefer_const_literals_to_create_immutables`. `use_super_parameters` joined the recommended set in `lints` 3.0.0 ([flutter_lints changelog](https://pub.dev/packages/flutter_lints/changelog)).

```dart
// Good
class PermitPlateBadge extends StatelessWidget {
  const PermitPlateBadge({super.key, required this.plate});

  final String plate;
}

// Bad: the pre-2.17 key plumbing
const PermitPlateBadge({Key? key, required this.plate}) : super(key: key);
```

```dart
// Good
late final PermitsStore _permitsStore = getIt<PermitsStore>();
final AuthStore _authStore = getIt<AuthStore>();

// Bad: reassignable, though nothing reassigns it
AuthStore _authStore = getIt<AuthStore>();
```

---

## Types and Class Design

> *Source: [Effective Dart: Design](https://dart.dev/effective-dart/design), [Class modifiers](https://dart.dev/language/class-modifiers)*

- DO annotate return types and parameter types on function declarations. DON'T annotate initialised locals or inferred lambda parameters.
- AVOID `dynamic` unless you mean to switch off static checking. An untyped JSON map is `Map<String, dynamic>` at the boundary only. Parse it into a model right away.
- DO return `Future<void>` from an async member that produces no value. AVOID `FutureOr<T>` as a return type.
- AVOID returning a nullable `Future`, `Stream` or collection. Return an empty one.
- AVOID positional boolean parameters. Use a named parameter: `loadPermits(userId, manageLoading: false)`.
- AVOID a class with only static members. Use top-level functions and constants.
- AVOID a one-member abstract class when a function type will do.
- DO use class modifiers to say whether a class may be extended or implemented.

A closed set of states is a `sealed` class. The compiler then checks that every `switch` covers every subtype:

```dart
// Good: exhaustive, and adding a subtype breaks every switch that misses it
sealed class CheckoutLinkError {}

final class PermitAlreadyPaid extends CheckoutLinkError {}

final class PermitOutOfDate extends CheckoutLinkError {}

String messageFor(CheckoutLinkError error) => switch (error) {
      PermitAlreadyPaid() => 'Already paid',
      PermitOutOfDate() => 'Reloading permits',
    };

// Bad: an enum-like int or String code with a default branch that swallows new cases
```

---

## Collections and Functions

> *Source: [Effective Dart: Usage](https://dart.dev/effective-dart/usage#collections), [IterableExtensions](https://api.dart.dev/dart-collection/IterableExtensions.html)*

- DO use collection literals: `<PermitModel>[]`, not `List<PermitModel>()`.
- DON'T use `.length` to test for emptiness. Use `isEmpty` and `isNotEmpty`.
- DO use `whereType<T>()` to filter by type. AVOID `cast()`.
- AVOID `Iterable.forEach()` with a function literal. Use a `for` loop.
- DON'T create a lambda when a tear-off will do.
- Use `firstOrNull` (since Dart 3.0) to find an element that may be absent. Never catch the `StateError` from `firstWhere`.

```dart
// Good
PermitModel? get activePermit =>
    permits.where((permit) => permit.isActive).firstOrNull;

// Bad: control flow by exception, and the bare catch hides every other failure
PermitModel? get activePermit {
  try {
    return permits.firstWhere((permit) => permit.isActive);
  } catch (e) {
    return null;
  }
}
```

---

## Asynchrony

> *Source: [Effective Dart: Usage](https://dart.dev/effective-dart/usage#asynchrony), [async and await](https://dart.dev/libraries/async/async-await), [unawaited_futures](https://dart.dev/tools/linter-rules/unawaited_futures), [discarded_futures](https://dart.dev/tools/linter-rules/discarded_futures), [use_build_context_synchronously](https://dart.dev/tools/linter-rules/use_build_context_synchronously)*

- PREFER `async`/`await` over raw `then` chains. DON'T mark a function `async` when it never awaits.
- Every `Future` is awaited, returned, or wrapped in `unawaited(...)` from `dart:async`, which marks a deliberate fire-and-forget. `unawaited_futures` flags this inside `async` bodies and `discarded_futures` flags it inside synchronous ones. Neither is in `flutter_lints`, so `<package>/analysis_options.yaml` enables them (see [Tooling](#tooling)).
- Run independent work concurrently with `Future.wait`.
- AVOID `Completer` in production code. It belongs in tests, where it holds a future open on purpose.
- CONSIDER higher-order methods (`map`, `where`, `asyncMap`) to transform a `Stream`.
- DON'T use a `BuildContext` across an `await`. After the gap, check `mounted` in a `State`, or `context.mounted` for any other context.

```dart
// Good
@override
void initState() {
  super.initState();
  unawaited(_loadData());
}

// Bad: a dropped future, and any error it raises is unhandled
@override
void initState() {
  super.initState();
  _loadData();
}
```

```dart
// Good
Future<void> _cancel() async {
  await _store.cancelPermit(permitId);
  if (!mounted) {
    return;
  }
  Navigator.of(context).pop();
}
```

---

## Error Handling

> *Source: [Effective Dart: Usage](https://dart.dev/effective-dart/usage#error-handling), [Error handling](https://dart.dev/language/error-handling)*

What an error must be is governed by `coding_guidelines.md` → **Failure**. These are the Dart mechanics:

- AVOID `catch` without an `on` clause. DON'T discard the error from one: a bare `catch` is only for a top-level boundary that logs and reports.
- Throw types implementing `Error` only for programming mistakes. Throw `Exception` subtypes for conditions a caller can handle.
- DON'T catch `Error` or its subtypes (`StateError`, `TypeError`, `RangeError`). They mean the code is wrong.
- DO use `rethrow` to pass on an exception you partly handled. It keeps the original stack trace, which `throw e` loses.
- Put cleanup in `finally`. It runs whether or not anything was thrown.

```dart
// Good: the expected failure is named, and the store still says what happened
try {
  permits
    ..clear()
    ..addAll(await _permitsRepo.getPermits(userId));
} on DioException catch (e, stack) {
  developer.log('Loading permits failed', name: 'PermitsStore', error: e, stackTrace: stack);
  errorStore.errorMessage = DioErrorUtil.handleError(e);
} finally {
  isLoading = false;
}

// Bad: a parse bug or a null dereference becomes a "network error" message
} catch (e) {
  errorStore.errorMessage = DioErrorUtil.handleError(e);
}
```

---

## Widgets and Build Methods

> *Source: [Flutter performance best practices](https://docs.flutter.dev/perf/best-practices), [State.dispose](https://api.flutter.dev/flutter/widgets/State/dispose.html), [flutter_lints](https://pub.dev/packages/flutter_lints)*

- `build()` "can be invoked frequently." Keep it free of I/O, allocation-heavy work and side effects. Load data in `initState` or in a store action, never in `build`.
- "To create reusable pieces of UIs, prefer using a `StatelessWidget` rather than a function." A private `_buildHeader()` method that returns a widget is a widget class waiting to be extracted.
- Split a large `build()` "based on encapsulation but also on how they change." The part that rebuilds should be the smallest subtree that reads the state. For MobX, that means the `Observer` wraps only what reads observables.
- For long or unbounded lists, use the lazy builders (`ListView.builder`, `GridView.builder`). A `Column` or a plain `ListView(children: ...)` builds every child up front.
- AVOID `Opacity`, and particularly in animations. Draw with a semitransparent colour, or use `AnimatedOpacity`.
- A `State` releases what it holds in `dispose()`: controllers, subscriptions, MobX `ReactionDisposer`s, animations. Its last line is `super.dispose()`.
- Give list children a `Key` derived from their data when the list can reorder or change.
- The `child` argument comes last (`sort_child_properties_last`). Use `SizedBox` for whitespace, not an empty `Container` (`sized_box_for_whitespace`).
- Colours, sizes and text styles come from the theme or the app's constants, never hand-picked per widget. Contrast, tap targets, labels and text scaling follow `accessibility_guidelines.md`.

```dart
// Good: a widget, const-constructible, rebuilt only when its inputs change
class _PermitList extends StatelessWidget {
  const _PermitList({required this.permits});

  final List<PermitModel> permits;

  @override
  Widget build(BuildContext context) => ListView.builder(
        itemCount: permits.length,
        itemBuilder: (context, i) => PermitCard(
          key: ValueKey(permits[i].id),
          permit: permits[i],
        ),
      );
}

// Bad: a helper method; it rebuilds with its parent and can't be const
Widget _buildPermitList() => ListView(children: [for (final p in permits) PermitCard(permit: p)]);
```

---

## State Management

> *Source: [MobX getting started](https://mobx.netlify.app/getting-started), [flutter_mobx](https://pub.dev/packages/flutter_mobx), [get_it](https://pub.dev/packages/get_it), [provider via InheritedWidget](https://docs.flutter.dev/data-and-backend/state-mgmt/options), [build_runner](https://pub.dev/packages/build_runner)*

Where a package keeps state in **MobX** stores, with code generated by `mobx_codegen`, and locates stores and services through **get_it**, these rules hold. A package embedded in a host app keeps its own container, `GetIt.asNewInstance()`, so it never collides with the host's `GetIt.instance`.

### Stores

A store is a generated class over an abstract base `with Store`. It lives in the feature's application folder, beside its data, domain and presentation folders:

```dart
part 'permits_store.g.dart';

class PermitsStore = PermitsStoreBase with _$PermitsStore;

abstract class PermitsStoreBase with Store {
  PermitsStoreBase(this._permitsRepo);

  final PermitsRepo _permitsRepo;

  @observable
  ObservableList<PermitModel> permits = ObservableList<PermitModel>();

  @computed
  bool get hasActivePermit => activePermit != null;

  @action
  Future<void> loadPermits(String userId) async { ... }
}
```

- State is `@observable`. Anything derivable from it is `@computed`, never a second observable kept in sync by hand ("AVOID storing what you can calculate", [Effective Dart: Usage](https://dart.dev/effective-dart/usage#variables)).
- Every mutation of an observable happens inside an `@action`.
- A store gets its repositories through its constructor. One that builds its own (`final PermitsRepo _permitsRepo = PermitsRepo();`) can only be tested by mocking the HTTP client underneath it.
- After editing a store, regenerate with `dart run build_runner build`. Commit the `.g.dart` file with the store it belongs to.

### Widgets

- Wrap the smallest subtree that reads observables in `Observer`. An `Observer` whose builder reads no observable "will print a warning", and it is a bug: it never rebuilds.
- A widget gets its store from the locator in `initState`, or from `context.read<T>()` where the app provides it through `provider`. It never constructs a store.
- A `reaction(...)` started in `initState` keeps its `ReactionDisposer`, and `dispose()` calls it.

### The locator

- Register in one place per package (`setupLocator()`): `registerSingleton` for what lives as long as the app, `registerLazySingleton` for what is built on first use, `registerFactory` for a fresh instance each time.
- Resolve from the locator at a composition root (`initState`, the router, `setupLocator`). Deeper code receives its dependencies as constructor arguments.

---

## Documentation

> *Source: [Effective Dart: Documentation](https://dart.dev/effective-dart/documentation)*

- DO use `///` for doc comments. Start with a one-sentence summary in its own paragraph.
- Refer to in-scope identifiers in square brackets: `[checkoutLinkError]`.
- A side-effecting method's comment starts with a third-person verb ("Reloads ..."). A boolean's starts with "Whether ...".
- Put doc comments before annotations.
- What a comment may say at all is governed by `coding_guidelines.md` → **Comments**.

```dart
/// Asks the backend for the hosted checkout link of a pending monthly permit.
///
/// Returns null without a link; [checkoutLinkError] says why.
@action
Future<String?> startPermitPayment(String userId, String permitId) async { ... }
```

---

## Testing

> *Source: [Flutter testing overview](https://docs.flutter.dev/testing/overview), [Widget testing](https://docs.flutter.dev/cookbook/testing/widget/introduction), [Accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing), [mocktail](https://pub.dev/packages/mocktail), [get_it](https://pub.dev/packages/get_it), [matchesGoldenFile](https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html)*

"A well-tested app has many unit and widget tests, tracked by code coverage, plus enough integration tests to cover all the important use cases." Tests mirror `<package>/lib/`: `lib/features/x/application/x_store.dart` is tested by `test/features/x/application/x_store_test.dart`.

### Unit tests: stores and repositories

Mock with `mocktail`, which needs no code generation.

- A mock is `class MockDio extends Mock implements Dio {}`.
- Stub with `when(() => ...)`. Use `thenAnswer((_) async => ...)` for anything returning a `Future`. An unstubbed method returns `null`, which throws a `TypeError` for a non-nullable `Future`.
- `verify(() => ...).called(n)` asserts an interaction that is itself the behaviour, such as a reload. Prefer asserting on the store's resulting state.
- Matching a custom type with `any()` needs `registerFallbackValue` once per type, in `setUpAll`.
- Use a `Completer` to hold a request open and assert the in-flight state.
- Swap a locator registration in `setUp`, and restore the locator in `tearDown` with `await getIt.reset()`. A registration that outlives its test makes the next test's result depend on run order.

```dart
// Good
setUp(() {
  dio = MockDio();
  getIt.registerSingleton<Dio>(dio);
  store = PermitsStore();
});

tearDown(() => getIt.reset());

test('returns the checkout link and marks the permit while it waits', () async {
  final response = Completer<Response<dynamic>>();
  when(() => dio.post(linkPath)).thenAnswer((_) => response.future);

  final pending = store.startPermitPayment(userId, permitId);
  expect(store.paymentPermitId, permitId);
  response.complete(link('https://c.example/ck'));

  expect(await pending, 'https://c.example/ck');
  expect(store.paymentPermitId, isNull);
});
```

### Widget tests

- `testWidgets` gives each case a `WidgetTester`. `pumpWidget` builds the tree. `pump()` renders one frame, and `pumpAndSettle()` renders frames until none is scheduled.
- Find widgets by what the user sees (`find.text`, `find.bySemanticsLabel`) before falling back to `find.byType`. Assert with `findsOneWidget`, `findsNothing` and `findsNWidgets(n)`.
- Mock the store (`class MockPermitsStore extends Mock implements PermitsStore {}`) and stub its observables, so the test sets the state the widget renders.
- Fake a platform plugin at its platform interface, for example with a fake `InAppWebViewPlatform`. Never let a widget test reach a real plugin.
- `test/flutter_test_config.dart` is the suite-wide setup, for work done once before any `pump`, such as warming a localisation cache.

### Accessibility tests

Every new widget with text or a tap target gets a guideline test:

```dart
testWidgets('meets the tap target and contrast guidelines', (tester) async {
  final handle = tester.ensureSemantics();
  await tester.pumpWidget(wrap(const StatusBadgeWidget(status: 'active', label: 'Active')));

  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  handle.dispose();
});
```

### Golden tests

For a golden test:

- Assert with `await expectLater(find.byType(X), matchesGoldenFile('goldens/x.png'))`.
- Regenerate with `flutter test --update-goldens`.
- Generate goldens on one fixed platform, because fonts render differently across operating systems and Flutter versions. Load real fonts with `FontLoader` in `flutter_test_config.dart`, since tests otherwise render the Ahem font.

---

## Complexity and Mutation

> *Source: `~/.claude/scripts/change_gate.py`, [mutation_test](https://pub.dev/packages/mutation_test), builtin rules printed by `dart pub global run mutation_test -g`*

- No function is above cyclomatic complexity 10. `~/.claude/scripts/change_gate.py` measures every changed `.dart` file with lizard.
- Every mutant on a changed line is killed. `change_gate.py` runs the `mutation_test` package over the changed lines. Install it with `dart pub global activate mutation_test`. It tests with the command given as `--test 'dart=<command>'`, which is the one CI runs, else with `flutter test` in a Flutter package (a `<package>/pubspec.yaml` that names `flutter:`) and with `dart test` otherwise.
- The builtin rules don't mutate a bare `<` or `>`. They mutate only `<=` and `>=` (to `==` and to the strict form), `==`, `!=`, `&&`, `||`, arithmetic, compound assignment, number literals, argument order and void calls. The rule that negates a whole `if` condition (`builtin.if`) matches only an `if` whose condition is followed by `{`. So write every `if` with braces, and test every boundary yourself, because nothing will mutate it for you.
- An undetected mutant fails the gate.
- A mutant that no test can tell apart from the original is accepted only when its line carries `// mutation: equivalent — <reason>`.

---

## Tooling

> *Source: [Analysis options](https://dart.dev/tools/analysis), [flutter_lints](https://pub.dev/packages/flutter_lints), [flutter_lints changelog](https://pub.dev/packages/flutter_lints/changelog), [async and await](https://dart.dev/libraries/async/async-await)*

### Lint set

`<package>/analysis_options.yaml` includes the `flutter_lints` Flutter set, which builds on the `lints` recommended set, which in turn builds on its core set.


The `flutter_lints` README says to add it as a dev dependency (`flutter pub add dev:flutter_lints`). An include of a package that isn't a dependency is a gap.

The latest version is `flutter_lints` 6.0.0, which needs Flutter 3.32 / Dart 3.8. Each major adds rules (3.0.0 added `use_super_parameters`; 6.0.0 added `strict_top_level_inference` and `unnecessary_underscores`). Upgrade it as its own change, with every new diagnostic fixed in that change.

### analysis_options.yaml

```yaml
include: package:flutter_lints/flutter.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
  exclude:
    - "**/*.g.dart"

linter:
  rules:
    - unawaited_futures
    - discarded_futures
    - avoid_catches_without_on_clauses
    - prefer_final_locals
```

- The three strict modes "all default to `false`" and catch implicit `dynamic` that the default type system allows.
- `unawaited_futures` and `discarded_futures` are the two lints the Dart async guide recommends. Neither is in any `lints` or `flutter_lints` set.
- Suppress a single diagnostic with `// ignore: <rule>` and a reason. `// ignore_for_file:` is for generated code only.

### Commands

| Command | Purpose |
|---|---|
| `dart format .` | Formatting (the formatter's own choices; no config at language 3.0) |
| `flutter analyze` | Analyzer and lints from `<package>/analysis_options.yaml` |
| `flutter test` | Unit and widget tests |
| `flutter test --update-goldens` | Regenerates golden images |
| `dart run build_runner build` | Regenerates MobX `.g.dart` files |
| `~/.claude/scripts/change_gate.py` | Complexity and mutation gate on the changed lines |

---

## Sources

This guide is compiled from these authoritative sources:

1. **[Effective Dart: Style](https://dart.dev/effective-dart/style)**: naming, ordering, formatting
2. **[Effective Dart: Documentation](https://dart.dev/effective-dart/documentation)**: doc comments
3. **[Effective Dart: Usage](https://dart.dev/effective-dart/usage)**: null, collections, constructors, errors, asynchrony
4. **[Effective Dart: Design](https://dart.dev/effective-dart/design)**: API names, types, class modifiers, parameters
5. **[Understanding null safety](https://dart.dev/null-safety/understanding-null-safety)**: `!`, `late`, promotion
6. **[Language versioning](https://dart.dev/language/versioning)** and **[Language evolution](https://dart.dev/resources/language/evolution)**: which features each language version enables
7. **[Class modifiers](https://dart.dev/language/class-modifiers)**: `sealed`, `final`, `base`, `interface`
8. **[Error handling](https://dart.dev/language/error-handling)**: `on`, `catch`, `rethrow`, `finally`
9. **[async and await](https://dart.dev/libraries/async/async-await)**, **[unawaited_futures](https://dart.dev/tools/linter-rules/unawaited_futures)**, **[discarded_futures](https://dart.dev/tools/linter-rules/discarded_futures)**, **[use_build_context_synchronously](https://dart.dev/tools/linter-rules/use_build_context_synchronously)**, **[curly_braces_in_flow_control_structures](https://dart.dev/tools/linter-rules/curly_braces_in_flow_control_structures)**
10. **[Analysis options](https://dart.dev/tools/analysis)** and **[dart format](https://dart.dev/tools/dart-format)**: lint configuration, strict modes, formatter options
11. **[dart_style CHANGELOG](https://dart.googlesource.com/dart_style/+/refs/tags/v3.1.1/CHANGELOG.md)**: the short and tall formatter styles
12. **[IterableExtensions](https://api.dart.dev/dart-collection/IterableExtensions.html)**: `firstOrNull`
13. **[Flutter performance best practices](https://docs.flutter.dev/perf/best-practices)**: build cost, widgets over helper functions, lazy lists
14. **[State.dispose](https://api.flutter.dev/flutter/widgets/State/dispose.html)**: releasing resources
15. **[Flutter state management options](https://docs.flutter.dev/data-and-backend/state-mgmt/options)**: `provider` over `InheritedWidget`
16. **[Flutter testing overview](https://docs.flutter.dev/testing/overview)**, **[Widget testing](https://docs.flutter.dev/cookbook/testing/widget/introduction)**, **[Accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing)**, **[matchesGoldenFile](https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html)**
17. **[flutter_lints](https://pub.dev/packages/flutter_lints)** and its **[changelog](https://pub.dev/packages/flutter_lints/changelog)**: the lint set, versions, SDK floors
18. **[MobX getting started](https://mobx.netlify.app/getting-started)**, **[flutter_mobx](https://pub.dev/packages/flutter_mobx)**, **[build_runner](https://pub.dev/packages/build_runner)**: stores, `Observer`, code generation
19. **[get_it](https://pub.dev/packages/get_it)** and **[mocktail](https://pub.dev/packages/mocktail)**: service location and mocking in tests
20. **[mutation_test](https://pub.dev/packages/mutation_test)** and its **[versions](https://pub.dev/packages/mutation_test/versions)**: the mutation tester `change_gate.py` runs

For updates, refer to the original sources as Dart and Flutter conventions evolve.

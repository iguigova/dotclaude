# JavaScript and TypeScript Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

## Core Principles

**Priority order**, the rest of `coding_guidelines.md`, and the layout rules in `style_guidelines.md` hold here unchanged. This guide covers only what is specific to JavaScript and TypeScript, and gives worked examples in their syntax.

The code comes in two kinds. The rules apply to both unless a heading is marked **(TS)**, which means it is for TypeScript only.

- **Plain browser JavaScript, no build step.** The page loads ES modules directly with `<script type="module">`. Tests run under `node --test`.
- **Typed React apps.** TypeScript under `strict`, linted with ESLint, tested with Jest or Vitest and Testing Library.

---

## Formatting

### Use the repository's formatter, or match the file
> *Source: [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html#432-semicolons-are-required)*

If a repository configures Prettier, Prettier decides the layout, and the lint run enforces it through `prettier/prettier`. If a repository has no formatter, the existing files are the standard. For example, one plain-JS project indents 4 spaces and uses double quotes, while another indents 2 and uses single quotes. A new line matches its own file.

Every statement ends with a semicolon: "Every statement must be terminated with a semicolon."

### One variable per declaration
> *Source: [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html#512-one-variable-per-declaration)*

"Every local variable declaration declares only one variable."

```js
// Good
const width = 640;
const height = 480;

// Bad
const width = 640, height = 480;
```

---

## Naming

> *Source: [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html#622-class-names), [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#naming-style)*

| Entity | Convention | Example |
|---|---|---|
| Variables, functions, methods | `lowerCamelCase` | `loadHttpUrl`, `score` |
| Classes, interfaces, types, enums, React components | `UpperCamelCase` | `BookingForm`, `NodeRecord` |
| Module-level constants | `CONSTANT_CASE` | `MAX_RETRIES`, `SUIT_INDEX` |
| Custom React hooks | `use` + `UpperCamelCase` | `useModules` |

- Treat an acronym as a word: `loadHttpUrl`, not `loadHTTPURL`.
- Don't put a leading or trailing underscore on a property or method to mark it private. The module boundary or `private` already does that. Repositories that let unused arguments start with `_` may use that prefix for those arguments.
- When a repository already has a settled naming style, follow it in that repository. The table above is for a repository that has none.

---

## Variables and Equality

### `const` by default, `let` when reassigned, never `var`
> *Source: [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html#511-use-const-and-let)*

"Use `const` by default, unless a variable needs to be reassigned. The `var` keyword must not be used."

```js
// Good
const ranks = [];
for (let r = 14; r >= 2; r--) ranks.push(r);

// Bad
var ranks = [];
```

`const` fixes the binding, not the value. A `const` array can still be pushed to. For immutable values, see [Immutability](#immutability).

### Strict equality
> *Source: [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#equality-checks), [ESLint `eqeqeq`](https://eslint.org/docs/latest/rules/eqeqeq)*

"Always use triple equals (`===`) and not equals (`!==`)." The one exception is a comparison with the literal `null`. There, `x == null` matches both `null` and `undefined` in one test. ESLint's `eqeqeq` with `"null": "ignore"` enforces exactly this.

```js
// Good
if (event.kind === REACTION) { ... }
if (value == null) return;   // null or undefined

// Bad
if (event.kind == "7") { ... }
```

### Never `eval`, `with`, or edits to built-in prototypes
> *Source: [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html#5112-dynamic-code-evaluation)*

"Do not use `eval` or the `Function(...string)` constructor." "Do not use the `with` keyword." "Never modify builtin types, either by adding methods to their constructors or to their prototypes."

---

## Modules

### ES modules, named exports
> *Source: [MDN: JavaScript modules](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules), [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#exports)*

Every file is an ES module. Modules "are automatically in strict mode." They also run "in their own scope, not in the global scope." So nothing a module declares reaches `window` unless it is exported.

"Do not use default exports. This ensures that all imports follow a uniform pattern." The exception is a framework that loads a module's default export, such as a route module's component.

```js
// Good
export function score(cards) { ... }
import { score } from "./poker.js";

// Bad
export default function (cards) { ... }
```

### Import paths carry the `.js` extension (plain JS)
> *Source: [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html#34111-file-extensions-in-import-paths)*

"The `.js` file extension is not optional in import paths and must always be included." Without a bundler, the browser resolves the path exactly as it is written.

### Loading modules in a page (plain JS)
> *Source: [MDN: `<script>`](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script), [MDN: JavaScript modules](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules)*

```html
<script type="module" src="src/main.js"></script>
```

"The `defer` attribute has no effect on module scripts — they defer by default." So a module script needs no `DOMContentLoaded` wrapper. The server must send modules "with a `Content-Type` header that contains a JavaScript MIME type such as `text/javascript`," so serve the page over a local HTTP server.

### No namespaces (TS)
> *Source: [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#use-modules-not-namespaces)*

Use modules, never `namespace Foo { ... }`. The only exception is declaring third-party code that is shaped that way.

---

## Functions

### Arrow functions for nested functions and callbacks
> *Source: [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html#553-arrow-functions)*

"Prefer arrow functions over the `function` keyword for nested functions." A top-level function may be either a `function` declaration or a `const` arrow. Use whichever form the file already uses, and use it everywhere in that file.

```js
// Good
const likes = reactions.filter((event) => event.kind === REACTION);

// Bad
const likes = reactions.filter(function (event) { return event.kind === REACTION; });
```

### A predicate returns a function, so it composes
```js
// Good: `is(label)` maps and filters directly
const is = (label) => (node) => labels(node.event).includes(label);
const offers = replies.filter(is(OFFER));
```

---

## Error Handling

This section covers JavaScript mechanics only. What an error must *be* is set by `coding_guidelines.md` → **Failure**, the only place those rules live.

### Throw `Error` objects only
> *Source: [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#only-throw-errors)*

Never throw a string, number, `null` or `undefined`. Throw only `Error` or one of its subclasses, so the caller gets a stack trace.

### Wrap with `cause`
> *Source: [MDN: Error.cause](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Error/cause)*

When you rethrow with a more specific message, pass the original error along: `throw new Error("…", { cause: err })`. The original error is then still there for whoever reads the chain.

```js
// Good
try {
    await relay.publish(event);
} catch (err) {
    throw new Error(`publishing to ${relay.url}`, { cause: err });
}

// Bad: the original stack is gone
} catch (err) {
    throw new Error("publish failed");
}
```

### A caught value is `unknown` (TS)
> *Source: [TSConfig: useUnknownInCatchVariables](https://www.typescriptlang.org/tsconfig/#useUnknownInCatchVariables)*

Under `strict`, a `catch` variable has the type `unknown`. Narrow it before you use it.

```ts
} catch (err) {
  if (err instanceof Error) report(err.message);
  else throw err;
}
```

### `fetch` resolves on an HTTP error
> *Source: [MDN: fetch()](https://developer.mozilla.org/en-US/docs/Web/API/Window/fetch)*

"A `fetch()` promise *does not* reject if the server responds with HTTP status codes that indicate errors." Check `response.ok` before you read the body. Put the status in the error, too, so a 404 and a 503 can be told apart.

```ts
// Good
const response = await fetch(url);
if (!response.ok) throw new Error(`GET ${url}: ${response.status}`);
return response.json();

// Bad: a 500 page parses as data, or fails later as a JSON error
return (await fetch(url)).json();
```

---

## Async

### No floating promises
> *Source: [typescript-eslint: no-floating-promises](https://typescript-eslint.io/rules/no-floating-promises/)*

Every promise is either awaited, returned, or given a rejection handler. A promise that is "created without any code set up to handle any errors it might throw" hides its failure. In TypeScript, `@typescript-eslint/no-floating-promises` reports these, and `recommended-type-checked` turns that rule on.

```ts
// Good
await save(draft);

// Bad: a rejection disappears
save(draft);
```

### `Promise.all` for dependent work, `Promise.allSettled` for independent work
> *Source: [MDN: Promise.allSettled()](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise/allSettled)*

`Promise.all` rejects as soon as any input rejects. That is right "if the tasks are dependent on each other." `Promise.allSettled` reports every outcome. That fits "multiple asynchronous tasks that are not dependent on one another." This is the per-item guard that **Failure** asks for in a loop.

```js
// Good: one relay down does not abandon the others
const results = await Promise.allSettled(relays.map((r) => r.publish(event)));
const failed = results.filter((r) => r.status === "rejected");
```

Use `await` inside a `for` loop only when each step needs the one before it. Otherwise the loop runs the work one item at a time for no reason.

---

## Immutability

### Copy instead of mutating
> *Source: [MDN: Array.prototype.toSorted()](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/toSorted)*

`toSorted()`, `toReversed()`, `toSpliced()` and `with()` return a new array and leave the original unchanged. They are Baseline "Widely available." Use them, or spread, in place of `sort`, `reverse`, `splice` and index assignment on a value someone else holds.

```js
// Good
const ordered = requests.toSorted((a, b) => b.backers - a.backers);
const tagged = { ...draft, tags: [...draft.tags, ["t", label]] };

// Bad: changes the caller's array and draft
requests.sort((a, b) => b.backers - a.backers);
draft.tags.push(["t", label]);
```

### `Object.freeze` is shallow
> *Source: [MDN: Object.freeze()](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Object/freeze)*

Freezing applies "only to the immediate properties." A nested object stays writable. A frozen table of constants holds only if its values are primitives, or if those values are frozen too.

### `readonly` at the type level (TS)
Mark a parameter `readonly T[]` or `Readonly<T>` when the function must not change it. Then the compiler rejects a `push` or an assignment on it.

---

## TypeScript (TS)

### Compiler strictness
> *Source: [TSConfig: strict](https://www.typescriptlang.org/tsconfig/#strict), [TSConfig: noUncheckedIndexedAccess](https://www.typescriptlang.org/tsconfig/#noUncheckedIndexedAccess)*

`"strict": true` turns on the whole strict family: `noImplicitAny`, `strictNullChecks`, `strictFunctionTypes`, `useUnknownInCatchVariables` and the rest. `noUncheckedIndexedAccess` is not part of `strict`, so set it separately. It adds `undefined` to every index-signature read, which makes `items[0]` and `record[key]` admit that they can miss. Never turn a strict check off to get code to compile.

### `unknown`, not `any`
> *Source: [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#any-unknown)*

For a value whose type you don't know yet, such as a parsed body or a `postMessage` payload, use `unknown`. Then narrow it, or validate it with the repository's schema library.

### No type assertions as a substitute for a check
> *Source: [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#type-and-non-nullability-assertions)*

"Type assertions (`x as SomeType`) and non-nullability assertions (`y!`) are unsafe." They tell the compiler something nobody checked. Narrow with a runtime test instead. Keep an assertion only where the reason it holds is stated next to it.

```ts
// Good: a missing param fails here, by name
const companyId = params.companyId;
if (companyId === undefined) throw new Error("route has no companyId");

// Bad: undefined flows on typed as string
const companyId = params.companyId as string;
```

### Discriminated unions, checked to the end
> *Source: [TypeScript Handbook: Narrowing](https://www.typescriptlang.org/docs/handbook/2/narrowing.html)*

Model a value that can take several shapes as a union with a literal `kind`. Assign the `default` branch to `never`. Then a new member that nobody handles becomes a compile error instead of a silent fall-through.

```ts
type NodeRecord =
  | { kind: "value"; value: unknown }
  | { kind: "object" }
  | { kind: "list"; order: Array<string | number> };

function size(node: NodeRecord): number {
  switch (node.kind) {
    case "value": return 1;
    case "object": return 0;
    case "list": return node.order.length;
    default: {
      const unhandled: never = node;
      return unhandled;
    }
  }
}
```

### `satisfies` to check without widening
> *Source: [TypeScript 4.9 release notes](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-9.html)*

`satisfies` checks "that the type of an expression matches some type, without changing the resulting type of that expression." Use it on configuration tables and lookup maps, so a typo in a key is caught and every value keeps its literal type.

```ts
const ERROR_KEYS = {
  expired_card: "messages.paymentErrorExpiredCard",
  card_declined: "messages.paymentErrorCardDeclined",
} satisfies Record<string, string>;
```

### Interfaces for object types; no `const enum`
> *Source: [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html#prefer-interfaces-over-type-literal-aliases)*

Declare an object type with `interface`. Keep `type` for unions, tuples and mapped types. "Code *must not* use `const enum`; use plain `enum` instead." Never coerce an enum value with `!!` or `Boolean()`. Compare it explicitly.

### Types for a plain-JS library
When the JavaScript is the source of truth, ship a hand-written `index.d.ts` beside it. Add a test that checks the two export the same names, so the declarations can't drift from the code.

---

## Browser and DOM (plain JS and React)

### Text goes in as text
> *Source: [MDN: Element.innerHTML](https://developer.mozilla.org/en-US/docs/Web/API/Element/innerHTML)*

`innerHTML` "is probably the most common vector for cross-site scripting (XSS) attacks." Put user or network content in with `textContent`, or build it with `createElement`. In React, never pass such content to `dangerouslySetInnerHTML`.

```js
// Good
item.textContent = event.content;

// Bad: a relay's content runs as markup
item.innerHTML = event.content;
```

### Accessibility
UI code in either kind follows `accessibility_guidelines.md`. In the React apps, `eslint-plugin-jsx-a11y` reports a subset of those rules while you edit. Passing that plugin is necessary, but it is not enough.

---

## React Components and Hooks

### Rules of Hooks
> *Source: [React: Rules of Hooks](https://react.dev/reference/rules/rules-of-hooks)*

"Don't call Hooks inside loops, conditions, nested functions, or `try`/`catch`/`finally` blocks." Call them at the top level of a component or of a custom Hook, "before any early returns." `eslint-plugin-react-hooks` enforces this.

### Dependency arrays are complete
> *Source: [React: exhaustive-deps](https://react.dev/reference/eslint-plugin-react-hooks/lints/exhaustive-deps)*

A dependency left out of `useEffect`, `useMemo` or `useCallback` leaves "stale closures where the hook uses outdated values." Keep `react-hooks/exhaustive-deps` on. "If you find yourself fighting with the linter, you likely need to restructure your code." Restructure the code. Don't silence the rule.

### Derive during render; Effects only for external systems
> *Source: [React: You Might Not Need an Effect](https://react.dev/learn/you-might-not-need-an-effect)*

"When something can be calculated from the existing props or state, don't put it in state. Instead, calculate it during rendering." An action the user triggers belongs in its event handler. Effects "synchronize your components with some external system," such as the network, a non-React widget or the DOM, and they are for nothing else.

```tsx
// Good
const fullName = `${first} ${last}`;

// Bad: an extra render and a second source of truth
const [fullName, setFullName] = useState("");
useEffect(() => setFullName(`${first} ${last}`), [first, last]);
```

### State is read-only
> *Source: [React: Updating Objects in State](https://react.dev/learn/updating-objects-in-state)*

"Treat all state in React as immutable." When you mutate state, React never re-renders, because "React has no idea that object has changed." Pass the setter a new object instead.

```tsx
// Good
setPerson({ ...person, firstName: e.target.value });

// Bad
person.firstName = e.target.value;
```

### Stable keys from the data
> *Source: [React: Rendering Lists](https://react.dev/learn/rendering-lists)*

"Keys must be unique among siblings" and "must not change." Take keys from the data's ids. An array index breaks when the list is reordered. `Math.random()` recreates every item on each render and loses the user's input.

```tsx
// Good
people.map((p) => <li key={p.id}>{p.name}</li>);

// Bad
people.map((p, i) => <li key={i}>{p.name}</li>);
```

---

## Testing

The runner is whatever the repository's `npm test` script runs: `node --test` in the plain-JS projects, Jest or Vitest in the React apps. `coding_guidelines.md` → **Verification** sets the coverage bar, which is every line of every changed file. The configuration below is how each runner enforces it.

### Coverage counts the whole file, including files no test imports
> *Source: [Node.js CLI](https://nodejs.org/api/cli.html), [Jest configuration](https://jestjs.io/docs/configuration#coveragethreshold-object), [Vitest coverage](https://vitest.dev/config/coverage)*

- **node:test.** `--experimental-test-coverage --test-coverage-include='src/**' --test-coverage-lines=100`. `--test-coverage-lines` makes the process "exit with code `1`" when line coverage falls below the threshold. The flag is marked Experimental.
- **Jest.** `collectCoverageFrom` collects coverage for a matching file "even if no tests exist for this file." `coverageThreshold` makes Jest fail when a threshold is missed, and it takes per-path globs.
- **Vitest.** `coverage.include` defaults to "Files that were imported during test run," so an untested file is invisible until you name it there. `coverage.thresholds` with `perFile: true` checks each file against the threshold, not the project-wide aggregate.

### Node assertions in strict mode
> *Source: [Node.js: assert](https://nodejs.org/api/assert.html)*

`import assert from "node:assert/strict"`. In strict mode, `deepEqual` behaves as `deepStrictEqual`, and an object mismatch prints a diff.

```js
import { test } from "node:test";
import assert from "node:assert/strict";

test("a request is a comment on the product labelled request", () => {
    const draft = request(PRODUCT, "dark mode", 10);
    assert.deepEqual(draft.tags.at(-1), ["t", "request"]);
});
```

Name each test as a sentence that states the behaviour. The plain-JS projects test DOM code under `node --test` against `linkedom`, with no browser.

### Table-driven cases
Several inputs with one expectation are one `it.each` (Jest, Vitest), not copies of the same test:

```ts
it.each(["insufficient_funds", "card_velocity_exceeded"])(
  "maps %s to paymentErrorInsufficientFunds",
  (code) => {
    expect(getPaymentErrorMessageKey(code)).toBe("messages.paymentErrorInsufficientFunds");
  },
);
```

### Query the way a user would
> *Source: [Testing Library: Queries](https://testing-library.com/docs/queries/about/#priority), [Testing Library: user-event](https://testing-library.com/docs/user-event/intro)*

"Your test should resemble how users interact with your code." Reach for `getByRole` first, then `getByLabelText`, then `getByText`. Use `getByTestId` only "for cases where you can't match by role or text." Drive input with `user-event`, not `fireEvent`. `user-event` "simulates full interactions," and it refuses what a browser would refuse, such as typing into a disabled field. Call `userEvent.setup()` before you render.

```tsx
const user = userEvent.setup();
render(<BookingLicensePlateForm />);
await user.type(screen.getByLabelText("Licence plate"), "AB12 CDE");
await user.click(screen.getByRole("button", { name: "Continue" }));
```

### Deterministic time
Pin the time zone in the test script, as in `TZ=${TZ:-UTC} vitest run`. Never let a test read the real clock. Pass the time in, or use the runner's fake timers.

---

## Complexity and mutation

### No function above cyclomatic complexity 10
> *Source: [lizard](https://github.com/terryyin/lizard), [ESLint `complexity`](https://eslint.org/docs/latest/rules/complexity)*

`~/.claude/scripts/change_gate.py` measures every changed file with lizard. A function above 10 fails the gate. Lizard reads JavaScript "with ES6 and JSX" and TypeScript "with TSX." It counts each default parameter as a branch, so a function with two defaults starts at 3. To see the number in the editor, set ESLint's `complexity` rule to 10. Its default is 20.

```js
// eslint.config.js
rules: { complexity: ["error", 10] }
```

### Every mutant on a changed line is killed
> *Source: [StrykerJS configuration](https://stryker-mutator.io/docs/stryker-js/configuration/)*

`change_gate.py` runs StrykerJS (`@stryker-mutator/core`) over the changed line ranges, testing with the command given as `--test 'js=<command>'`, which is the one CI runs, else the repository's `npm test`. A mutant that survives fails the gate. So does a mutant that no test covers. A repository with no `test` script cannot pass.

A mutant that no test can tell apart from the original is accepted only when its line carries the gate's marker, with the reason saying why:

```js
const frozen = Object.freeze(table);  // mutation: equivalent — nothing writes to table, so freezing only states it
```

The gate reads its own marker. Never use Stryker's `// Stryker disable` comments.

---

## Anti-Patterns

### Loosening the type to make an error go away (TS)
An `any`, an `as`, a `!`, a `// @ts-ignore`, or a strict flag turned off each removes a check instead of fixing its cause. Each one falls under **Verification**: never loosen a check to pass it.

### Swallowing a rejection into a falsy value
`.catch(() => null)` and `catch { return []; }` turn "the request failed" into "there is nothing." **Failure** forbids exactly this.

### Module-level mutable state
A `let` at the top of a module is a global that every importer shares and none of them can see. Pass the state in, or keep it in the one component or closure that owns it.

### Effects that mirror state
An Effect whose only job is to copy one piece of state into another is a second source of truth. Derive the value during render instead.

---

## Tooling

| Tool | Purpose |
|---|---|
| **ESLint** | Linting. ESLint looks for a flat config named `eslint.config.js`, `.mjs`, `.cjs`, `.ts`, `.mts` or `.cts` ([ESLint: configuration files](https://eslint.org/docs/latest/use/configure/configuration-files)) |
| **typescript-eslint** | Type-aware rules. `recommended-type-checked` adds rules "that require type information," and `strict-type-checked` adds stricter ones but "is not considered 'stable' under Semantic Versioning" ([typescript-eslint configs](https://typescript-eslint.io/users/configs/)) |
| **eslint-plugin-react-hooks** | Rules of Hooks and `exhaustive-deps` |
| **eslint-plugin-jsx-a11y** | Accessibility checks on JSX |
| **Prettier** | Formatting, where the repository configures it |
| **`tsc --noEmit`** | Type checking |
| **node:test, Jest, Vitest** | Tests and coverage, as the repository's `npm test` runs them |
| **lizard, StrykerJS** | Complexity and mutation, run by `change_gate.py` |

Take the lint, type-check and test commands from the repository's CI workflow, and run them as **Verification** says.

---

## Sources

1. **[Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html)**: declarations, naming, modules, forbidden features
2. **[Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html)**: exports, equality, `any`, assertions, enums, namespaces
3. **[TypeScript TSConfig Reference](https://www.typescriptlang.org/tsconfig/)**: `strict`, `noUncheckedIndexedAccess`, `useUnknownInCatchVariables`
4. **[TypeScript Handbook: Narrowing](https://www.typescriptlang.org/docs/handbook/2/narrowing.html)**: discriminated unions, exhaustiveness
5. **[TypeScript 4.9 release notes](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-9.html)**: `satisfies`
6. **[MDN Web Docs](https://developer.mozilla.org/)**: [modules](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules), [`<script>`](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script), [Error.cause](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Error/cause), [fetch()](https://developer.mozilla.org/en-US/docs/Web/API/Window/fetch), [Promise.allSettled()](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise/allSettled), [toSorted()](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/toSorted), [Object.freeze()](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Object/freeze), [innerHTML](https://developer.mozilla.org/en-US/docs/Web/API/Element/innerHTML)
7. **[React documentation](https://react.dev/)**: [Rules of Hooks](https://react.dev/reference/rules/rules-of-hooks), [exhaustive-deps](https://react.dev/reference/eslint-plugin-react-hooks/lints/exhaustive-deps), [You Might Not Need an Effect](https://react.dev/learn/you-might-not-need-an-effect), [Updating Objects in State](https://react.dev/learn/updating-objects-in-state), [Rendering Lists](https://react.dev/learn/rendering-lists)
8. **[ESLint rules](https://eslint.org/docs/latest/rules/)**: [`complexity`](https://eslint.org/docs/latest/rules/complexity), [`eqeqeq`](https://eslint.org/docs/latest/rules/eqeqeq)
9. **[typescript-eslint](https://typescript-eslint.io/)**: [configs](https://typescript-eslint.io/users/configs/), [no-floating-promises](https://typescript-eslint.io/rules/no-floating-promises/)
10. **[Node.js](https://nodejs.org/api/)**: [test runner](https://nodejs.org/api/test.html), [CLI coverage flags](https://nodejs.org/api/cli.html), [assert](https://nodejs.org/api/assert.html)
11. **[Jest configuration](https://jestjs.io/docs/configuration)** and **[Vitest coverage](https://vitest.dev/config/coverage)**: coverage scope and thresholds
12. **[Testing Library](https://testing-library.com/docs/)**: [query priority](https://testing-library.com/docs/queries/about/#priority), [user-event](https://testing-library.com/docs/user-event/intro)
13. **[lizard](https://github.com/terryyin/lizard)** and **[StrykerJS](https://stryker-mutator.io/docs/stryker-js/configuration/)**: complexity and mutation measurement

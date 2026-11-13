# Python Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

## Core Philosophy

Code quality priorities, in order:

1. **Correct** — Code does what it's supposed to do
2. **Simple and Readable** — Readability counts; explicit is better than implicit
3. **Extensible** — Flat is better than nested; composable over monolithic
4. **Performant** — Optimize only when measured and necessary

Always favor the human programmer over the machine. Prefer readability and clarity of design over performance unless explicitly instructed otherwise.

**The Zen of Python** (PEP 20):
- "Explicit is better than implicit."
- "Simple is better than complex. Complex is better than complicated."
- "Flat is better than nested. Sparse is better than dense."
- "Errors should never pass silently. Unless explicitly silenced."
- "There should be one — and preferably only one — obvious way to do it."
- "If the implementation is hard to explain, it's a bad idea."

---

## Formatting

### Black / Ruff
> *Source: [PEP 8](https://peps.python.org/pep-0008/), project conventions*

Use an autoformatter (`black`, `ruff format`, or `pyink`). This is non-negotiable. Check `pyproject.toml` for project-specific settings (e.g., `line-length = 79`).

### Line Length
> *Source: [PEP 8](https://peps.python.org/pep-0008/#maximum-line-length)*

79 characters for code, 72 for docstrings and comments. Teams may agree on 99. Check `pyproject.toml` or `setup.cfg` for the project setting.

### Indentation
> *Source: [PEP 8](https://peps.python.org/pep-0008/#indentation)*

4 spaces. Never tabs. Continuation lines should align with the opening delimiter or use a hanging indent.

```python
# Good: aligned with opening delimiter
foo = long_function_name(var_one, var_two,
                         var_three, var_four)

# Good: hanging indent
foo = long_function_name(
    var_one, var_two,
    var_three, var_four,
)
```

### Blank Lines
> *Source: [PEP 8](https://peps.python.org/pep-0008/#blank-lines)*

- 2 blank lines around top-level definitions (functions, classes)
- 1 blank line between methods in a class
- Use sparingly within functions to indicate logical sections

### Trailing Commas
> *Source: [PEP 8](https://peps.python.org/pep-0008/#when-to-use-trailing-commas)*

Required for single-element tuples `(x,)`. Recommended for multi-line collections — cleaner diffs:

```python
# Good
FILES = [
    "setup.cfg",
    "tox.ini",
]

# Good — single-element tuple
x = (1,)
```

---

## Naming

> *Source: [PEP 8](https://peps.python.org/pep-0008/#naming-conventions), [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#316-naming)*

| Entity | Convention | Example |
|---|---|---|
| Modules | `short_lowercase` | `utils`, `db_client` |
| Packages | `shortlowercase` | `mypackage` |
| Classes | `CapWords` | `UserAccount`, `HttpClient` |
| Exceptions | `CapWords` + `Error` suffix | `ValidationError` |
| Functions / Methods | `snake_case` | `get_user()`, `process_batch()` |
| Variables | `snake_case` | `user_count`, `max_retries` |
| Constants | `UPPER_SNAKE_CASE` | `MAX_OVERFLOW`, `DEFAULT_TIMEOUT` |
| Type Variables | `CapWords`, short | `T`, `KT`, `VT` |
| Private | Single leading `_` | `_internal_helper()` |
| Name-mangled | Double leading `__` | `__private_attr` |

**Never** use `l`, `O`, or `I` as single-character variable names.

Method first arguments: always `self` for instance methods, `cls` for class methods.

Use brevity when naming variables for conciseness. Don't include redundant nouns that are made apparent by the arguments or context:

```python
# Good
def sort_by_distance(summaries): ...

# Bad — redundant noun
def sort_summaries_by_distance(summaries): ...
```

---

## Imports

> *Source: [PEP 8](https://peps.python.org/pep-0008/#imports), [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#313-imports-formatting)*

```python
# 1. __future__ imports (always first)
from __future__ import annotations

# 2. Standard library
import os
import sys
from collections import defaultdict
from pathlib import Path

# 3. Third-party
import boto3
import requests
from pydantic import BaseModel

# 4. Local application
from app.models import User
from app.utils import sanitize
```

**Rules:**
- One import per line (except `from X import a, b, c`)
- Absolute imports preferred over relative
- **Never** use wildcard imports (`from module import *`)
- Remove an import nothing uses; the linter flags it and it misleads a reader about the dependencies
- Separate groups with blank lines
- Use `isort` or `ruff` for automatic organization

Use `TYPE_CHECKING` for import-time-only types to avoid circular imports and reduce startup cost:

```python
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from expensive_module import HeavyType
```

---

## Function Design

### Keep Functions Small and Focused

Numbered comments inside a function — `# 1. Parse`, `# 2. Validate` — are the
symptom: each number is a function name waiting to be extracted.
> *Source: [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#24-decision)*

- Prefer short, focused functions. Reconsider anything over ~40 lines.
- Each function should do one thing.
- Extract complex expressions into named helpers even if used once — readability over DRY.

### Build Through Composition
> *Source: Core programming principles*

- Functions should build upon each other
- Prefer pipelines of simple functions over complex single functions
- Keep functions orthogonal (independently extensible)
- Organize functions in the order they are called/needed
- Make logical flow obvious from top to bottom

```python
# Good: composed pipeline
def process_orders(orders):
    validated = validate(orders)
    discounted = apply_discounts(validated)
    return summarize(discounted)

# Bad: everything in one function
def process_orders(orders):
    result = []
    for order in orders:
        if order.is_valid():
            price = order.price * (1 - order.discount)
            # ... 40 more lines
```

### Arguments
> *Source: [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#21-default-argument-values)*

- Place invariant arguments before varying arguments (enables `functools.partial`)
- Prefer keyword arguments for functions with more than 2-3 parameters
- Use `*` to force keyword-only arguments for clarity

```python
# Good: forced keyword-only after *
def connect(host: str, *, port: int = 5432, timeout: int = 30) -> Connection:
    ...

# Caller must be explicit:
connect("localhost", port=5433, timeout=60)
```

### Mutable Default Arguments (Critical Anti-Pattern)
> *Source: [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#212-default-argument-values), [Python Anti-Patterns](https://docs.quantifiedcode.com/python-anti-patterns/)*

```python
# BAD — mutable default is shared across calls
def append_to(element, target=[]):
    target.append(element)
    return target

# GOOD — use None sentinel
def append_to(element, target=None):
    if target is None:
        target = []
    target.append(element)
    return target
```

---

## Type Annotations

> *Source: [PEP 484](https://peps.python.org/pep-0484/), [PEP 604](https://peps.python.org/pep-0604/), [Typing Best Practices](https://typing.python.org/en/latest/reference/best_practices.html)*

### Modern Syntax (Python 3.10+)

```python
# Good — modern union syntax
def process(data: str | None = None) -> int | str:
    ...

# Avoid — old-style
from typing import Optional, Union
def process(data: Optional[str] = None) -> Union[int, str]:
    ...
```

### Built-in Generics (Python 3.9+)

```python
# Good — built-in generics
def get_users() -> list[User]: ...
def get_config() -> dict[str, int]: ...

# Avoid — typing module aliases
from typing import List, Dict
def get_users() -> List[User]: ...
```

### Accept Abstract, Return Concrete
> *Source: [Typing Best Practices](https://typing.python.org/en/latest/reference/best_practices.html)*

```python
# Arguments: accept abstract types (Iterable, Mapping, Sequence)
# Returns: provide concrete types (list, dict)
def process(items: Iterable[str]) -> list[int]:
    return [len(s) for s in items]
```

### Protocol for Structural Subtyping
> *Source: [PEP 544](https://peps.python.org/pep-0544/)*

```python
from typing import Protocol

class Renderable(Protocol):
    def render(self) -> str: ...

# Any class with render() -> str satisfies this — no inheritance needed
def display(item: Renderable) -> None:
    print(item.render())
```

### Use `object` over `Any`

```python
# Good — any type accepted, no type-specific operations
def log_value(o: object) -> None:
    print(str(o))

# Only when truly unconstrained
def deserialize(data: bytes) -> Any: ...
```

---

## Data Modeling

### Prefer Dataclasses Over Dicts for Structured Data
> *Source: [Python Docs - dataclasses](https://docs.python.org/3/library/dataclasses.html)*

```python
# Bad — stringly-typed, no validation, no IDE support
user = {"name": "Alice", "age": 30, "active": True}

# Good — typed, self-documenting
@dataclass(frozen=True)
class User:
    name: str
    age: int
    active: bool = True
```

### Use Enums Instead of String Constants
> *Source: [Python Docs - enum](https://docs.python.org/3/library/enum.html)*

```python
# Bad — easy to misspell, no IDE completion
status = "actve"  # typo not caught

# Good — type-safe, IDE-friendly
class Status(Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"
    PENDING = "pending"
```

### Immutable Data by Default

```python
# Prefer tuples for fixed collections
DIRECTIONS = ("north", "south", "east", "west")

# Frozen dataclasses for value objects
@dataclass(frozen=True)
class Coordinate:
    lat: float
    lon: float

# Frozenset for immutable sets
VALID_STATUSES = frozenset({"active", "inactive", "pending"})
```

---

## Pydantic

### Establish the major version first

v1 and v2 differ in API names *and* in behaviour, and both are in active use. Read the pin (`requirements*.txt`, `pyproject.toml`, `poetry.lock`) before applying anything below; never assume v2 because it is newer.

| Concern | v1 | v2 |
|---|---|---|
| Build from a dict | `Model(**d)`, `Model.parse_obj(d)` | `Model.model_validate(d)` |
| Dump | `.dict()`, `.json()` | `.model_dump()`, `.model_dump_json()` |
| Copy with changes | `.copy(update=…)` | `.model_copy(update=…)` |
| Config | `class Config:` | `model_config = ConfigDict(…)` |
| Undeclared input keys | dropped silently (`Extra.ignore`) | dropped silently (`extra="ignore"`) |

### A declared type is a weaker guarantee than it looks

Both majors coerce rather than reject, so "the field is typed" does not mean bad values were refused — it means they were *converted*. On a `float` field (verified, pydantic 1.10.13):

```python
M(rate="20").rate           # 20.0  — a numeric string is coerced, not rejected
M(rate=Decimal("25")).rate  # 25.0  — a Decimal becomes a float
M(rate=["x"])               # ValidationError: type_error.float
```

Never write — in a comment, a docstring, or a test name — that a type declaration rejects a class of input without running it. A false guarantee is worse than no guarantee: it is why the next reader stops checking.

### Three places validation does not run

1. **Defaults are not validated** (`validate_all` in v1, `validate_default` in v2 — both off). An `int` literal default on a `float` field stays an `int`, so the unconfigured path can carry a different runtime type from the configured one, and different arithmetic behaviour with it.
2. **Mutation is not validated** (`validate_assignment` off by default) — see below.
3. **Values nested inside an untyped container are not coerced.** A `dict`/`list` field is validated as a container; its contents are left exactly as they arrived.

### The coercion boundary is where mixed numeric types bite

A client that returns `Decimal` for every number — `boto3.resource("dynamodb")` is the common one — meets pydantic unevenly. A **declared** `float` field is coerced to a real `float`; the same number nested inside an untyped `dict` field stays a `Decimal`. `Decimal` interoperates with `int` and raises `TypeError` against `float`, so two halves of one record can be arithmetic-incompatible:

```python
location.rate                       # declared float   -> 25.0
booking.metadata["amounts"]["x"]    # nested in a dict -> Decimal('2000')
location.rate * booking.metadata["amounts"]["x"]   # TypeError
```

Cast explicitly at the boundary (`int(...)`, `float(...)`) rather than trusting the declaration. Declaring a previously-undeclared field *changes* its runtime type, which makes it a migration, not just documentation.

### Undeclared attributes vanish without a word

Both majors default to ignoring extra input keys, so an attribute present in storage but absent from the model is dropped at load with no error and no log line. Code that then looks for it in a catch-all `metadata` dict finds nothing and silently takes its default. Declare every field you intend to read, and set `extra="forbid"` (v2) / `Extra.forbid` (v1) where an unexpected key should be loud.

### `model_copy(update=...)` and `setattr` both skip validation

Neither major re-validates when you mutate an existing instance — `setattr(obj, "field", value)`, v1 `obj.copy(update=…)` and v2 `obj.model_copy(update=…)` all skip field validators. Wrong-typed data is silently accepted and only blows up later, typically at read-back time when another consumer tries to deserialise the persisted row. In a test it is worse than a silent bug: it plants a state the real loader could never produce, so the test passes for a reason unrelated to what it claims to cover.

```python
# BAD — setattr skips validation
for key, value in patch_body.items():
    setattr(model, key, value)  # accepts anything, including wrong types

# ALSO BAD — model_copy(update=...) skips validation
model = model.model_copy(update=patch_body)  # same problem

# GOOD — model_validate on a merged dict re-runs full validation
try:
    model = type(model).model_validate({**model.model_dump(), **patch_body})
except ValidationError as exc:
    raise BadRequestError(str(exc)) from exc
```

Three paths that *do* run validation on an existing instance:

1. v2 `Model.model_validate(merged_dict)` / v1 `Model.parse_obj(merged_dict)` — build a new validated instance from the merged dict. Cleanest for PATCH handlers.
2. `Model(**merged_dict)` — same effect in both majors; constructs a fresh instance.
3. Opt in per-model with `validate_assignment=True` (v2 `model_config = ConfigDict(...)`, v1 `class Config:`) — then assignment and copy-with-update both validate. Pick this when there are many mutation sites; otherwise prefer (1).

**Why this matters:** a PATCH endpoint that accepts `{"config": "not-a-dict"}` against a `config: dict` field will happily persist a string, and the next reader meets a confusing `ValidationError` far from the original insertion point. The path-of-least-resistance "`setattr` in a loop" pattern is the single most common source of silent schema corruption in pydantic code, in either major.

### Other behaviours worth knowing

- **Copies are shallow by default** (v1 `.copy()`, v2 `.model_copy()`) — nested mutable fields share references with the original. Pass `deep=True` when the copy must be independent.
- **JSON-mode dumps**: v2 `model.model_dump(mode="json")` — required when feeding output directly to `json.dumps()` or an HTTP response, since the default mode keeps Python-native types like `datetime` and `Decimal`. v1's equivalent is `json.loads(model.json())`.

---

## Error Handling

> *Source: [PEP 8](https://peps.python.org/pep-0008/#programming-recommendations), [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#24-exceptions)*

The sections below are the Python mechanics — which exception types to catch, how small a `try` block should be, how to build a custom hierarchy. What an error must *be* is governed by `coding_guidelines.md` → **Failure**, the single source for those rules.

### Catch Specific Exceptions

```python
# Bad — hides bugs
try:
    result = process(data)
except Exception:
    return default_value

# Good — explicit about what can fail
try:
    result = process(data)
except ValidationError as e:
    logger.warning("Invalid data: %s", e)
    return default_value
except ConnectionError as e:
    logger.error("Connection failed: %s", e)
    raise
```

### Keep try Blocks Small

```python
# Bad — too much in try block
try:
    data = load_file(path)
    parsed = parse(data)
    result = transform(parsed)
    save(result)
except FileNotFoundError:
    ...

# Good — isolate the risky operation
try:
    data = load_file(path)
except FileNotFoundError:
    logger.error("File not found: %s", path)
    raise

parsed = parse(data)
result = transform(parsed)
save(result)
```

### Never Use Bare `except:`

```python
# Bad — catches SystemExit, KeyboardInterrupt
try:
    risky()
except:
    pass

# Good
try:
    risky()
except SpecificError as e:
    logger.error("Failed: %s", e)
```

### Don't Use Exceptions for Flow Control

```python
# Bad — exception for normal flow
try:
    value = my_dict[key]
except KeyError:
    value = default

# Good — LBYL or built-in
value = my_dict.get(key, default)
```

### Custom Exception Hierarchies

```python
class AppError(Exception):
    """Base exception for this application."""

class ValidationError(AppError):
    """Raised when input validation fails."""

class NotFoundError(AppError):
    """Raised when a requested resource does not exist."""
```

### Use `try/except/else/finally` Correctly

```python
try:
    f = open(path)
except OSError as e:
    logger.error("Cannot open: %s", e)
else:
    # Only runs if no exception
    data = f.read()
finally:
    # Always runs — cleanup
    f.close()
```

---

## Context Managers

> *Source: [PEP 343](https://peps.python.org/pep-0343/), [PEP 8](https://peps.python.org/pep-0008/#programming-recommendations)*

Always use context managers for resource management:

```python
# Bad
f = open("data.txt")
data = f.read()
f.close()  # Skipped on exception

# Good
with open("data.txt") as f:
    data = f.read()
```

Write custom context managers for your own resources:

```python
from contextlib import contextmanager

@contextmanager
def managed_connection(url):
    conn = create_connection(url)
    try:
        yield conn
    finally:
        conn.close()
```

---

## Comprehensions and Generators

> *Source: [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#274-decision)*

### Prefer Comprehensions for Simple Transforms

```python
# Good — clear, single expression
names = [user.name for user in users if user.active]

# Bad — imperative equivalent
names = []
for user in users:
    if user.active:
        names.append(user.name)
```

### Use Generators for Large Data

```python
# Bad — materializes entire list just to sum
total = sum([x * x for x in range(1_000_000)])

# Good — generator, constant memory
total = sum(x * x for x in range(1_000_000))
```

### Don't Over-Nest Comprehensions

```python
# Bad — hard to read
result = [transform(x) for xs in matrix for x in xs if predicate(x)]

# Good — extract or use itertools
from itertools import chain
flat = chain.from_iterable(matrix)
result = [transform(x) for x in flat if predicate(x)]
```

---

## Composability and Functional Patterns

> *Source: [Python Functional Programming HOWTO](https://docs.python.org/3/howto/functional.html), [functools docs](https://docs.python.org/3/library/functools.html)*

### Pure Functions

```python
# Bad — side effect, modifies external state
total = 0
def add_to_total(x):
    global total
    total += x

# Good — pure, no side effects
def add(a: int, b: int) -> int:
    return a + b
```

### Partial Application

```python
from functools import partial

def power(base: int, exponent: int) -> int:
    return base ** exponent

square = partial(power, exponent=2)
cube = partial(power, exponent=3)
```

### Composable Pipelines with Generators

```python
def read_lines(path):
    with open(path) as f:
        yield from f

def strip_lines(lines):
    for line in lines:
        yield line.strip()

def non_empty(lines):
    for line in lines:
        if line:
            yield line

# Compose — lazy, memory-efficient
records = parse_csv(non_empty(strip_lines(read_lines("data.csv"))))
```

### Key `itertools` Patterns

```python
from itertools import chain, groupby, islice

# Flatten nested iterables
flat = list(chain.from_iterable([[1, 2], [3, 4]]))

# Take first N from large iterable
first_100 = list(islice(huge_generator(), 100))
```

### Decorators — Preserve Signatures

```python
from functools import wraps

def retry(max_attempts: int = 3):
    def decorator(func):
        @wraps(func)  # preserves __name__, __doc__, signature
        def wrapper(*args, **kwargs):
            for attempt in range(max_attempts):
                try:
                    return func(*args, **kwargs)
                except Exception:
                    if attempt == max_attempts - 1:
                        raise
        return wrapper
    return decorator
```

---

## Testing

> *Source: [pytest docs](https://docs.pytest.org/en/stable/), [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#316-naming)*

### Arrange-Act-Assert

```python
def test_user_creation():
    # Arrange
    data = {"name": "Alice", "email": "alice@example.com"}

    # Act
    user = create_user(**data)

    # Assert
    assert user.name == "Alice"
    assert user.email == "alice@example.com"
```

### Fixtures with Appropriate Scope

```python
@pytest.fixture
def sample_user():
    """Function-scoped — fresh per test."""
    return User(name="Test", email="test@test.com")

@pytest.fixture(scope="module")
def db_connection():
    """Module-scoped — shared, torn down after."""
    conn = create_connection()
    yield conn
    conn.close()
```

### Parametrize for Multiple Cases

```python
@pytest.mark.parametrize("input_val,expected", [
    ("hello", 5),
    ("", 0),
    ("  spaces  ", 10),
])
def test_string_length(input_val, expected):
    assert len(input_val) == expected
```

### Mock the Consumer, Not the Source

```python
# service.py imports external_lib.api_client
# Patch where it's USED, not where it's defined:
with patch("service.api_client.fetch", return_value={"key": "val"}):
    result = get_data()
```

### No Interdependence

Each test passes when run alone and in any order. A test that depends on another
having run first fails only under `-p no:randomly` or a changed file order, which
is the hardest kind of failure to attribute.

### Naming Convention

- Files: `test_<module>.py` or `<module>_test.py`
- Functions: `test_<what>_<condition>_<expected>` or `test_<behavior>`
- One assertion focus per test (multiple asserts on the same object is fine)
- Test fixtures should be explicit — clarity over DRY in tests

---

## Modern Python Idioms (3.10+)

### Structural Pattern Matching (3.10+)
> *Source: [PEP 634](https://peps.python.org/pep-0634/)*

```python
match command:
    case {"action": "move", "direction": str(d)}:
        move(d)
    case {"action": "quit"}:
        quit_game()
    case _:
        unknown_command(command)
```

### Walrus Operator `:=` (3.8+)
> *Source: [PEP 572](https://peps.python.org/pep-0572/)*

```python
# Avoid computing twice
if (n := len(data)) > 10:
    print(f"Processing {n} items")

# In while loops
while chunk := f.read(8192):
    process(chunk)
```

### Union Type Syntax (3.10+)
> *Source: [PEP 604](https://peps.python.org/pep-0604/)*

```python
# New
def handle(value: int | str) -> None: ...

# Old — avoid when targeting 3.10+
from typing import Union
def handle(value: Union[int, str]) -> None: ...
```

### f-strings (3.6+)

```python
# Good
message = f"Hello {name}, you have {count} items"

# Avoid — old-style formatting
message = "Hello %s, you have %d items" % (name, count)
message = "Hello {}, you have {} items".format(name, count)
```

---

## Truthiness

> *Source: [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#2114-truefalse-evaluations)*

```python
# Good — Pythonic truthiness
if users:           # non-empty check
if not config:      # empty check
if x is None:       # identity check for None
if x is not None:   # identity check for not-None

# Bad — verbose, un-Pythonic
if len(users) > 0:
if config == {}:
if x == None:       # use 'is', not '=='
if x == False:      # use 'not x'
```

---

## Performance

> *Source: [Python Performance Tips](https://wiki.python.org/moin/PythonSpeed/PerformanceTips)*

### Profile Before Optimizing

```bash
python -m cProfile -s cumulative my_script.py
```

### Use Built-in Functions (C-level Speed)

```python
# Bad
total = 0
for x in numbers:
    total += x

# Good
total = sum(numbers)

# Same: min, max, any, all, sorted, map, filter
```

### Choose the Right Data Structure

```python
# Membership testing — O(1) vs O(n)
if item in large_list:   # O(n) — bad for large data
if item in large_set:    # O(1) — use sets for membership
```

### Caching

```python
from functools import lru_cache

@lru_cache(maxsize=128)
def expensive_computation(n: int) -> int:
    ...
```

### `__slots__` for Memory-Heavy Classes

```python
class Point:
    __slots__ = ("x", "y")
    def __init__(self, x: float, y: float) -> None:
        self.x = x
        self.y = y
# ~40% less memory per instance
```

### Local Variables are Faster Than Globals

In tight loops, bind globals to local names:

```python
def process(data):
    local_len = len
    return [local_len(item) for item in data]
```

### Concurrency Model

- **I/O-bound** (HTTP, file, DB): `asyncio` or `threading`
- **CPU-bound** (computation): `multiprocessing` or `ProcessPoolExecutor`
- The GIL means threads do NOT help with CPU-bound work

---

## Security

> *Source: [Bandit](https://bandit.readthedocs.io/), [OWASP](https://owasp.org/), [defusedxml](https://github.com/tiran/defusedxml)*

### XML Parsing — Always Use defusedxml

`xml.etree.ElementTree.fromstring()` is vulnerable to XML entity attacks (XXE, billion laughs). **Never** use it on untrusted input.

```python
# BAD — vulnerable to XML attacks
from xml.etree import ElementTree as ET
root = ET.fromstring(response.text)

# GOOD — safe parsing
from defusedxml.ElementTree import fromstring as safe_fromstring
from xml.etree.ElementTree import Element  # types only — safe
root = safe_fromstring(response.text)
```

Note: `defusedxml` doesn't export `Element` type — import types from `xml.etree.ElementTree` directly.

### Hashlib — Mark Non-Security Uses

Python 3.9+ requires explicit `usedforsecurity` for SHA1/MD5 on FIPS-compliant systems. Bandit flags all SHA1 usage.

```python
# BAD — bandit flags as insecure
digest = hashlib.sha1(data).digest()

# GOOD — explicit about intent
digest = hashlib.sha1(data, usedforsecurity=False).digest()  # noqa: S324

# For HMAC — use string digestmod to avoid bandit flagging hashlib.sha1
hmac.new(key, msg, "sha1").digest()  # instead of hashlib.sha1
```

### Magic String Literals — Extract Constants

Repeated string literals (3+ occurrences) should be extracted to named constants. This prevents typos and makes the intent clear.

```python
# BAD — "Basic " repeated 3 times
if not header.startswith("Basic "):
    ...
creds = header[len("Basic "):]

# GOOD — named constant
BASIC_AUTH_PREFIX = "Basic "
if not header.startswith(BASIC_AUTH_PREFIX):
    ...
creds = header[len(BASIC_AUTH_PREFIX):]
```

### Cognitive Complexity — Keep Functions Under 15

Static analysis tools (radarlint, SonarQube) flag cognitive complexity > 15. Deeply nested loops with conditionals are the primary cause.

```python
# BAD — cognitive complexity ~25 (nested loops + conditionals)
def collect_namespaces(tree, nsmap):
    result = {}
    for el in tree.iter():
        if el.tag and isinstance(el.tag, str) and el.tag.startswith("{"):
            uri = el.tag.split("}")[0][1:]
            for pfx, ns_uri in nsmap.items():
                if ns_uri == uri and pfx:
                    result[pfx] = uri
    return result

# GOOD — extract helpers to flatten nesting
def _extract_uri(name: str) -> str:
    return name.split("}")[0][1:]

def collect_namespaces(tree, nsmap):
    uri_to_prefix = {uri: pfx for pfx, uri in nsmap.items() if pfx}
    result = {}
    for el in tree.iter():
        uris = [_extract_uri(el.tag)] if _is_qualified(el.tag) else []
        uris.extend(_extract_uri(a) for a in el.attrib if a.startswith("{"))
        for uri in uris:
            if pfx := uri_to_prefix.get(uri):
                result[pfx] = uri
    return result
```

### Unused Function Parameters

Remove unused parameters from function signatures. If a parameter exists in the signature but is never referenced in the body, it misleads callers and fails static analysis.

```python
# BAD — default parameter never used
def parse_bool(parent, tag, default=False):
    return get_text(parent, tag).lower() == "true"

# GOOD — remove unused parameter
def parse_bool(parent, tag):
    return get_text(parent, tag).lower() == "true"
```

### YAML Quoting

A simple scalar is left unquoted. Redundant quotes around a plain string are what
the static analysers flag, and they hide the one case where quoting is load-bearing.

### SAM/CloudFormation Lambda Security

When defining AWS Lambda functions in `template.yaml`:
- **VpcConfig**: Add when function accesses private resources or for network isolation
- **DeadLetterQueue**: Add SQS DLQ for async invocations to capture failures
- **ReservedConcurrentExecutions**: Set to prevent runaway scaling
- **KmsKeyArn**: Add for environment variable encryption at rest (if org has KMS keys)
- **YAML quoting**: Don't quote simple string values that don't contain special YAML characters

```yaml
# BAD
POWERTOOLS_SERVICE_NAME: "MyService"

# GOOD
POWERTOOLS_SERVICE_NAME: MyService
```

---

## Anti-Patterns

> *Source: [Python Anti-Patterns](https://docs.quantifiedcode.com/python-anti-patterns/), [DeepSource](https://deepsource.com/blog/8-new-python-antipatterns)*

### Mutable Default Arguments
See [Function Design](#function-design).

### Ignoring the Standard Library

```python
# Bad — reimplementing what exists
from itertools import chain
flat = list(chain.from_iterable(nested))  # don't hand-roll this
```

### Bare `except:` Clauses
See [Error Handling](#error-handling).

### Checking Types Instead of Using Duck Typing

```python
# Bad
if isinstance(obj, list):
    for item in obj:
        ...

# Good — use Iterable annotation + duck typing
def process(items: Iterable[str]) -> None:
    for item in items:
        ...
```

### Using `dict()` Instead of `{}`

```python
# Slower — function call + global lookup
d = dict()

# Faster — literal syntax
d = {}
```

### God Classes / God Functions

- Classes with 10+ methods doing unrelated things → split by responsibility
- Functions over 40 lines → extract helpers
- Modules over 500 lines → split by domain

### Late Binding Closures

```python
# Bad — all functions return 4 (last value of i)
funcs = [lambda: i for i in range(5)]

# Good — capture current value
funcs = [lambda i=i: i for i in range(5)]
```

---

## Docstrings

> *Source: [PEP 257](https://peps.python.org/pep-0257/), [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#38-comments-and-docstrings)*

Use Google-style docstrings:

```python
def fetch_data(url: str, timeout: int = 30) -> dict[str, Any]:
    """Fetch JSON data from a remote endpoint.

    Retrieves data with exponential backoff retry logic.

    Args:
        url: Complete URL endpoint to query.
        timeout: Maximum seconds to wait for response.

    Returns:
        Parsed JSON response as dictionary.

    Raises:
        requests.Timeout: If response exceeds timeout.
        ValueError: If URL is malformed.
    """
```

- Always use triple double-quotes `"""`
- Summary line under 80 characters, terminated by period
- Blank line between summary and body
- Sections: `Args`, `Returns` (or `Yields`), `Raises`

Docstring format above is the Python-specific mechanics. What a comment or docstring may say is governed by `coding_guidelines.md` → **Comments**, the single source for those rules.

---

## Complexity and mutation

> *Source: [Verification](coding_guidelines.md#verification), [lizard](https://github.com/terryyin/lizard), [Ruff — C901](https://docs.astral.sh/ruff/rules/complex-structure/)*

`~/.claude/scripts/change_gate.py` holds a change to both bars.

- **No function above cyclomatic complexity 10.** The gate counts with lizard.
  Ruff's `C901` counts the same paths in the editor, at its default
  `max-complexity` of 10. The cognitive-complexity bar above is a separate
  measure, and both hold.
- **Every mutant on a changed line is killed.** The gate's mutator swaps
  `<`/`<=`/`>`/`>=`, `==`/`!=`, `and`/`or`, `True`/`False`, `+ 1`/`- 1`, and
  drops `not` and the `not` of `is not`, in the code of each changed line. A
  string, a docstring and a comment are never mutated. The repo's test
  command runs once with per-test coverage, so the suite needs `pytest-cov`;
  each mutant then runs only the tests whose coverage ran its line, or every
  test for a line run only at import. The command is the one CI runs, test
  paths included, given as
  `--test 'python=.venv/bin/python -m pytest tests'`; with none it is
  `<repo>/.venv/bin/python -m pytest`. When CI's own run already recorded
  per-test coverage (`--cov-context=test`), `--coverage <file>` hands that
  file over, and the gate reruns only the tests covering the changed lines
  instead of the whole suite.
- **A script that offers `--self-test` is tested by it.** Its `self_test`
  functions are test code and are not mutated, so the self-test's helpers
  belong inside them.
- **An equivalent mutant is marked on its line:**
  `# mutation: equivalent — <reason>`.

---

## Tooling

| Tool | Purpose |
|---|---|
| **ruff** | Linting + formatting (replaces flake8, isort, black, pyflakes) |
| **black** | Auto-formatting |
| **mypy** / **pyright** | Static type checking |
| **pytest** | Testing framework |
| **bandit** | Security linting |
| **pre-commit** | Git hooks for automated checks |

When working in a project, check for existing tool configuration in `pyproject.toml`, `setup.cfg`, or dedicated config files before adding new tools.

---

## LLM Interaction Guidelines

### Imperative Smell Checklist (check every function)

These are patterns that LLMs produce reflexively. Flag ALL occurrences:

**Unnecessary class wrapping**
```python
# Bad — class exists only to hold one method
class DataProcessor:
    def process(self, data):
        return [transform(x) for x in data]

# Good — just a function
def process_data(data):
    return [transform(x) for x in data]
```

**Verbose error handling that swallows context**
```python
# Bad — catches everything, logs generic message
try:
    result = complex_operation()
except Exception as e:
    print(f"An error occurred: {e}")
    return None

# Good — specific exception, preserves context
try:
    result = complex_operation()
except ConnectionError as e:
    logger.error("Failed to connect: %s", e)
    raise
```

**Premature abstraction**
```python
# Bad — factory/strategy/builder for something used once
class UserValidatorFactory:
    @staticmethod
    def create(validation_type):
        if validation_type == "email":
            return EmailValidator()
        ...

# Good — just validate inline
if not is_valid_email(user.email):
    raise ValidationError("Invalid email")
```

**Near-duplicate functions (>70% similar)**
If two functions share >70% of their structure and differ only in a small detail, factor out the common logic and parameterize.

**Tests that an abstraction is not worth it**
- The abstracted code is longer than the duplication it replaces.
- An abstract base class has one implementation.
- Behaviour hides in `__init__`, `__getattr__`, a descriptor or a metaclass, so a
  reader must open the source to learn what a call does.
- State reaches a function through a module global instead of an argument. Pass it
  in: a global is an argument every caller shares and none can see.

---

## Sources

- [PEP 8 — Style Guide for Python Code](https://peps.python.org/pep-0008/)
- [PEP 20 — The Zen of Python](https://peps.python.org/pep-0020/)
- [PEP 257 — Docstring Conventions](https://peps.python.org/pep-0257/)
- [PEP 484 — Type Hints](https://peps.python.org/pep-0484/)
- [PEP 544 — Protocols: Structural Subtyping](https://peps.python.org/pep-0544/)
- [PEP 572 — Assignment Expressions](https://peps.python.org/pep-0572/)
- [PEP 604 — Union Type Syntax](https://peps.python.org/pep-0604/)
- [PEP 612 — Parameter Specification Variables](https://peps.python.org/pep-0612/)
- [PEP 634 — Structural Pattern Matching](https://peps.python.org/pep-0634/)
- [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html)
- [Python Anti-Patterns](https://docs.quantifiedcode.com/python-anti-patterns/)
- [Python Functional Programming HOWTO](https://docs.python.org/3/howto/functional.html)
- [Typing Best Practices](https://typing.python.org/en/latest/reference/best_practices.html)

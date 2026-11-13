# Haskell Coding Guidelines

## Core Philosophy

Code quality priorities, in order:

1. **Correct** — Types should make invalid states unrepresentable
2. **Simple and Readable** — Favor clarity over cleverness
3. **Extensible** — Types and functions should compose naturally
4. **Performant** — Optimize only when measured and necessary

Always favor the human programmer over the machine. Prefer readability and clarity of design over performance unless explicitly instructed otherwise.

---

## Function Design

### Keep Functions Small and Focused

- Aim for 1-5 lines per function (guideline, not a hard rule)
- Prefer typeclasses and idioms over imperative case statement chains
- Each function should do exactly one thing
- Prefer single-argument functions that compose via `.` and `$`
- Extract complex expressions into named bindings

```haskell
-- Good: small, composable
activeUsers :: [User] -> [User]
activeUsers = filter isActive

sortedByName :: [User] -> [User]
sortedByName = sortOn userName

-- Use: activeUsers . sortedByName
```

### Build Through Composition

- Functions should build upon each other
- Prefer pipelines of simple functions over complex single functions
- Use `.` for composition, `$` to reduce parentheses
- Point-free style is acceptable when it *improves* readability—abandon it when it obscures

```haskell
-- Good: clear pipeline
processOrders :: [Order] -> Summary
processOrders = summarize . applyDiscounts . validate

-- Bad: point-free obscuring logic
processOrders = (. filter valid) . flip foldr mempty . (. discount) . (<>)
```

---

## Type-Driven Development

### Let Types Guide Implementation

- Write the type signature first
- Use types to encode invariants and domain logic
- Prefer `newtype` wrappers for domain concepts over raw primitives
- Use sum types to model alternatives explicitly

```haskell
newtype UserId = UserId Int
newtype Email = Email Text

data PaymentStatus 
  = Pending 
  | Completed TransactionId 
  | Failed FailureReason
```

### Totality

- Avoid partial functions (`head`, `tail`, `!!`, `fromJust`)
- Use `Maybe`, `Either`, or `NonEmpty` to handle absence/failure in types
- Pattern match exhaustively—enable `-Wincomplete-patterns`

```haskell
-- Bad
firstUser :: [User] -> User
firstUser users = head users

-- Good
firstUser :: [User] -> Maybe User
firstUser = listToMaybe
```

### Smart Constructors and Export Discipline

- When a type requires validation, hide the data constructor
- Export the type name, smart constructor, and accessor—not `Foo(..)`
- This prevents bypassing validation

```haskell
-- Bad: anyone can bypass validation
module Url (Url(..)) where
newtype Url = Url Text

-- Good: construction only through mkUrl
module Url (Url, mkUrl, unUrl) where
newtype Url = Url Text

mkUrl :: Text -> Maybe Url
unUrl :: Url -> Text
```

### Opaque Handles

- Resource handles (connections, processes, sessions) should be opaque
- Callers receive handles from create/launch, pass to operations, never inspect

```haskell
-- Good: callers can't construct or inspect
module Browser (BrowserHandle, launch, shutdown, navigate) where

data BrowserHandle = BrowserHandle
  { bhProcess :: ProcessHandle
  , bhConn    :: Connection
  }  -- constructor not exported
```

### Constrained Values with Validation

- Don't rely on numeric types alone for domain constraints
- Wrap in a newtype with a smart constructor that validates
- Internal representation can be whatever libraries expect

```haskell
-- Bad: relies on type range, no domain meaning
data Config = Config { port :: Word16 }

-- Good: domain type with validation
newtype Port = Port Int  -- Int for library compat

mkPort :: Int -> Maybe Port
mkPort n
  | n >= 0 && n <= 65535 = Just (Port n)
  | otherwise = Nothing
```

### Typeclass Derivation

- Only derive typeclasses if all operations make semantic sense
- `Num` implies multiplication, negation—does that apply?
- Provide only the operations that are meaningful

```haskell
-- Bad: what does Depth * Depth mean?
newtype Depth = Depth Int deriving (Num)

-- Good: explicit operations only
newtype Depth = Depth Natural deriving (Eq, Ord)

succDepth :: Depth -> Depth
succDepth (Depth n) = Depth (n + 1)
```

### Preserve Source for Compiled Values

- When wrapping compiled representations (regex, template, AST), store original source
- Enables `Show`, `Eq`, and debugging

```haskell
-- Bad: can't show or compare
newtype UrlPattern = UrlPattern Regex

-- Good: source preserved
data UrlPattern = UrlPattern
  { patternSource :: Text   -- for Show/Eq/debugging
  , patternRegex  :: Regex  -- compiled, opaque
  }
```

### Record Field Naming and JSON Serialization

Use unprefixed field names with GHC 9.2+ record extensions. This eliminates the need for manual JSON instances in most cases.

**Required extensions** (enabled per-module or in cabal):
- `NoFieldSelectors` — prevents field names from becoming top-level functions
- `DuplicateRecordFields` — allows `id` in multiple types
- `OverloadedRecordDot` — enables `record.field` syntax

```haskell
{-# LANGUAGE NoFieldSelectors #-}

-- Good: unprefixed fields with ViaUnprefixed for automatic JSON
data Campaign = Campaign
  { id          :: CampaignId
  , name        :: Text
  , status      :: CampaignStatus
  , createdAt   :: UTCTime
  } deriving (Eq, Show, Generic)
    deriving (ToJSON, FromJSON) via ViaUnprefixed Campaign

-- Access via OverloadedRecordDot:
campaign.name
campaign.status
```

**Reserved words** use trailing underscore (stripped in JSON by `ViaUnprefixed`):
```haskell
data Event = Event
  { id    :: EventId
  , type_ :: EventType  -- serializes to "type" in JSON
  }
```

**Manual instances** still needed when:
- A field has special default handling (e.g., `mediaUrls` defaults to `[]`)
- A field should be omitted for security (e.g., `creds` in `ChannelAccount`)

```haskell
-- Keep manual instances for special cases
instance ToJSON Post where
  toJSON p = object
    [ "id"        .= p.id
    , "mediaUrls" .= p.mediaUrls  -- special handling for empty default
    , ...
    ]
```

---

## Type Signatures and Documentation

### Always Provide Top-Level Signatures

- Every exported function must have an explicit type signature
- Type signatures *are* documentation—make them readable
- Use type aliases for complex signatures when it aids comprehension

```haskell
-- Type alias for clarity
type Handler m = Request -> m Response

-- Signature documents intent
authenticate :: MonadIO m => Credentials -> Handler m
```

### Comments

Haddock documents exported functions — purpose, not implementation. What any comment may say is governed by `coding_guidelines.md` → **Comments**, the single source for those rules.

---

## Naming Conventions

### Be Precise and Concise

- Function names should describe the transformation
- Don't include type names redundant with the signature
- Use conventional suffixes: `M` (monadic), `'` (strict), `_` (discards result)

```haskell
-- Bad: redundant "User" 
getUserById :: UserId -> IO (Maybe User)

-- Good: context clear from types
getById :: UserId -> IO (Maybe User)
```

### Module Organization

- Group related types and functions
- Export list should read as a minimal public API
- Internal helpers go in `.Internal` modules if exposed at all
- Order: types, then constructors/smart constructors, then functions

---

## Algebraic Data Types and Pattern Matching

### Model Your Domain Precisely

- Use ADTs to make illegal states unrepresentable
- Prefer sum types over boolean flags
- Record syntax for products with multiple fields

```haskell
-- Bad: boolean blindness
sendEmail :: User -> Bool -> Bool -> IO ()

-- Good: explicit intent
data EmailOptions = EmailOptions
  { includeCc :: Bool
  , includeAttachments :: Bool
  }
sendEmail :: User -> EmailOptions -> IO ()
```

### Pattern Match Directly

- Match on constructors directly, avoid intermediate predicates when possible
- Use `case` for clarity when matching in the middle of a function
- Guards for boolean conditions, patterns for structural decomposition

### Strictness Policy for Data Records

Bare-typed record fields default to lazy. Lazy fields are the dominant
space-leak vector in long-running Haskell services, and Stan reports
several hundred instances per dhat.news package — meaning the default
is silently wrong for most domain records.

**Default policy**: enable `{-# LANGUAGE StrictData #-}` per module for
any data type that lives inside a long-running data structure:

- DB row records and decoded query results
- JSON/wire-decoded payloads kept in memory (caches, queues, accumulators)
- Worker state, in-memory tables, configuration that's read once and held

```haskell
{-# LANGUAGE StrictData #-}
module Foo where

data User = User
  { id    :: UserId  -- strict by StrictData; equivalent to !UserId
  , name  :: Text
  , email :: Email
  }
```

**Opt out explicitly with `~` only when laziness is load-bearing**:

- Pure streaming consumers walking infinite/large structures lazily
- Lazy decision trees (computed only when forced)
- Memo tables where the whole point is on-demand evaluation

```haskell
{-# LANGUAGE StrictData #-}

data Tree a = Tree
  { value    :: a       -- strict
  , children :: ~[Tree a]  -- lazy: traversal may not visit children
  }
```

**Field-level bangs (`!Foo`) instead** when only some fields in a record
should be strict — usually because the module has mixed-use types.

**Anti-pattern**: bang-everywhere as a reflex. Strictness is a per-type
decision; reach for `StrictData` at module top once, not field by field.

---

## Algebraic Effects with Effectful

### Prefer Effectful Over Monad Transformers

- Use `effectful` as the default effect system
- Effects are explicit in the type signature via effect rows
- Easier to compose, test, and reason about than transformer stacks
- Fall back to transformers only for library interop when necessary

```haskell
import Effectful
import Effectful.Reader.Static
import Effectful.Error.Static

-- Effects are listed in the constraint
runQuery 
  :: (Reader Config :> es, Error QueryError :> es, IOE :> es) 
  => Query 
  -> Eff es Results

-- Application entry point runs the effects
main :: IO ()
main = do
  config <- loadConfig
  result <- runEff 
    . runError @QueryError
    . runReader config 
    $ app
  case result of
    Left err -> handleError err
    Right _  -> pure ()
```

### Defining Custom Effects

- Define domain-specific effects for your core operations
- Keep effect definitions minimal and focused
- Provide interpreters for production and testing

```haskell
-- Define the effect
data UserStore :: Effect where
  GetUser :: UserId -> UserStore m (Maybe User)
  SaveUser :: User -> UserStore m ()

type instance DispatchOf UserStore = Dynamic

makeEffect ''UserStore

-- Production interpreter
runUserStoreIO 
  :: IOE :> es 
  => Connection 
  -> Eff (UserStore : es) a 
  -> Eff es a
runUserStoreIO conn = interpret $ \_ -> \case
  GetUser uid -> liftIO $ queryUser conn uid
  SaveUser u  -> liftIO $ insertUser conn u

-- Test interpreter  
runUserStorePure 
  :: State (Map UserId User) :> es 
  => Eff (UserStore : es) a 
  -> Eff es a
runUserStorePure = interpret $ \_ -> \case
  GetUser uid -> gets (Map.lookup uid)
  SaveUser u  -> modify (Map.insert (userId u) u)
```

### Effect Best Practices

- Use static effects (`Reader`, `State`) when you don't need dynamic dispatch
- Use dynamic effects for operations you want to mock or swap implementations
- Keep `IOE` at the edge—push it as far out as possible
- Group related operations into a single effect, but don't overload

```haskell
-- Good: focused effect
data EmailSender :: Effect where
  SendEmail :: Email -> EmailSender m ()

-- Bad: kitchen sink effect
data AppOperations :: Effect where
  SendEmail :: Email -> AppOperations m ()
  LogMessage :: Text -> AppOperations m ()
  GetConfig :: AppOperations m Config
  SaveUser :: User -> AppOperations m ()
```

### When to Use Plain IO

- Small scripts or one-off tooling
- Performance-critical inner loops where effect overhead matters
- When interfacing with libraries that require `IO` directly
- Pure functions should remain pure—never add effects for convenience

---

## Error Handling

The sections below are the Haskell mechanics — which type carries a failure, and where an exception is still the right tool. What an error must *be* is governed by `coding_guidelines.md` → **Failure**, the single source for those rules.

### Use the Type System

- `Maybe` for optional values
- `Either` for pure operations that can fail with a reason
- `Error` effect for effectful computations that can fail
- Exceptions only for truly exceptional, unrecoverable situations

```haskell
-- Pure parsing
parseConfig :: Text -> Either ConfigError Config

-- Effectful operation with typed errors
loadConfig :: (Error ConfigError :> es, IOE :> es) => FilePath -> Eff es Config
loadConfig path = do
  contents <- liftIO (readFile path) `catchIO` \_ -> 
    throwError (ConfigNotFound path)
  case parseConfig contents of
    Left err     -> throwError err
    Right config -> pure config
```

### Fail Early, Fail Loudly

- Validate inputs at boundaries
- Use smart constructors to enforce invariants
- Prefer early returns via `Error` effect over nested conditionals
- Handle errors at the appropriate level—don't catch too early

---

## Code Organization

### Module Structure

- One primary type per module when practical
- Group constants and configuration at module top
- Order functions by dependency—callees before callers, or vice versa, but be consistent
- Keep modules focused; split when they grow beyond ~300 lines

### Named Constants for Magic Values

Extract magic numbers and strings into named constants at module top. Names document intent and enable easy modification.

```haskell
-- Good: intent is clear, easy to tune
browserStartupDelay :: Int
browserStartupDelay = 2000000  -- 2 seconds in microseconds

maxSlugLength :: Int
maxSlugLength = 50

trackingParams :: [Text]
trackingParams = ["utm_source", "utm_medium", "fbclid", "gclid"]

-- Bad: magic values inline
launchBrowser = do
  threadDelay 2000000  -- what is this?
  ...

-- Bad: comment instead of name
threadDelay 2000000  -- browser startup delay
```

### Imports

- Explicit import lists for non-standard libraries
- Qualified imports for ambiguous or commonly-aliased modules
- Prelude alternatives (if used) should be project-wide standard
- Import effectful modules with clear patterns

```haskell
import Effectful
import Effectful.Reader.Static (Reader, ask, runReader)
import Effectful.Error.Static (Error, throwError, runError)

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
```

### Import Hygiene for Qualified Modules

When using a module both qualified and unqualified, import types explicitly for unqualified use alongside the qualified import. This makes type signatures clean while keeping function calls unambiguous.

```haskell
-- Good: Text is unqualified in signatures, T.* for functions
import Data.Text (Text)
import Data.Text qualified as T

processName :: Text -> Text
processName = T.strip . T.toLower

-- Bad: forces T.Text everywhere or ambiguous Text
import Data.Text qualified as T

processName :: T.Text -> T.Text  -- noisy signatures
```

---

## Modern Idioms

These patterns are enforced by hlint. Prefer them for consistency and clarity.

### Traversable over Monad-specific

Use `Traversable` functions from `Data.Foldable` and `Data.Traversable`:

```haskell
-- Bad: Monad-specific
mapM f xs
mapM_ f xs
forM xs f
forM_ xs f
sequence (map f xs)

-- Good: Traversable (more general)
traverse f xs
traverse_ f xs
for xs f
for_ xs f
traverse f xs
```

### foldMap over maybe with empty

When extracting a monoidal value from `Maybe`, use `foldMap`:

```haskell
-- Bad: verbose
maybe [] (\x -> [x]) mVal
maybe [] f mVal

-- Good: direct
foldMap pure mVal
foldMap f mVal
```

### fmap over map for Functors

Use `fmap` when working with functors other than lists, or when the context is clearly functor-generic:

```haskell
-- Bad: list-specific in functor context
T.concat . map collapseGroup . T.group

-- Good: functor-generic
T.concat . fmap collapseGroup . T.group
```

### pure over return

`pure` is more general (Applicative) than `return` (Monad):

```haskell
-- Bad
return x

-- Good
pure x
```

### readMaybe over read

`read` is partial and throws on invalid input:

```haskell
-- Bad: throws on invalid input
let n = read str :: Int

-- Good: returns Maybe
import Text.Read (readMaybe)
let mN = readMaybe str :: Maybe Int
```

### async over forkIO

`forkIO` silently discards exceptions from the spawned thread:

```haskell
-- Bad: exceptions lost
_ <- forkIO $ doWork

-- Good: exceptions propagate
import Control.Concurrent.Async (async, wait)
task <- async doWork
result <- wait task

-- Or for fire-and-forget with proper exception handling:
import Control.Concurrent.Async (withAsync)
withAsync doWork $ \_ -> mainWork
```

Note: `forkIO` may be acceptable for long-running worker threads where you handle exceptions internally and don't need the result. Document the rationale when using it.

---

## Performance

Laziness makes the cost of an expression invisible at the call site, so these are
read for, not noticed.

- Recursion that is not in tail position accumulates stack; give the accumulator a
  bang pattern or use a fold that is already strict.
- Repeated `++` and `length` inside a loop are O(n^2). Build with a difference list
  or `Data.Sequence`, and carry the length rather than recomputing it.
- `foldl` builds a thunk chain the whole input long. Use `foldl'`, and with it
  `sum` and `product` over anything large.
- A lazy field in a data type that is always forced is a thunk that lives as long as
  the record. Make it strict, and `{-# UNPACK #-}` it when it is a small primitive.
- Lazy `Text` or `ByteString` where the whole value is consumed at once costs a
  chunk list for nothing; choose strict.
- `read` fails by exception on any input it does not understand. Use `readMaybe` or
  a real parser.
- A list traversed by index, or traversed many times, is a `Vector`. A lookup by key
  is `Data.Map`, or `Data.HashMap` where ordering is never needed.

## Testing

Test code is documentation of behaviour, so it tolerates verbosity production code
does not: an explicit fixture that reads plainly beats a clever generator. What it
does not tolerate is a gap — every public function has a test, and each covers the
edge cases (empty input, boundaries, the error path) beside the happy one. A
refactor that reduces coverage is not a refactor.

## Complexity and mutation

> *Source: [Verification](coding_guidelines.md#verification), [lizard](https://github.com/terryyin/lizard)*

`~/.claude/scripts/change_gate.py` holds a change to the mutation bar.

- **Complexity is held in review.** lizard, the gate's counter, reads no
  Haskell, so the cap of 10 paths per function is a review finding, not a
  measured one.
- **Every mutant on a changed line is killed.** The gate's mutator swaps
  `<`/`<=`/`>`/`>=`, `==`/`/=`, `&&`/`||`, `True`/`False` and `+ 1`/`- 1` in
  the code of each changed line, never in a string or after `--`. `<-`, `->`
  and `=>` are not comparisons and are left alone. It runs the
  `--test haskell` command for each mutant: `--test 'haskell=cabal test'`.
  With no command, a Haskell change fails the gate. Test files (`*Spec.hs`,
  and those under a test folder) are not
  mutated.
- **An equivalent mutant is marked on its line:**
  `-- mutation: equivalent — <reason>`.

## Anti-Patterns to Avoid

### Code Smells

- Overuse of `String`—prefer `Text`
- Partial functions (`head`, `!!`, `fromJust`, `read`)
- Over-abstracted type classes with single instances
- Bang-everywhere reflex inside function bodies (different from the per-record `StrictData` policy above — module-level strictness is policy; speculative `!` on every let-binding, or reaching for unboxed types, is premature optimization)
- Complex `lens` machinery when simple record access suffices
- Monad transformer stacks when `effectful` would be clearer
- Kitchen-sink effects that bundle unrelated operations
- `IOE` scattered throughout business logic instead of at the edges

### Prefer Battle-Tested Library Functions

Before implementing any utility function, verify it doesn't already exist in:

1. `base` / Prelude
2. `containers`, `text`, `bytestring` (core ecosystem)
3. `extra` (common utilities not in base)

If you're writing more than 2-3 lines of list/set/map manipulation, there's probably
a library function for it. Run `hlint` to catch common patterns automatically.

Signs you might be reinventing the wheel:
- Manual recursion over lists with an accumulator
- Folding with Set/Map for tracking state
- Pattern matching on list structure for common operations

### Style Smells

- Point-free that requires mental gymnastics to read
- Excessively long lines (keep under 100 characters)
- Anonymous functions longer than one simple expression
- Multiple responsibilities in one function

---

## LLM Interaction Guidelines

How to take direction, change code and work a problem is governed by
`coding_guidelines.md` → **Communication and Problem-Solving**, the
single source for those rules. Haskell adds nothing to them.

---

## Formatting

- Use a consistent formatter (`fourmolu` or `ormolu`)
- 2-space indentation is standard
- Align record fields and `where` clauses for readability
- One blank line between top-level declarations
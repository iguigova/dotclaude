# Clojure/ClojureScript Coding Guidelines

## Core Philosophy

Code quality priorities, in order:

1. **Correct** — Data shapes should make invalid states unlikely
2. **Simple and Readable** — Follow Rich Hickey's definition of "Simple"; favor clarity over cleverness
3. **Extensible** — Functions and data should compose naturally
4. **Performant** — Optimize only when measured and necessary

Always favor the human programmer over the machine. Prefer
readability and clarity of design over performance unless explicitly
instructed otherwise.

---

## Function Design

### Keep Functions Small and Focused

- Aim for 1-5 lines per function (guideline, not a hard rule)
- Each function should do exactly one thing
- Prefer single-argument functions that compose via `comp` and `|>`
- Extract complex expressions into named bindings
- Extract complex operations into named functions even if used once

```clojure
;; Good: small, composable
(defn active-jobs [jobs]
  (filter active? jobs))

(defn sorted-by-number [jobs]
  (sort-by :job/number jobs))

;; Use: (->> jobs active-jobs sorted-by-number)
```

### Invariant Args First

- Place invariant arguments before varying arguments
- This enables composition with `|>` (reverse comp) and `|?` (partial)
- Always require/assume presence of the fx library providing these
- If invariant args are placed first, the function can be readily
  composed and mapped over

```clojure
;; Good: invariant (centroid) first, varying (summary) last
(defn add-distance [centroid-vec centroid-mag summary]
  ...)

;; Now composable:
(map (|? add-distance centroid-vec centroid-mag) summaries)
```

### Entry Point Naming

- Use `-main` in the core namespace
- Use `main` in all other namespaces

### Build Through Composition

- Functions should build upon each other
- Prefer pipelines of simple functions over complex single functions
- Use `->` for object-centric transforms, `->>` for collection pipelines
- Never nest `->` inside `->>` or vice versa — use `let` or `some->`

```clojure
;; Good: clear pipeline
(defn active-job-list- [jobs]
  (->> jobs
       (filter active?)
       (sort-by :job/number)))

;; Bad: nested threading
(->> items
     (map #(-> % :user :name s/lower-case)))

;; Good: extract helper
(defn user-name-lower [item]
  (-> item :user :name s/lower-case))

(->> items (map user-name-lower))
```

---

## Data-Driven Development

### Let Data Guide Implementation

- Use keyword-namespaced maps for domain entities
- Maps can be used as functions for key lookups
- Don't create Records unnecessarily — prefer plain maps
- Don't use overly complex or nested destructuring
- Validate at boundaries, trust data internally
- Use destructuring to document expected data shapes

```clojure
;; Good: namespaced keys, clear shape
{:job/name "Site A"
 :job/number "TST-001"
 :job/archived false
 :job/location {:db/id 123}}

;; Good: destructuring documents shape
(defn unique-email-
  [{:keys [:data/id :user/email]} index]
  (let [idx-user (get index email)]
    (not (and idx-user (not= id (:data/id idx-user))))))
```

### State Predicates

- Use the `defstate` macro for entity predicates
- Zero-arg form returns the predicate function
- One-arg form applies to a single record or filters a collection
- Parameterized predicates place invariant args first

```clojure
(defstate active? [job]
  (not (archived job)))

(defstate by-region? [region] [job]
  (= (-> job :job/region :region/name) region))

;; Usage: (filter active? jobs)
;; Usage: (by-region? "BC" some-job)
```

---

## Naming Conventions

### Be Precise and Concise

- Subscription functions end in `-` (e.g., `active-job-list-`)
- Side-effecting functions end in `!` (e.g., `init-signature-pad!`)
- Side effects include: exceptions, IO, state, randomness, DB access
- Actions/transforms start with `$` (e.g., `$activate`, `$archive`)
- Don't include redundant nouns apparent from arguments
- Use brevity when it doesn't reduce clarity

```clojure
;; Bad: redundant noun
(defn order-summaries-by-distance [summaries] ...)

;; Good: context clear from arg
(defn order-by-distance [summaries] ...)
```

### Constants

- Name constants in UPPER_SNAKE_CASE at top of file
- Use `_` not `-` in constant names

```clojure
(def BC {:db/id 17592186060197})
(def DEFAULT_REGION "BC")
```

---

## Idiomatic Clojure

- Prefer `mapv`/`filterv` over `map`/`filter` when laziness isn't needed
- Use `core.match` over `if`/`cond` for map destructuring
- Prefer pure functions unless it makes the code ugly
- Use Clojure's built-in concurrency primitives over external libs
- Extract regex patterns into named constants at file top

```clojure
;; Good: eager when laziness not needed
(mapv transform items)

;; Good: pattern matching over nested conditionals
(match [msg]
  [{:type :error :code code}] (handle-error code)
  [{:type :success}]         (handle-success msg))

;; Good: regex as named constant
(def PHONE_PATTERN #"\d{3}-\d{3}-\d{4}")
```

---

## Code Organization

### Namespace Structure

- One primary entity per model namespace
- Group constants at namespace top
- Define functions in order they are called/needed
- Keep namespaces under ~300 lines; split when larger
- Label code sections so they can be discussed independently
- Order: entity definition, state predicates, actions, show methods,
  subscription functions

### Imports

- Align requires for readability
- Use `:refer` for frequently-used symbols
- Use `:as` aliases for namespace-qualified access
- Reader conditionals for platform-specific requires

```clojure
(ns krewz.model.job
  (:require [clojure.string :as s]
            [krewz.model :as mdl :refer [show]]
            [krewz.util :as u :refer [|>]]
            [krewz.macros :refer [defentity defstate defaction]])
  (:refer-clojure :rename {name core-name} :exclude [name]))
```

---

## Style and Formatting

### Line Width

- Find logical break points for long lines
- Don't let one line stick out from a block of shorter lines

### Indentation

- 2-space indentation is standard
- Symmetry is king — if you take an approach, apply it universally
- Short fns should inline their args
- Args on next line if there's a docstring or type hint
- Don't break symmetry between let binding pairs
- Where one binding form is a long destructuring map, put every
  binding's value on its own next line — symmetry decides the
  whole `let`, not each pair separately

```clojure
;; Good: symmetrical, consistent breaks
(defn- prepare-params [user-params]
  (merge
    (default-params)
    (select-keys
      user-params
      [:n-neighbors :n-components :min-dist])
    {:metric
     (or (:metric user-params)
         (:metric (default-params)))}))

;; Bad: one line juts out
(when-let [result (prepare-and-cluster normalized-arrays
                                        umap-params
                                        hdbscan-params)]
  ...)

;; Good: reduce line span
(when-let
  [result
   (prepare-and-cluster
     normalized-arrays umap-params hdbscan-params)]
  ...)

;; Bad: constructor args aligned to first arg (jagged)
(HdbscanTrainer. min-cluster-size
                 (.getDistance distance-type)
                 min-points
                 threads)

;; Good: args on separate lines, uniform indent
(HdbscanTrainer.
  min-cluster-size
  (.getDistance distance-type)
  min-points
  threads)

;; Bad: log/info wraps the line
(log/info "No significant clusters found (only noise ...)")

;; Good: break after the fn name
(log/info
  "No significant clusters found (only noise ...)")

;; Bad: breaks symmetry between let bindings
(let [dataset (create-dataset arrays)
      trainer
      (create-hdbscan-trainer
        (:min-cluster-size params)
        (:min-points params))
      model (.train trainer dataset)]
  ...)

;; Good: keep let binding pairs aligned
(let [dataset (create-dataset arrays)
      trainer (create-hdbscan-trainer
                (:min-cluster-size params)
                (:min-points params))
      model (.train trainer dataset)]
  ...)

;; Bad: long destructuring forms, values jammed alongside
(let [{:keys [noise-count noise-ids cluster-groups]} (extract-noise-info data ids)
      {:keys [num-clusters largest average]}
      (extract-cluster-stats cluster-groups ids)]
  ...)

;; Good: every value on its next line, and a long expression named
(let [{:keys [noise-count noise-ids cluster-groups]}
      (extract-noise-info data ids)
      {:keys [num-clusters largest average]}
      (extract-cluster-stats cluster-groups ids)
      noise-perc
      (if (pos? total-points)
          (* 100.0 (/ noise-count total-points))
          0.0)]
  ...)
```

#### Emacs Indent Config

Every form whose body is really a list of arguments indents to 0, so
its args line up under each other instead of under the first one.

```elisp
(setq clojure-indent-style 'always-indent)

(defun custom-clojure-indents ()
  (interactive)
  (put-clojure-indent '-> 0)
  (put-clojure-indent '->> 0)
  (put-clojure-indent 'as-> 0)
  (put-clojure-indent 'map 0)
  (put-clojure-indent 'mapv 0)
  (put-clojure-indent 'filter 0)
  (put-clojure-indent 'comp 0)
  (put-clojure-indent 'and 0)
  (put-clojure-indent 'or 0)
  (put-clojure-indent '= 0)
  (put-clojure-indent 'not= 0)
  (put-clojure-indent '< 0)
  (put-clojure-indent '> 0)
  (put-clojure-indent 'if 0)
  (put-clojure-indent 'doto 'nil))
```

### Maps

- Single-line when 2 or fewer key-value pairs
- Multi-line with one pair per line when 3+
- Long lines OK if ALL lines in the map are long (symmetry)

```clojure
;; Good: short map inline
{:db/id "1" :job/name "Test"}

;; Good: multi-line, symmetrical
{:min-cluster-size (or (:min-cluster-size p) DEFAULT_SIZE)
 :min-points (or (:min-points p) DEFAULT_POINTS)
 :distance-type distance-type
 :threads (or (:threads p) DEFAULT_THREADS)}
```

---

## Threading and Nesting

### Threading Macros

- `->` for object transforms (map → field → transform)
- `->>` for collection pipelines (coll → filter → map → sort)
- `some->` for nil-safe chains
- `as->` when you need to name the intermediate value
- Never nest one threading form inside another

### Nesting

- Prefer 1 level of nesting where possible
- Only nest within simple constructs: `when`, `let`, `if`
- Use `when-let*` macro when multiple bindings must succeed
- Instead of deep nesting, extract helper fns and compose

```clojure
;; Bad: deep nesting
(defn process [data]
  (when data
    (if (valid? data)
      (let [result (transform data)]
        (when result
          (save! result)))
      (log/warn "invalid"))))

;; Good: flat, composed
(defn process [data]
  (when-let* [data data
              _ (valid? data)
              result (transform data)]
    (save! result)))
```

---

## Anonymous Functions

- Prefer named helper functions over anonymous functions
- If anonymous, use `(fn [x] ...)` not `#(...)`
- Anonymous fns must be dead simple — one expression max
- Extract and define a helper fn for anything more complex

```clojure
;; Bad: complex anonymous function
(map #(let [n (:name %)] (str (s/upper-case n) "-" (:id %))) items)

;; Good: named helper
(defn format-item [{:keys [name id]}]
  (str (s/upper-case name) "-" id))

(map format-item items)
```

---

## Error Handling

- Use `nil` for absence (Clojure idiom)
- Use `ex-info` + `ex-data` for errors with context
- Validate at system boundaries (user input, API responses)
- Trust internal data — don't validate between pure functions
- Don't add error handling for scenarios that can't happen

---

## Re-frame Conventions (Krewz-specific)

### Event Handlers

- `defnt` for pure db transforms (returns new db)
- `defx` for effectful handlers (returns effects map)
- `defx2` for effectful handlers with coeffect injection
- Event keywords auto-namespaced to `krewz.events`

### Subscriptions

- `defsubs` macro generates layer-2 and layer-3 subs from tree
- Subscription functions end in `-` (the raw computation fn)
- Config map in `subs.cljs` maps keywords to computation fns
- Layer-2: direct db key lookup
- Layer-3: computed from other subscriptions

### dispatch-tsx Bridge

- TSX components dispatch via `callback(component, event, data)`
- CLJS side handles via `defmethod dispatch-tsx [comp event]`
- Each wrapper file owns its component's dispatch methods
- Bridge methods should be thin — dispatch to re-frame events

---

## Anti-Patterns to Avoid

### Code Smells

- Long `let` bindings with many steps — extract helper fns
- Deeply nested `if`/`when` branches — use `cond` or `case`
- `println` for debugging — use proper logging or remove
- Hardcoded credentials — use environment variables
- Atoms and state management when simpler constructs will do
- Java interop, or a Java library, where a pure Clojure solution exists

### Style Smells

- One line jutting out from a symmetrical block
- Mixing `->` and `->>` in the same expression
- Complex `#()` reader macros — use `(fn [x] ...)`
- Unnecessary let bindings when threading works

---

## Comments

What a comment may say is governed by `coding_guidelines.md` →
**Comments**, the single source for those rules. Clojure adds no
mechanics of its own.

---

## Testing Conventions

### Test Organization

- Test namespace mirrors source: `krewz.model.user` → `krewz.model.user-test`
- One `deftest` per function or logical group
- `testing` blocks for sub-cases within a `deftest`
- Test file naming: `*_test.cljc` for model, `*_test.cljs` for re-frame

### Assertion Style

- Use `match?` from matcher-combinators for data structure comparison
- Subset matching by default — only assert what matters
- `is` + `match?` for flexible assertions
- Plain `is` + `=` for exact equality when needed

```clojure
(deftest active-job-list-test
  (testing "filters archived jobs"
    (let [jobs [{:job/name "A" :job/archived false}
                {:job/name "B" :job/archived true}]]
      (is (match? [{:job/name "A"}]
                  (active-job-list- jobs))))))
```

### Re-frame Testing

- `run-test-sync` for synchronous event dispatch
- Seed db via `dispatch [:initialize-db]` then `swap! app-db`
- Test event handlers as pure functions when possible (Pattern D)
- Import both `krewz.events` and `krewz.subs` for registration

---

## LLM Interaction Guidelines

How to take direction, change code and work a problem is governed by
`coding_guidelines.md` → **Communication and Problem-Solving**, the
single source for those rules. Clojure adds nothing to them.

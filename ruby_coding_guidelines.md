# Ruby Coding Guidelines

> Compiled from authoritative sources with citations. See [Sources](#sources) at the bottom.

Applies to Ruby 3.x and Rails 7/8. `coding_guidelines.md` owns the general
principles — including the **Failure** and **Comments** rules, which are stated
only there. This guide adds Ruby mechanics and never restates them.
`style_guidelines.md` owns how code sits on the page.

## Core Philosophy

Code quality priorities, in order:

1. **Correct** — the code does what it is supposed to do
2. **Simple and Readable** — optimised for the next person to read it
3. **Extensible** — changeable without a rewrite
4. **Performant** — fast enough, measured before tuned

Always favour the human programmer over the machine. Prefer readability and
clarity of design over performance unless explicitly instructed otherwise.

**Ruby's premise** — the language is designed to make the programmer
productive and the code pleasant to read. Ruby gives many ways to say the same
thing; a guide exists so a team picks one. Where this guide and cleverness
disagree, the guide wins.

**The Rails Doctrine**, in the parts that constrain code:
- **Convention over configuration** — a name that follows the convention needs
  no wiring. Fighting a convention costs more than adopting it.
- **The menu is omakase** — use the framework's answer (Active Record, Action
  Mailer, Active Job) before reaching for a third-party one.
- **No one paradigm** — Rails is not purely OO or purely functional; choose
  per problem, and do not import a paradigm wholesale.
- **Provide sharp knives** — Rails permits dangerous things (`update_all`,
  `html_safe`, metaprogramming). Permission is not endorsement.

---

## Formatting

### Layout
> *Source: [Ruby Style Guide](https://rubystyle.guide/), `style_guidelines.md`*

- **Two spaces per indent level, never tabs.**
- **One expression per line.** No semicolons.
- **`do ... end` for multi-line blocks, `{ ... }` for single-line blocks.**
- **No trailing whitespace**, and end every file with a newline.
- **Use empty lines to separate a method's phases**, and one empty line
  between method definitions.

### Frozen string literals
> *Source: [Ruby Style Guide — frozen-string-literal-comment](https://rubystyle.guide/#frozen-string-literal-comment)*

Every file starts with the magic comment. It makes every string literal in the
file frozen, which removes a per-literal allocation and turns accidental
mutation into a loud `FrozenError` instead of a silent shared-state bug.

```ruby
# frozen_string_literal: true

# Bad — mutating a frozen literal raises FrozenError
def greeting(name)
  out = ""
  out << "Hello, " << name
end

# Good — build with interpolation, or start from an unfrozen buffer
def greeting(name)
  "Hello, #{name}"
end

def report(rows)
  buffer = String.new          # unfrozen, mutation is intended
  rows.each { |r| buffer << r << "\n" }
  buffer
end
```

### Heredocs and literals
> *Source: [Ruby Style Guide](https://rubystyle.guide/#squiggly-heredocs)*

- **Squiggly heredoc `<<~` for multi-line text**, so the indentation of the
  code does not leak into the string.
- **`%w[]` for arrays of words, `%i[]` for arrays of symbols.**
- **Underscore long numerics** — `1_000_000`, not `1000000`.

```ruby
# Bad
STATES = ['pending', 'active', 'closed']
KEYS   = [:name, :email]

# Good
STATES = %w[pending active closed].freeze
KEYS   = %i[name email].freeze
```

---

## Naming

> *Source: [Ruby Style Guide — Naming](https://rubystyle.guide/#naming-conventions)*

| Thing | Convention |
|---|---|
| methods, variables, symbols | `snake_case` |
| classes, modules | `CapitalCase`, acronyms stay upper (`HTTPClient`, `XMLParser`) |
| other constants | `SCREAMING_SNAKE_CASE` |
| files | `snake_case.rb`, matching the class it defines |
| predicate methods | end in `?` |
| dangerous methods | end in `!`, **only if a safe sibling exists** |
| unused block param / local | prefix `_` |

- **Predicate methods end in `?` and return a boolean.** "The names of
  predicate methods (methods that return a boolean value) should end in a
  question mark."
- **Do not prefix a predicate with an auxiliary verb.** Steer clear of `is_`,
  `does_`, `can_` — the `?` already says it. `published?`, not `is_published?`.
- **`!` marks the dangerous member of a pair.** "The names of potentially
  dangerous methods should end with an exclamation mark if there exists a safe
  version." A `!` method with no safe sibling is misleading decoration: the
  suffix means "there is a gentler way to do this", not "this one raises".
- **One class or module per file**, named for it.

```ruby
# Bad — ! with nothing to contrast it against
def process!(order) = gateway.submit(order)

# Bad — auxiliary verb, and no ?
def is_valid(order) = order.errors.empty?

# Good
def valid?(order) = order.errors.empty?
def save(order)   = order.save          # returns false on failure
def save!(order)  = order.save!         # raises on failure
```

---

## Methods

### Size and arguments
> *Source: [Ruby Style Guide](https://rubystyle.guide/#short-methods), [Sandi Metz's rules](https://thoughtbot.com/blog/sandi-metz-rules-for-developers)*

- **"Avoid methods longer than 10 LOC. Ideally, most methods will be shorter
  than 5 LOC."**
- **"Avoid parameter lists longer than three or four parameters."** Sandi
  Metz: "Pass no more than four parameters into a method. Hash options are
  parameters."
- **Optional arguments go last**; required keyword arguments go before
  optional keyword ones.
- **Use keyword arguments instead of an option hash.** They are
  self-documenting at the call site and fail loudly on a typo.

```ruby
# Bad — positional booleans, unreadable at the call site
def notify(user, email, sms, urgent)
  # ...
end

notify(user, true, false, true)

# Good — keyword arguments say what each value means
def notify(user, email: true, sms: false, urgent: false)
  # ...
end

notify(user, email: true, urgent: true)
```

### Guard clauses over nesting
> *Source: [Ruby Style Guide — guard clauses](https://rubystyle.guide/#no-nested-conditionals)*

"Prefer a guard clause when you can assert invalid data. A guard clause is a
conditional statement at the top of a function that bails out as soon as it
can." Handle the exceptional case first and leave the body at one indent.

```ruby
# Bad — the real work is buried three levels deep
def charge(order)
  if order.present?
    if order.payable?
      if order.total.positive?
        gateway.charge(order.total)
      end
    end
  end
end

# Good — each precondition is its own line, the work is unindented
def charge(order)
  return if order.blank?
  return unless order.payable?
  return unless order.total.positive?

  gateway.charge(order.total)
end
```

### Return values
> *Source: [Ruby Style Guide](https://rubystyle.guide/#no-explicit-return)*

- **No explicit `return` for the last expression** — a method returns its
  final expression. Keep `return` for early exits.
- **Avoid single-line method definitions.** An endless method
  (`def x = expr`, Ruby 3.0+) is acceptable only for a true one-expression
  accessor or delegation, never for anything with a side effect.
- **`unless` for a negative condition**, not `if !`. Never `unless ... else`.
- **Never use `and` / `or` as boolean operators** — their precedence differs
  from `&&` / `||` and produces surprises. Use `&&` and `||`.

---

## Classes and Modules

### Structure
> *Source: [Ruby Style Guide — consistent classes](https://rubystyle.guide/#consistent-classes)*

One order, every class, so a reader can skim to the part they want:

```ruby
class Booking < ApplicationRecord
  extend  Searchable                 # 1. extend and include
  include Auditable

  CANCELLABLE_STATES = %i[pending confirmed].freeze   # 2. constants

  belongs_to :user                   # 3. macro-style declarations
  has_many   :payments, dependent: :destroy
  validates  :starts_at, presence: true
  scope :upcoming, -> { where(starts_at: Time.current..) }

  attr_reader :calculator            # 4. attribute macros

  def self.reconcile(date)           # 5. class methods
    # ...
  end

  def initialize(attributes = {})    # 6. initialisation
    super
    @calculator = Rates::Calculator.new(space)
  end

  def cancel!                        # 7. public instance methods
    transaction do
      update!(cancelled_at: Time.current)
      notify_cancellation
    end
  end

  private                            # 8. access modifiers last

  def notify_cancellation
    CancellationMailer.notify(self).deliver_later
  end
end
```

### Design
> *Source: [Ruby Style Guide](https://rubystyle.guide/#classes--modules), [Sandi Metz's rules](https://thoughtbot.com/blog/sandi-metz-rules-for-developers)*

- **"Classes can be no longer than one hundred lines of code."** A class past
  that is doing more than one job; split it. A `rubocop:disable` on a length
  cop is a debt marker, and in review it is a finding unless the change says
  why.
- **Leverage access modifiers.** Everything not part of the object's contract
  is `private`. `protected` only where a sibling instance must be compared.
- **Never use class variables (`@@x`).** They are shared down the whole
  inheritance tree and mutate from anywhere. Use a class-level instance
  variable with an `attr_accessor` on `class << self`, or a constant.
- **`attr_reader` / `attr_writer` / `attr_accessor`** rather than hand-written
  getters and setters.
- **Prefer composition over inheritance.** Inherit to share a *type*; compose
  or include a module to share *behaviour*. Deep hierarchies make the source
  of a method unfindable.
- **A module used as a namespace holds no state.** A module used as a mixin
  documents what it expects of the host class.

```ruby
# Bad — class variable, shared and mutable from anywhere
class Registry
  @@items = []
  def self.add(i) = @@items << i
end

# Good — state belongs to the class object itself
class Registry
  class << self
    attr_reader :items
  end
  @items = []

  def self.add(item)
    @items << item
  end
end
```

### Value objects
> *Source: [Ruby `Data`](https://docs.ruby-lang.org/en/master/Data.html), [`Struct`](https://docs.ruby-lang.org/en/master/Struct.html)*

Use `Data.define` (Ruby 3.2+) for an immutable value object — it gives
`==`, `to_h`, keyword or positional construction, and no setters. Reach for
`Struct` only when the value must be mutable, which is rare.

```ruby
# Good — immutable, comparable by value, self-documenting
Money = Data.define(:amount_cents, :currency) do
  def +(other)
    raise ArgumentError, "currency mismatch" unless currency == other.currency

    with(amount_cents: amount_cents + other.amount_cents)
  end
end
```

---

## Error Handling

The rules for *what* an error must be — never a neutral empty value, never a
swallowed `false`, always raised before the side effect — are in
`coding_guidelines.md` → **Failure**, the single source for them. This section
is the Ruby mechanics only.

### Which class to rescue
> *Source: [Ruby Style Guide — Exceptions](https://rubystyle.guide/#exceptions)*

- **Never rescue `Exception`.** "This will trap signals and calls to `exit`,
  requiring you to `kill -9` the process." `StandardError` is the boundary for
  application errors; `Exception` includes `SignalException`, `SystemExit` and
  `NoMemoryError`, none of which application code can handle.
- **Never use a bare `rescue`** — it means `rescue StandardError` implicitly.
  Say it, so the reader does not have to know the default.
- **Rescue the narrowest class that can actually be raised**, and order
  handlers most-specific first: "Put more specific exceptions higher up the
  rescue chain, otherwise they'll never be rescued from."
- **Avoid the `rescue` modifier form** (`value = risky rescue nil`) — it
  catches every `StandardError` and discards it.

```ruby
# Bad — traps Ctrl-C, OOM and exit; hides every bug in the block
begin
  gateway.charge(order)
rescue Exception => e
  nil
end

# Bad — bare rescue, and the error vanishes
begin
  gateway.charge(order)
rescue
end

# Good — the one failure this caller knows how to handle, named
begin
  gateway.charge(order)
rescue Gateway::TimeoutError => e
  Rails.logger.warn("charge timed out: #{e.message}")
  raise Billing::Unavailable, "payment provider unreachable"
end
```

### Raising
> *Source: [Ruby Style Guide](https://rubystyle.guide/#prefer-raise-over-fail)*

- **`raise`, never `fail`.**
- **Pass the class and message as two arguments**, not a constructed
  instance: `raise ArgumentError, "msg"`, not
  `raise ArgumentError.new("msg")`.
- **Do not name `RuntimeError` explicitly** in the two-argument form —
  `raise "msg"` already means that.
- **Define a domain error hierarchy under `StandardError`**, one root per
  bounded area, so a caller can rescue the area or a specific failure.

```ruby
# Good — one root, specific leaves, all rescuable as StandardError
module Billing
  Error         = Class.new(StandardError)
  Unavailable   = Class.new(Error)
  CardDeclined  = Class.new(Error)
end

# a caller that handles every billing failure the same way
begin
  Billing::Charge.call(invoice)
rescue Billing::Error => e
  render_failure(e.message)
end

# a caller that treats only the transient one as retryable
begin
  Billing::Charge.call(invoice)
rescue Billing::Unavailable
  Billing::RetryJob.perform_in(5.minutes, invoice.id)
end
```

### Block scope, `ensure` and flow
> *Source: [Ruby Style Guide](https://rubystyle.guide/#dont-hide-exceptions)*

- **Keep the `begin` block as small as the operation that can fail.** A wide
  block rescues failures from code you never meant to guard.
- **Use an implicit `begin`** — a method body, `def ... rescue ... end`, needs
  no explicit `begin`.
- **"Don't suppress exceptions."** An empty `rescue` body is never correct: it
  turns a failure into a silent wrong answer.
- **Never `return` from an `ensure` block.** "If you explicitly return from a
  method inside an `ensure` block, the return will take precedence over any
  exception being raised" — the error disappears.
- **`ensure` is for releasing a resource**, not for producing a value.
- **Don't use exceptions for flow control.** Check the condition.

```ruby
# Bad — ensure swallows the exception entirely
def fetch
  risky_call
ensure
  return cached          # the raise never reaches the caller
end

# Good — ensure only releases, the error propagates
def fetch
  connection = pool.checkout
  connection.read
ensure
  pool.checkin(connection) if connection
end
```

---

## Collections

> *Source: [Ruby Style Guide — Collections](https://rubystyle.guide/#collections)*

- **Literal syntax** — `[]` and `{}`, not `Array.new` / `Hash.new` (except
  `Hash.new` with a default block, and `String.new` for an unfrozen buffer).
- **Iterate with `Enumerable`, never a `for` loop.** `each` to act, `map` to
  transform, `select`/`reject` to filter, `detect` for the first match,
  `reduce` to fold, `sum`/`min_by`/`group_by`/`tally` where they fit.
- **Symbols as hash keys**, and never a mutable object as a key.
- **`Hash#fetch` where a missing key is a bug** — it raises instead of
  returning `nil`, which is the Failure rule applied to lookups. Pass a
  default explicitly where absence is legitimate.
- **`first` / `last`** rather than `[0]` / `[-1]`.
- **Never mutate a collection while iterating it.** Build a new one.
- **`freeze` a constant collection**, or it is mutable global state.

```ruby
# Bad — silently nil, then explodes somewhere far away
rate = config[:rate]

# Good — a missing key fails here, where it is wrong
rate = config.fetch(:rate)
rate = config.fetch(:rate, DEFAULT_RATE)    # absence is legitimate

# Bad — a manual accumulator
names = []
users.each { |u| names << u.name if u.active? }

# Good
names = users.select(&:active?).map(&:name)
```

---

## Strings, Symbols and Regular Expressions

> *Source: [Ruby Style Guide](https://rubystyle.guide/#strings), [Rails Security Guide](https://guides.rubyonrails.org/security.html#regular-expressions)*

- **Interpolate, don't concatenate.** `"Hello, #{name}"` beats
  `"Hello, " + name` — it is faster, and it calls `to_s` for you.
- **`+` copies, `<<` mutates.** With frozen literals, `<<` on a literal
  raises; use it only on a buffer you own.
- **Use `\A` and `\z`, not `^` and `$`.** In Ruby `^` and `$` match at every
  line boundary, so a pattern anchored with them passes on any string
  containing a newline — a validation bypass, not a style preference.
- **`String#include?` for a plain substring**, not a regexp.
- **Non-capturing groups `(?:...)`** where the content is not used, and
  **named captures** where it is.

```ruby
# Bad — "safe\njavascript:alert(1)" matches
URL = /^https?:\/\/example\.com/

# Good — anchored to the whole string
URL = /\Ahttps?:\/\/example\.com/

# Good — named capture reads at the point of use
if (m = line.match(/\A(?<key>\w+)=(?<value>.*)\z/))
  settings[m[:key]] = m[:value]
end
```

---

## Modern Ruby

> *Source: [Ruby Style Guide](https://rubystyle.guide/), [Ruby pattern matching docs](https://docs.ruby-lang.org/en/master/syntax/pattern_matching_rdoc.html)*

Use these where they make the code shorter *and* clearer — not to demonstrate
that they exist.

- **Safe navigation `&.`** instead of `obj && obj.method`. "Avoid long chains
  of `&.`" — three links means the caller does not know what may be `nil`,
  which is a design problem the operator only hides.
- **Pattern matching `case/in`** for destructuring a nested structure — an API
  payload, a parsed message. Use plain `case/when` for simple value
  comparison; `in` earns its keep only when matching *shape*.
- **`case` over a chain of `elsif`.**
- **Anonymous block forwarding** (`def wrap(&) = inner(&)`) and argument
  forwarding (`def wrap(...) = inner(...)`) for genuine pass-throughs.
- **Prefer Ruby's standard library to an Active Support alias** where both
  exist, and `&.` over `try!`.

```ruby
# Good — case/in destructures and validates shape in one step
case payload
in { event: "booking.created",
     data: { id: String => id, starts_at: String => at } }
  Bookings::Create.call(id:, starts_at: Time.zone.parse(at))
in { event: String => other }
  Rails.logger.info("ignored event #{other}")
else
  raise Webhooks::MalformedPayload, "unrecognised payload shape"
end
```

---

## Rails: Controllers

> *Source: [Rails Style Guide — Controllers](https://github.com/rubocop/rails-style-guide#controllers)*

- **"Keep the controllers skinny — they should only retrieve data for the view
  layer and shouldn't contain any business logic."** A controller's job is
  HTTP: authenticate, authorise, parse params, call one thing, render.
- **"Each controller action should (ideally) invoke only one method other than
  an initial find or new."**
- **"Minimize the number of instance variables passed between a controller and
  a view."** Sandi Metz's fourth rule is the strict form: one object per
  action, and the view sends messages only to that object.
- **Prefer a template to inline rendering**, and **HTTP status symbols to
  numbers** — `:unprocessable_entity`, not `422`.
- **Action filters must be lexically scoped** — a `before_action` naming an
  action defined in another class is unfindable.
- **Strong parameters in a private method**, one per resource, never
  `params.permit!`.

```ruby
# Bad — business logic, four instance variables, a raw status number
def create
  @booking = Booking.new(params[:booking])
  @booking.total = @booking.space.rate * @booking.hours
  if @booking.space.available?(@booking.starts_at)
    @booking.save
    BookingMailer.confirmation(@booking).deliver_now
    @spaces = Space.all
    @user = current_user
    render :show, status: 201
  else
    render :new, status: 422
  end
end

# Good — HTTP in the controller, the decision in the service
def create
  result = Bookings::Create.call(user: current_user, params: booking_params)

  if result.success?
    render :show, locals: { booking: result.booking }, status: :created
  else
    render :new, locals: { errors: result.errors },
           status: :unprocessable_entity
  end
end

private

def booking_params
  params.require(:booking).permit(:space_id, :starts_at, :hours)
end
```

---

## Rails: Models and Active Record

### Declarations
> *Source: [Rails Style Guide — Active Record](https://github.com/rubocop/rails-style-guide#activerecord)*

- **"Group macro-style methods (`has_many`, `validates`, etc) in the beginning
  of the class definition."**
- **"Avoid altering Active Record defaults (table names, primary key, etc)
  unless you have a very good reason."**
- **"Define the `dependent` option to the `has_many` and `has_one`
  associations."** Omitting it leaves orphaned rows; state `:destroy`,
  `:delete_all`, `:nullify` or `:restrict_with_error` deliberately.
- **"Prefer `has_many :through` to `has_and_belongs_to_many`"** — the join
  model can carry attributes and validations.
- **"To make validations easy to read, don't list multiple attributes per
  validation."** One `validates` per attribute.
- **Custom validators live in `app/validators`.**
- **"Prefer using the hash syntax for `enum`"** — positional array values
  renumber silently when someone inserts a member.
- **Append to `ignored_columns`, never assign** — assignment overwrites an
  earlier one.
- **"Use named scopes freely"**, and convert a scope whose lambda grows
  unwieldy into a class method.
- **`self[:attribute]`** over `read_attribute(:attribute)`.

### Callbacks
> *Source: [Rails Guides — Active Record Callbacks](https://guides.rubyonrails.org/active_record_callbacks.html), [Rails Style Guide](https://github.com/rubocop/rails-style-guide#callbacks-order)*

- **"Order callback declarations in the order in which they will be
  executed."**
- **"The whole callback chain is wrapped in a transaction."** A raise anywhere
  in it rolls the save back.
- **`throw :abort` halts the chain.** Then `save` and `destroy` return
  `false`, while `save!` raises `ActiveRecord::RecordNotSaved` and `destroy!`
  raises `ActiveRecord::RecordNotDestroyed`. Choose the form whose failure mode
  the caller actually handles — per `coding_guidelines.md` → **Failure**, an
  ignored `false` is not handling.
- **`after_commit` makes different guarantees.** "`after_commit` makes very
  different guarantees than `after_save`, `after_update`, and
  `after_destroy`": the data is already persisted, so raising cannot roll it
  back, and the callback body is not itself in a transaction. Enqueue jobs and
  call external services here — never inside the transaction, where the job can
  start before the row is visible.
- **The guide's own warning:** "Refrain from using methods like `update`,
  `save`, or any other methods that cause side effects on the object within
  your callback methods." Cross-model work belongs in a service, not a
  callback.

```ruby
# Bad — enqueued inside the transaction; the worker can run before commit,
#        and a later rollback leaves a job referring to a row that never existed
after_save :notify

# Good
after_commit :notify, on: :create

def notify
  BookingConfirmationJob.perform_async(id)
end
```

### Writes
> *Source: [Rails Style Guide — save-bang](https://github.com/rubocop/rails-style-guide#save-bang), [Rails Guides](https://guides.rubyonrails.org/active_record_validations.html)*

- **"When persisting AR objects always use the exception raising bang! method
  or handle the method return value."** An unchecked `save` is the Failure rule
  broken in one line.
- **"Beware of the behavior of" the methods that skip validations.**
  `update_all`, `update_column`, `update_columns`, `increment!`, `toggle!`,
  `insert_all` and `upsert_all` bypass validations, and most bypass callbacks
  and timestamps too. They are correct for a bulk backfill and wrong for a
  domain change.

| Method | Validations | Callbacks | `updated_at` |
|---|---|---|---|
| `save` / `update` | yes | yes | yes |
| `save!` / `update!` | yes (raises) | yes | yes |
| `update_column(s)` | **no** | **no** | **no** |
| `update_all` | **no** | **no** | **no** |
| `insert_all` / `upsert_all` | **no** | **no** | **no** |
| `touch` | no | `after_touch` | yes |

### Soft deletes
> *Source: [paranoia README](https://github.com/rubysherpas/paranoia)*

A soft-delete gem (`paranoia`, `discard`) makes `destroy` set `deleted_at`
and scopes every query to the rows where it is null.

- **A uniqueness rule accounts for `deleted_at`.** "Because NULL != NULL in
  standard SQL, we can not simply create a unique index on the deleted_at
  column"; use a partial index, `where: "deleted_at IS NULL"`, and scope the
  validation to match, or a deleted row blocks a new one.
- **A read that must see deleted rows says so** with `with_deleted` or
  `only_deleted`. A join through a soft-deleted association drops rows
  silently.
- **`really_destroy!` cascades**: it "will also _really destroy_ all
  `dependent: :destroy` records".
- **A `default_scope` composes with the soft-delete scope silently**; read
  both before trusting a count.

### Dirty tracking
> *Source: [`ActiveRecord::AttributeMethods::Dirty`](https://api.rubyonrails.org/classes/ActiveRecord/AttributeMethods/Dirty.html)*

The two families are not interchangeable, and picking the wrong one gives a
callback that never fires.

| Where | Ask | Not |
|---|---|---|
| `before_save`, `before_update`, validations | `will_save_change_to_x?`, `x_change_to_be_saved`, `attribute_in_database` | |
| `after_save`, `after_update`, `after_commit` | `saved_change_to_x?`, `saved_change_to_x`, `x_before_last_save` | |

```ruby
# Bad — in an after_save, this is already false: the save has happened
after_save :sync_if_renamed
def sync_if_renamed
  Sync.call(self) if will_save_change_to_name?
end

# Good
after_save :sync_if_renamed
def sync_if_renamed
  Sync.call(self) if saved_change_to_name?
end
```

---

## Rails: Queries

### Safety
> *Source: [Rails Style Guide — avoid-interpolation](https://github.com/rubocop/rails-style-guide#avoid-interpolation), [Rails Security Guide](https://guides.rubyonrails.org/security.html#sql-injection)*

**"Avoid string interpolation in queries, as it will make your code
susceptible to SQL injection attacks."** Pass conditions as a hash, or as a
fragment with placeholders — named placeholders once there is more than one.

```ruby
# Bad — injection
User.where("email = '#{params[:email]}'")

# Good
User.where(email: params[:email])
User.where("created_at > :since AND role = :role",
           since: 1.week.ago, role: role)
```

### Shape
> *Source: [Rails Style Guide — Active Record Queries](https://github.com/rubocop/rails-style-guide#activerecord-queries)*

- **`find` by primary key**, **`find_by` by attribute** — not `where(...).take`
  or the dynamic `find_by_attribute` forms.
- **"Prefer passing conditions to `where` and `where.not` as a hash over using
  fragments of SQL."** Avoid multiple attributes in one `where.not`; its
  meaning changed in Rails 6.1.
- **`pluck` for a column across records, `pick` for one value, `ids` over
  `pluck(:id)`.**
- **`size`, not `count` or `length`** — it counts in the database when the
  relation is unloaded and in memory when it is loaded.
- **`exists?` to ask whether anything matches** — it does not instantiate.
- **Ranges over comparison fragments** — `where(created_at: 1.week.ago..)`.
- **Don't order by `id`** to mean chronological; order by a timestamp.
- **`first` and `last` carry the `order` that defines them.** With none,
  `first` orders by primary key, which answers "oldest row" only by accident.
- **`where.missing(:association)`** for records with no associated row.
- **Squished heredocs (`<<~SQL.squish`)** for the rare unavoidable SQL.
- **`all` as a receiver is redundant.**

### N+1 and loading
> *Source: [Rails Guides — Active Record Query Interface](https://guides.rubyonrails.org/active_record_querying.html#eager-loading-associations)*

Ten books, each asking for its author, is "1 (to find 10 books) + 10 (one per
each book to load the author) = **11** queries in total." Three tools, with
different mechanics:

| Method | Mechanics | Use when |
|---|---|---|
| `includes` | "ensures that all of the specified associations are loaded using the minimum possible number of queries" — Rails picks | the default choice |
| `preload` | "loads each specified association using one query per association" | you want separate queries guaranteed |
| `eager_load` | "loads all specified associations using a `LEFT OUTER JOIN`" | you must filter or order on the association |

`includes` and `preload` cannot carry conditions on the associated table;
`eager_load` can, because it joins.

- **`strict_loading` proves the absence of an N+1.** "By enabling strict
  loading mode on a relation, an `ActiveRecord::StrictLoadingViolationError`
  will be raised if the record tries to lazily load any association." Use it in
  the spec covering a new listing endpoint — an assertion, unlike a development
  logger that nobody reads.
- **`find_each` / `in_batches` for large sets.** "`Customer.all.each`
  instructs Active Record to fetch _the entire table_ in a single pass", which
  "becomes increasingly impractical as the table size increases". For a
  thousand records the plain finders are fine.
- **When a batched API already exists, wire it** — a loop calling a
  single-record method around an existing bulk one is an N+1 by construction.

```ruby
# Bad — one query per booking, then one per space
Booking.recent.each { |b| puts b.space.name }

# Good
Booking.recent.includes(:space).each { |b| puts b.space.name }

# Good — the spec fails if a new association is touched lazily
it "loads without an N+1" do
  expect { get bookings_path }.not_to raise_error
  Booking.strict_loading.recent.each(&:space)
end
```

---

## Rails: Migrations

> *Source: [Rails Style Guide — Migrations](https://github.com/rubocop/rails-style-guide#migrations), [strong_migrations](https://github.com/ankane/strong_migrations)*

- **`schema.rb` / `structure.sql` stays in version control.**
- **"Enforce default values in the migrations themselves instead of in the
  application layer"**, and give every boolean a default plus `NOT NULL` — a
  three-state boolean is a bug waiting for a `nil`.
- **"Enforce foreign-key constraints"** in the database.
- **Name foreign keys explicitly** rather than relying on generated names.
- **Use `change`, not `up`/`down`**, for constructive migrations, and never put
  a non-reversible command in `change`.
- **Define a local model class inside the migration** if it must use one, so a
  later change to the real model cannot break replay.

### Operations that lock a live table

A migration that is correct on an empty database can take production down.
Each of these blocks reads or writes on a table under load:

| Operation | Why it hurts | Safe pattern |
|---|---|---|
| add a column with a volatile default | "causes the entire table to be rewritten" | add the column, set the default, then backfill |
| backfill in the migration that alters | "keeps the table locked for the duration of the backfill" | `disable_ddl_transaction!`, batch, throttle |
| change a column type | "the entire table to be rewritten... reads and writes are blocked" | new column, dual-write, backfill, move reads, drop old |
| rename a column | "will cause errors in your application" | same multi-step path as a type change |
| remove a column | "Active Record caches database columns at runtime" — the app raises until reboot | `ignored_columns`, deploy, then drop inside `safety_assured` |
| add an index | non-concurrent index creation "blocks writes" | `algorithm: :concurrently` + `disable_ddl_transaction!` |
| add `NOT NULL` | "blocks reads and writes while every row is checked" | unvalidated check constraint, validate, then set `NOT NULL` |
| add a foreign key | "blocks writes on both tables" | add `validate: false`, validate in a second migration |
| add a check constraint | "blocks reads and writes... while every row is checked" | add `validate: false`, then validate |
| add a `json` column | "no equality operator for the `json` column type" | use `jsonb` |

---

## Rails: Time and Zones

> *Source: [Rails Style Guide — Time](https://github.com/rubocop/rails-style-guide#time)*

The application has a configured zone; the process has a system zone. Any call
that reads the second is a bug that appears only for users elsewhere, and only
some of the year.

- **"Don't use `Time.now`. Use `Time.zone.now` or `Time.current`."**
- **"Don't use `Time.parse`"** — `Time.zone.parse`. **"Don't use
  `String#to_time`."**
- **`Date.current`, not `Date.today`.**
- **Prefer `all_day` / `all_week` / `all_month`** to a hand-built range.
- **Use Duration methods** — `2.days.ago`, `30.minutes.from_now` — rather than
  arithmetic on the current time.
- **In specs, `freeze_time`** rather than `travel_to(Time.current)`.

```ruby
# Bad — the server's zone, not the application's
Booking.where("starts_at > ?", Time.now)
Booking.where(created_at: Date.today.beginning_of_day..Date.today.end_of_day)

# Good
Booking.where(starts_at: Time.current..)
Booking.where(created_at: Date.current.all_day)
```

---

## Rails: Views and Helpers

> *Source: [Rails Style Guide — Views](https://github.com/rubocop/rails-style-guide#views)*

- **"Never call the model layer directly from a view."**
- **"Avoid using instance variables in partials, pass a local variable to
  `render` instead."** A partial that reads `@booking` cannot be reused or
  tested.
- **"Avoid complex formatting in the views"** — a helper for simple cases, a
  presenter or serializer once it has branches.
- **Name the view at every serializer render.** A serializer with views
  (Blueprinter's `view:`) renders its default view when none is named, so a
  caller missing it gets fewer fields and nothing fails. Its spec asserts a
  field only the intended view carries; a spec asserting `id` alone passes
  under every view.
- **Mitigate duplication with partials and layouts.**
- **No user-facing strings in views, models or controllers** — I18n keys, with
  lazy lookup (`t('.title')`) inside a view, and dot-separated keys rather than
  a `:scope` array.

For accessibility requirements in markup, `accessibility_guidelines.md` is
mandatory and this guide does not duplicate it.

---

## Background Jobs

> *Source: [Sidekiq — Best Practices](https://github.com/sidekiq/sidekiq/wiki/Best-Practices)*

- **Arguments must be JSON-native** — "string, integer, float, boolean,
  null(nil), array and hash" — because the client uses `JSON.dump` and the
  server `JSON.load`. **"Don't pass symbols, named parameters, keyword
  arguments or complex Ruby objects (like Date or Time!)"**
- **Pass an id, not a record.** Beyond serialisation: "what happens if your
  queue backs up and that quote object changes in the meantime?" The job should
  read the current row.
- **Delivery is at-least-once.** "Sidekiq will execute your job **at least**
  once, not **exactly** once. Even a job which has completed can be re-run."
  Therefore **every job must be idempotent** — a job that creates, charges or
  sends needs a guard, or a retry duplicates the effect.
- **Make the job resilient or transactional.** Use a transaction so a partial
  failure rolls back, or write the body so a second run is a no-op.
- **Design for parallelism** — "Sidekiq is designed for parallel execution so
  design your jobs so you can run lots of them in parallel." Two jobs on the
  same row at once is the normal case, not the exception.
- **Enqueue after the transaction commits**, so the worker cannot start before
  the row it needs is visible.
- **A job with retries disabled gets one attempt.** Then its own failure
  handling is the only thing between an error and silent data loss.

```ruby
# Bad — a Time object and a record; and a retry charges twice
InvoiceJob.perform_async(invoice, Time.current)

def perform(invoice, at)
  gateway.charge(invoice.total)
end

# Good — ids and JSON-native values; the guard makes a retry a no-op
InvoiceJob.perform_async(invoice.id, Time.current.iso8601)

def perform(invoice_id, at)
  invoice = Invoice.find(invoice_id)
  return if invoice.charged?

  invoice.with_lock do
    return if invoice.reload.charged?

    gateway.charge(invoice.total)
    invoice.update!(charged_at: Time.zone.parse(at))
  end
end
```

---

## Security

> *Source: [Rails Security Guide](https://guides.rubyonrails.org/security.html)*

| Risk | Unsafe | Safe |
|---|---|---|
| SQL injection | `where("name = '#{params[:name]}'")` | `where(name: params[:name])`, or placeholders |
| Mass assignment | `params.permit!`, `Model.new(params[:model])` | `params.require(:model).permit(:a, :b)` |
| XSS | `raw(user_text)`, `user_text.html_safe` | escaped by default; `sanitize` with a permitted tag list |
| CSRF | skipping the check to make a form work | `protect_from_forgery with: :exception`, Rails form helpers |
| Command injection | `system("echo #{input}")` | `system("echo", input)` — arguments, not a shell string |
| Unsafe `open` | `Kernel#open(user_path)` | `File.open`, `IO.open`, `URI#open` |
| Open redirect | `redirect_to(params[:referer])` | validate against a permitted list |
| Path traversal | `send_file("/uploads/" + params[:name])` | look the file up by database id |
| Weak anchors | `/^https?:/` | `/\Ahttps?:/` — `^` matches after any newline |

- **`html_safe` and `raw` are assertions you make about a string.** Neither
  escapes anything; both mark the string as already safe. Use them only on
  markup the application itself built.
- **Store uploads outside `public/`**, filter filenames against a permitted
  character list rather than a blocked one, and process media asynchronously.
- **Never store sensitive data in the session** — the cookie store is
  encrypted but still client-held. Invalidate sessions on login, and set an
  expiry.
- **Authorisation is per action, not per controller.** A policy object
  (Pundit) or ability definition (CanCan) keeps the rule testable in isolation;
  a `before_action` that checks a role inline does not. A new action inherits no
  protection by default, so the absence of an authorisation call is the finding.

---

## Where Code Goes

> *Source: [Rails Style Guide — Models](https://github.com/rubocop/rails-style-guide#models)*

"Introduce non-Active Record model classes freely" and "keep your models for
business logic and data-persistence only". Neither a fat model nor a fat
controller is the answer; a third object is.

| Layer | Holds | Never holds |
|---|---|---|
| Controller | HTTP: params, authorisation, status, rendering | business rules |
| Model | persistence, associations, validations, scopes | HTTP, formatting, external calls |
| Service / interactor | one business action, start to finish | rendering, params parsing |
| Policy | may this actor do this | how to do it |
| Query object | one non-trivial query | the decision to run it |
| Serializer / presenter | shaping output | fetching |
| Form object | a multi-model write with its own validations | persistence rules of one model |
| Job | scheduling and retry concerns | the business logic itself, which it calls |

A service object is a class with one public entry point, named for the action
it performs, returning a result the caller can branch on:

```ruby
# Good — one public method, an explicit result, no HTTP knowledge
module Bookings
  class Create
    Result = Data.define(:booking, :errors) do
      def success? = errors.empty?
    end

    def self.call(user:, params:) = new(user:, params:).call

    def initialize(user:, params:)
      @user   = user
      @params = params
    end

    def call
      booking = @user.bookings.build(@params)
      unless booking.save
        return Result.new(booking: nil, errors: booking.errors)
      end

      Result.new(booking:, errors: [])
    end
  end
end
```

Pick one convention for the entry point — `.call` delegating to an instance is
the common one — and apply it to every service in the codebase. Symmetry is the
rule (`style_guidelines.md`); two conventions for the same thing is the debt.

---

## Testing

> *Source: [RSpec Style Guide](https://github.com/rubocop/rspec-style-guide)*

### Structure and naming

- **`describe` names the thing**, using Ruby documentation conventions: `'.'`
  for a class method, `'#'` for an instance method — `describe '#cancel!'`.
- **`context` names the condition**, starting with "when", "with" or "without",
  so description and context read as one sentence.
- **No "should" in an example description.** Write third-person present tense:
  `it 'cancels the booking'`, not `it 'should cancel the booking'`. Keep
  descriptions under about 60 characters, and never end one with a conditional
  — that condition belongs in a `context`.
- **"Every context should have a matching opposite case; a single context
  without negation is a code smell."**
- **Declaration order**: `subject`, then `let!`/`let`, then `before`/`after`.

### Setup

- **`let` rather than instance variables** — scoped, lazy, and overridable in a
  nested context.
- **Don't over-`let`.** "Balance DRY principles with clarity; don't extract
  primitive data prematurely. Start with duplication, then refactor." A spec
  whose setup is spread over four `let`s in three contexts is unreadable.
- **Avoid `before(:all)` / `before(:context)`** — state leaks between examples
  and creates order dependence.
- **Factories, not fixtures**, and **create only the data the example needs**.
  `build` or `build_stubbed` where nothing needs to be persisted.

### Expectations

- **`expect` syntax only**; configure RSpec to reject `should`.
- **One expectation per example**, or `:aggregate_failures` where several
  assert one behaviour — consistently, not case by case.
- **Use the specific matcher**: `be_published` over checking truthiness,
  `include`, `change`, `have_attributes`. Avoid the bare `be`; prefer
  `be_truthy` / `be_falsey` or a type-specific matcher.
- **Test behaviour, not implementation.** Assert the observable outcome, not
  that a private method was called.

### Doubles

- **Verifying doubles** — `instance_double`, `class_double`, `object_double` —
  so a spec breaks when the real method's signature changes. A plain `double`
  will happily stub a method that no longer exists.
- **Never `allow_any_instance_of` / `expect_any_instance_of`.** Stub the
  instance you have.
- **Never stub the object under test.** "Don't stub methods on the object under
  test; this indicates poor design."
- **Stub constants rather than declaring them** in an example group.
- **No `sleep` in a spec.** Control time with `freeze_time` / `travel_to`.

```ruby
# Bad — should-phrasing, instance variable, a double that verifies nothing,
#        two unrelated assertions, and implementation coupling
describe Bookings::Create do
  before(:all) { @user = User.create!(email: 'a@b.c') }

  it 'should create a booking and send mail' do
    gateway = double(charge: true)
    expect_any_instance_of(described_class).to receive(:validate!)
    expect(described_class.call(user: @user, params: {})).to be_success
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end
end

# Good — one behaviour per example, verified double, observable outcome
describe Bookings::Create do
  subject(:result) { described_class.call(user:, params:) }

  let(:user)   { build_stubbed(:user) }
  let(:params) { { space_id: space.id, starts_at: 1.day.from_now } }

  context 'when the space is free' do
    let(:space) { create(:space) }

    it 'returns a persisted booking' do
      expect(result.booking).to be_persisted
    end

    it 'enqueues the confirmation' do
      expect { result }.to change(BookingConfirmationJob.jobs, :size).by(1)
    end
  end

  context 'when the space is already booked' do
    let(:space) { create(:space, :booked) }

    it 'fails with an error on starts_at' do
      expect(result.errors[:starts_at]).to be_present
    end
  end
end
```

---

## Anti-Patterns

Each of these has its rule above; this is the review checklist.

- `rescue Exception`, a bare `rescue`, an empty `rescue` body, or `rescue nil`
  as a modifier.
- An unchecked `save` / `update` — no bang, no branch on the return value.
- `update_all` / `update_column` used for a domain change rather than a
  backfill.
- String interpolation inside `where`, `order`, `pluck` or `find_by_sql`.
- `Time.now`, `Date.today`, `Time.parse`, `String#to_time`.
- A callback that writes another model, calls an external service, or enqueues
  before commit.
- `will_save_change_to_x?` in an `after_*` callback, or `saved_change_to_x?` in
  a `before_*` one.
- A loop that queries — `each` over records touching an unloaded association.
- A Sidekiq job taking a record, a `Time`, a symbol or keyword arguments.
- A job that is not idempotent: creating, charging or sending with no guard.
- `params.permit!`, or `Model.new(params[:model])`.
- `html_safe` or `raw` on anything derived from user input.
- `^` / `$` in a validation regexp.
- A class variable `@@x`.
- A `rubocop:disable` on a metrics cop with no stated reason.
- An instance variable in a partial.
- A controller action with business logic, or more than one instance variable.
- A predicate named `is_x?`, or a `!` method with no safe sibling.
- A spec that stubs the object under test, or uses `any_instance_of`.

---

## Complexity and mutation

> *Source: [Verification](coding_guidelines.md#verification), [lizard](https://github.com/terryyin/lizard), [RuboCop — Metrics/CyclomaticComplexity](https://docs.rubocop.org/rubocop/cops_metrics.html#metricscyclomaticcomplexity), [mutant — licensing](https://github.com/mbj/mutant#licensing)*

`~/.claude/scripts/change_gate.py` holds a change to both bars.

- **No method above cyclomatic complexity 10**, counted by lizard. RuboCop's
  `Metrics/CyclomaticComplexity` defaults to a stricter `Max` of 7, and where a
  project enables it, that bar holds too.
- **Every mutant on a changed line is killed.** mutant, Ruby's standard
  mutation tool, is free only for public open-source code, so the gate uses
  its own mutator: it swaps `<`/`<=`/`>`/`>=`, `==`/`!=`, `&&`/`||`,
  `and`/`or`, `true`/`false`, `if`/`unless`, `.any?`/`.none?` and
  `+ 1`/`- 1` in the code of each changed line, never in a string or a
  comment, and runs the `--test ruby` command for each mutant:
  `--test 'ruby=bundle exec rspec spec/models/user_spec.rb'`. With no
  command, a Ruby change fails the gate.
- **An equivalent mutant is marked on its line:**
  `# mutation: equivalent — <reason>`.

---

## Tooling

> *Source: [RuboCop](https://docs.rubocop.org/), [Brakeman](https://brakemanscanner.org/), [Bullet](https://github.com/flyerhzm/bullet), [strong_migrations](https://github.com/ankane/strong_migrations)*

| Tool | Checks | Note |
|---|---|---|
| `rubocop` | style, layout, metrics, Rails and RSpec cops | with `rubocop-rails`, `rubocop-rspec`, `rubocop-performance` |
| `brakeman` | injection, XSS, mass assignment, unsafe redirects | static; run in CI, not by hand |
| `bundler-audit` | known CVEs in locked gems | |
| `bullet` | N+1s and unused eager loading, at runtime | only sees paths that actually execute |
| `strong_migrations` | migrations that lock a live table | fails the migration, with the safe pattern in the message |
| `rspec` | behaviour | |

- **A project's `.rubocop.yml` decides what CI blocks; this guide decides what
  good Ruby is.** The two are not the same, and where a project's config is
  silent or has grandfathered a cop into a todo file, the rule above still
  holds — it is simply a review finding rather than a build failure.
- **A diff-scoped linter (Pronto) reports only changed lines.** A clean report
  means the lines you touched are clean, never that the file is.
- **`bullet` cannot prove the absence of an N+1** — it observes. An assertion
  (`strict_loading`) can.

---

## Sources

- [Ruby Style Guide](https://rubystyle.guide/) — the community style guide,
  the basis of RuboCop's defaults
- [Rails Style Guide](https://github.com/rubocop/rails-style-guide) — the
  Rails companion to the community guide
- [RSpec Style Guide](https://github.com/rubocop/rspec-style-guide)
- [Rails Guides](https://guides.rubyonrails.org/) — in particular
  [Security](https://guides.rubyonrails.org/security.html),
  [Active Record Querying](https://guides.rubyonrails.org/active_record_querying.html),
  [Active Record Callbacks](https://guides.rubyonrails.org/active_record_callbacks.html),
  [Active Record Validations](https://guides.rubyonrails.org/active_record_validations.html)
- [Rails API documentation](https://api.rubyonrails.org/) — in particular
  [`ActiveRecord::AttributeMethods::Dirty`](https://api.rubyonrails.org/classes/ActiveRecord/AttributeMethods/Dirty.html)
- [Sandi Metz's rules for developers](https://thoughtbot.com/blog/sandi-metz-rules-for-developers)
- [Sidekiq Best Practices](https://github.com/sidekiq/sidekiq/wiki/Best-Practices)
- [strong_migrations](https://github.com/ankane/strong_migrations) — the
  catalogue of migrations that lock a table
- [paranoia](https://github.com/rubysherpas/paranoia) — soft deletes
- [Blueprinter](https://github.com/procore-oss/blueprinter) — serializer views
- [The Rails Doctrine](https://rubyonrails.org/doctrine)
- [Ruby documentation](https://docs.ruby-lang.org/en/master/) — in particular
  [`Data`](https://docs.ruby-lang.org/en/master/Data.html) and
  [pattern matching](https://docs.ruby-lang.org/en/master/syntax/pattern_matching_rdoc.html)

For updates, refer to the original sources as Ruby and Rails conventions
evolve.

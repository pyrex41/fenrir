# Fenrir surface syntax

Draft 3 • 16 November 2026 • For owner review

**Status.** A first frontend, written in Shen, so that a Fenrir program can be
written as text, run, and its result seen. Every choice of spelling below is a
proposal for the owner to confirm or change (§8 lists them). Nothing here is
qualified, and nothing here adds to the language: the frontend translates text
into an artifact of schema `tc1-handler-demo/2` (contract
[EFFECTS.md](EFFECTS.md), slice TC1-H2), or of schema `tc1-handler-demo/3`
(slice TC1-R1) when the program declares a remote effect. What a program means
is decided by the Shen model; whether an artifact is well formed is decided by
the validator `tools/tc0/pure-call-artifact.mjs`. Draft 2 adds the remote
effect class of EFFECTS.md draft 7 (owner rulings of 16 November 2026 on
questions 7 and 9 of its §12.10): `remote-effect`, `read-only`, the type
`(Remote T)` and its three outcomes. Draft 3 follows EFFECTS.md draft 8
(owner rulings of the same day on questions 11, 12, 14 and 16 of its §12.10):
a remote perform is written only as the value a `match` takes apart
(must-use, §2), and the type `(Remote T)` is no longer written at all; the
rejection of `(handle E ...)` for a remote effect is confirmed; and the
member an effect goes to is stated in the system manifest. Every program
that was accepted and is still accepted elaborates to the same bytes as
before; one test program that passed outcomes around is now rejected.

```sh
sh frontend/fenrir.sh check FILE.fen           # elaborate and validate
sh frontend/fenrir.sh run FILE.fen             # check, then run on the Shen model
sh frontend/fenrir.sh emit FILE.fen OUT.json   # check, then write the artifact
sh frontend/test.sh                            # the frontend's tests, about a minute
```

`run` prints each emitted value in order, the outcome, where a trap arose, and
the number of model steps:

```text
$ sh frontend/fenrir.sh run examples/transaction.fen
emit "begin": unit
emit "write": 20
emit "write": 22
emit "commit": 42
outcome: Ok 42
steps: 74
```

## 1 Grammar card

```text
program  ::= form...
form     ::= (datatype Name constructor...)            constructor ::= Name | (Name type...)
           | (effect Name (operation type --> type)...)
           | (remote-effect Name remote-operation...)
           | (define name {type --> type} parameter... -> e)

remote-operation ::= (operation type --> type)             keyed: performed with a request key
                   | (read-only operation type --> type)   no key; changes nothing at the peer

type     ::= Unit | Bool | I64 | Bytes | TrapCode | Name      a declared datatype
           | (Tuple type...)                                  1 to 8 components
           | (type --> type)                                  a function with no effects
           | (type --> type ! Effect...)                      a function with exactly these effects

e        ::= unit | true | false | 42 | -7 | #x68ff | "text"
           | name                                  a variable
           | Name | (Name e...)                    a constructor, without or with fields
           | (let name e ... e)                    name e pairs, then the body
           | (do e ... e)                          in order; the value of the last
           | (if e e e)
           | (tuple e...)   | (project e index)    index a literal, from 0
           | (match e arm...)                      arm ::= (Name -> e) | ((Name name...) -> e)
           | (match (perform Effect operation e...) ((Reply x) -> e) (NotDelivered -> e) (TimedOut -> e))
                                                   Effect remote: the only place such a perform may stand
           | (lambda (name : type) e)
           | (name e...)                           call a function, or apply a variable
           | (e e...)                              apply the value of an expression
           | (type e type)                         e, held against the type
           | (+ e e) | (- e e) | (* e e) | (/ e e) | (neg e)
           | (< e e) | (<= e e) | (> e e) | (>= e e) | (= e e) | (not e)
           | (bytes-length e) | (bytes-index e e) | (bytes-concat e e)
           | (emit "label" e)
           | (perform Effect operation e...)       Effect ordinary. Remote: only as above; keyed: (perform Effect operation key e)
           | (handle Effect clause... e)           clause ::= ((operation name) -> e)
                                                            | ((operation name k) -> e)
           | (resume k e) | (discontinue k)

\\ starts a comment that runs to the end of the line.
```

Words are separated by white space and brackets. `Name` starts with an
uppercase letter and continues with letters, digits or `_`: datatypes,
constructors and effects. `name` starts with a lowercase letter or `_`:
functions and variables, which may also contain `-`, and operations, which
may not. `_` alone is a binder that names nothing. The words of the grammar
(`let`, `if`, `handle`, `unit`, `not`, `remote-effect`, `read-only`, ...) cannot
be used as names.

## 2 What the forms mean

Each form is one construct of the artifact, or is defined by rewriting into
them. There is no other meaning.

| Surface | Artifact |
| --- | --- |
| `42`, `-7` | `int`, the decimal text. Leading zeros and `-0` are normalized |
| `#x68ff` | `bytes`, lowercase hex |
| `"text"` | `bytes`, the UTF-8 octets of the text. Escapes: `\\`, `\"`, `\n` |
| `Name`, `(Name e...)` | `construct` with the datatype that declares the constructor |
| `(let x a y b body)` | `let x = a in let y = b in body`; later bindings see earlier ones |
| `(do a b c)` | `let _ = a in let _ = b in c`, with fresh binders |
| `(f a)` with `f` a function | `call` |
| `(x a)` with `x` a variable, `(e a)` | `apply` |
| `(f a b)`, `(x a b)`, `(perform E op a b)` | the same with the one argument `tuple(a, b)` |
| `(define f {(Tuple A B) --> C} a b -> e)` | parameter `p`, body `let a = project(p,0) in let b = project(p,1) in e` |
| `(type e T)` | `e` itself: no node. See §3 |
| `+ - * / neg < <= > >= not` | `prim` `add sub mul div neg lt le gt ge not` |
| `=` | `prim eq` |
| `bytes-length`, `bytes-index`, `bytes-concat` | `prim` `bytes_length`, `bytes_index`, `bytes_concat` |
| `(handle E clause... body)` | `handle(E, [clause]..., body)`, clauses in the order written |
| `((op x) -> e)` | the tail-resumptive clause `op(x) => e` |
| `((op x k) -> e)` | the clause `op(x, k) => e` with its one-shot resumption |
| `(remote-effect E (op A --> B) (read-only op2 C --> D))` | an effect declaration of class `remote`, with `read_only` false on `op` and true on `op2`; every `(effect ...)` of the same program gets class `ordinary` |
| `(perform E op k a)`, E remote, `op` keyed | `perform(E, op, tuple(k, a))`: the request key is the first argument |
| `(perform E op2 a)`, `op2` read-only | `perform(E, op2, a)`: no key |
| `(match (perform E op ...) arms)`, E remote | `match` with the `perform` node as its scrutinee; the perform has the type `["Remote", B]`, which is written nowhere |
| `Reply`, `NotDelivered`, `TimedOut` in a match arm | the constructors `reply`, `not_delivered`, `timed_out` |

Operands are written, and evaluated, left to right. Arithmetic is checked I64:
a result out of range traps `Overflow`, division by zero traps `DivZero`, a bad
`bytes-index` traps `Bounds`.

**Names.** A variable is visible in the rest of its `let`, in its match arm,
clause, lambda or function body, and may shadow an outer one. Functions,
datatypes and effects may be declared in any order and functions may be
mutually recursive. A local variable hides a function of the same name.
Constructor names must be unique across the datatypes of a program, and the
constructors of the built-in `TrapCode` (`Overflow`, `DivZero`, `Bounds`,
`InvalidDuration`, `TaskLimit`, `ChildFailed`) are always declared.

**Entry.** The program runs `main`, which must have type `{I64 --> T}` with `T`
serializable, with input 0 (the harness's fixed input). Every ordinary effect
must be handled by the time control reaches `main`'s caller: `main`'s effect
set may contain only `Emit` and remote effects.

**Remote effects** (EFFECTS.md §3, §12.2). `(remote-effect Ledger (add I64 -->
(Tuple I64 I64)) (read-only total Unit --> I64))` declares an effect whose
operations another image carries out. The types written are the peer's: `add`
takes an `I64` and gives a `(Tuple I64 I64)`.

- A perform of a remote operation gives one of three outcomes, which a
  `match` takes apart with the arms `((Reply x) -> e)`, `(NotDelivered -> e)`
  and `(TimedOut -> e)`, in any order, `x` having the operation's result
  type. As for every match, all arms are required. Nothing else takes an
  outcome apart, and a program cannot make one: `Reply`, `NotDelivered` and
  `TimedOut` are not constructors a program can apply. They are resolved by
  the type of what is matched, so a program may have constructors of its own
  with these names.
- **Must-use** (EFFECTS.md §3; owner ruling of 16 November 2026). A remote
  perform is written in one place only: as the scrutinee of a `match`,
  `(match (perform Ledger total unit) ...)`, the perform form itself. That
  match may stand wherever an expression may. Anywhere else the perform is
  rejected, at its own position: bound by `let` (even when the next line
  matches the variable), an element of `do`, a component of a tuple, the
  body of a function or lambda, an argument, an operand of `=`, or the
  scrutinee wrapped in an `if` or a `let`. The message says what to write instead. An arm may be
  `(TimedOut -> unit)`: the rule asks that each outcome is decided in the
  text, not that the decision is a good one.
- The type of an outcome, written `(Remote T)` in messages, **cannot be
  written in a program**: not in a signature, a lambda parameter, a datatype
  field, an operation or `(type ...)`. With the rule above no value of it
  could reach such a place. So a helper cannot take or return an outcome;
  it takes the reply's value, and the function that performs also matches.
- An operation that is not read-only is performed with its request key first:
  `(perform Ledger add 7 5)` is key 7, argument 5, by the rule that several
  arguments are one tuple. A read-only operation has no key:
  `(perform Ledger total unit)`.
- `(handle Ledger ...)` is rejected: no handler discharges a remote effect
  (confirmed by the owner, 16 November 2026).
- `main` may leave a remote effect unhandled. Such a program is not run by
  `sh frontend/fenrir.sh run`, which has no peer to ask and says so with exit
  status 2; `check` and `emit` work, and
  [examples/remote/ledger-caller.fen](../../examples/remote/ledger-caller.fen)
  is the program of the caller image of `sh harness/run-tc1-remote-run.sh`,
  built from that file.
- A program that declares a remote effect cannot declare a datatype named
  `RemoteResult`, the name the outcome values carry.
- Which member an effect's operations go to is not in the source: the system
  manifest binds each remote effect of a caller to a member (EFFECTS.md
  §12.6; owner ruling of 16 November 2026).

**Identity.** Every expression node and every function gets a decimal ID in
source order and a source-map row with the file as named on the command line
and the line and column (from 1, in characters) of the form it came from. A
node made by sugar has the position of the text that caused it. The module
name is the file name without directory and `.fen`. `emit` writes the
canonical encoding, so the artifact's SHA-256 is that of the file.

## 3 What is written and what is inferred

Written by the programmer:

- the argument and result type of every `define`;
- the parameter type of every `lambda`;
- field types of constructors and the argument and result type of operations,
  and for an operation of a remote effect whether it is read-only;
- the effect set of a function *type*, wherever a type is written: `(A --> B)`
  means no effects, `(A --> B ! E F)` means exactly `E` and `F`.

Inferred:

- the type of every expression and `let` variable;
- the result type of every `lambda`;
- **the effect set of every `define`**: the least sets such that each
  function's set contains what its body can perform, where a call contributes
  the callee's set, an application the set in the function's type, `perform`
  its effect and `emit` the effect `Emit`, and `handle E` removes `E` from its
  body's effects and adds its clauses'. For recursive and mutually recursive
  functions this is computed by iteration from empty sets;
- **the effect set of every `lambda`**, in one of two ways. Where the context
  wants a function type whose parameter type is the lambda's (a function
  argument, a constructor field, the result of a `define`, the body of a
  lambda that is itself wanted at such a type, a `(type e T)`), the lambda
  takes that type's result and effect set, and its body may perform fewer
  effects but not others. Anywhere else (for instance bound by `let`), it gets
  exactly the effects of its body.

The artifact has no subtyping: two function types are the same only with the
same effect set. So a lambda bound by `let` and then passed where a larger
effect set is wanted is a type mismatch; write the lambda at the place it is
passed, or state its type with `(type (lambda ...) (A --> B ! E))`.

The expected type also flows into the body of `let` and `do`, the branches of
`if`, the arms of `match`, the components of a `tuple`, and the body of
`handle`. An `if` or `match` with no expected type takes the type of its first
branch, and the others are held against it.

Limits of the inference, stated plainly. It finds the *least* effect sets. In
a contrived program a lambda's set can depend on its own function's set in a
way that only a larger, non-least choice would type; such a program is
rejected with a type mismatch, and `(type ...)` resolves it. While the sets
are being computed, function types that differ only in effect set are joined;
the pass that produces the artifact then checks every type exactly. There is
no proof that this procedure agrees with the validator's rules. The validator
runs on every artifact produced, and the frontend treats a disagreement as its
own defect (exit status 3).

## 4 Resumptions

A clause `((op x k) -> e)` names its resumption. As in EFFECTS.md §7, `e` has
the type of the `handle`, `(resume k v)` has the type of the `handle` and
gives back what the handled body finally produced, and `(discontinue k)` has
type `Unit`. The frontend checks the one-shot rule and reports which rule a
program breaks:

- every path through the clause uses `k` exactly once, by one `resume` or one
  `discontinue`; the branches of an `if` and the arms of a `match` must agree;
- `k` is not a value;
- `k` cannot be used inside a `lambda`, or inside a clause of another handler
  (it can be used in the *body* of an inner `handle`).

## 5 Errors

A rejected program gives one message, the first problem found, on standard
error as `FILE:LINE:COLUMN: error: MESSAGE`, with exit status 1. The messages,
by what they name (`tests/frontend/bad/` has programs for each kind, not for
every message):

| Kind | Message says |
| --- | --- |
| Brackets and literals | which `(` or `{` is never closed, or closed by the wrong bracket; a `)` with no `(`; a string not closed on its line; an unknown escape; a word that is not an integer; an integer outside I64; a bytes literal with an odd digit count |
| Shape of a form | how the form is written, for example `lambda is written (lambda (x : Type) body)` |
| Names | unknown name, type, effect or operation (listing the effect's operations); a name declared twice; a constructor declared by two datatypes; a reserved word or a wrongly capitalised name used as a name; a function used as a value; a variable bound twice in one pattern |
| Types | `WHAT has type FOUND, but EXPECTED is expected`, where WHAT is the role (the condition of if, operand 2 of +, the argument of f, field 1 of Some, the body of f, the else branch, this match arm, the clause for E.op, the value resumed with), followed where useful by where the expectation comes from |
| Arity | operands of an operator, fields of a constructor, binders of a match arm, parameters against a tuple type, a call with no argument |
| Data | `project` of a non-tuple or with an index out of range; `match` on a non-datatype; a match that is not exhaustive (naming the missing constructors), has two arms for one constructor, or an arm for a constructor of another type; `=` or `emit` on a value containing a function |
| Effects | an ordinary effect that reaches `main` unhandled, at the perform, call or application it comes from; a handler with a clause missing or given twice; an effect in a lambda whose wanted type does not allow it; an operation type that is not serializable |
| Remote effects | a `handle` of a remote effect; a keyed operation performed without its key, or a read-only one with a key (as a type mismatch that says why); a remote perform that is not the scrutinee of a match (must-use: bound, dropped, stored, returned, passed, compared, or reached through an `if`), at the perform; `(Remote T)` written as a type; a match on an outcome without all three arms; `Reply`, `NotDelivered` or `TimedOut` used to make a value; `read-only` in an ordinary effect; a datatype named `RemoteResult` beside a remote effect |
| Resumptions | never used; used twice on a path (at the second use); branches that disagree; used as a value; used inside a lambda or another handler's clause; `resume` or `discontinue` of something that is not a resumption |
| Entry | no `main`; `main` not taking `I64`; `main` returning a function |
| Size | the validator's caps: 200 expression nodes, nesting depth 64, 256 octets in a bytes literal. This message has no position |

Other exit statuses: 2 for usage, an unreadable file, or `run` of a program
that leaves a remote effect to the system, 3 for a defect in the
frontend (including a validator rejection of what the elaborator accepted), 4
when a run exhausts its step budget (`FENRIR_FUEL`, default 100000). A trap is
an outcome, with status 0.

## 6 Not supported

- Anything outside schemas `tc1-handler-demo/2` and `/3`: tasks, scopes, channels, time,
  resources, multi-shot resumption, polymorphism, effect-row polymorphism,
  modules and imports.
- Running a program that performs a remote operation: there is no peer here.
  A stub for one would need either a handler for the remote effect, which the
  contract rejects, or a manifest that binds the effect to a stub member.
- Naming the member a remote effect is bound to: that is the manifest's.
  Operations of a remote effect that share a declaration between two
  programs (no modules).
- An outcome as a value: naming one, passing it to a helper, returning it.
  EFFECTS.md §3 says what a linear type for outcomes would allow later.
- Patterns beyond one constructor per arm: no wildcard arm, no nested
  patterns, no literal patterns, no tuple patterns (use `project`, or several
  parameters on a `define`).
- A function name as a value: wrap it in a lambda.
- Lambdas with several parameters; operators with more than two operands;
  `and`/`or` (the artifact has none; `if` expresses them).
- Qualified constructor names: hence the uniqueness rule in §2.
- An entry input other than `I64` 0; the validator would allow any
  serializable input type, the harness supplies only this one.
- Emit labels outside printable ASCII. A label is otherwise any text; the
  Solo5 guest's lowering additionally wants `[A-Za-z_][A-Za-z0-9_-]{0,63}`.
- More than one error per run; warnings (an unused variable, a clause that
  could be tail-resumptive); a formatter.
- Programs over the validator's caps (§5, Size). They are the validator's
  defaults and the frontend does not raise them.
- Source text is not checked to be valid UTF-8.

## 7 What is checked

`sh frontend/test.sh`, development evidence only:

- 12 accepted programs (8 under `examples/`, 4 under
  `tests/frontend/programs/`) elaborate, pass the validator, run on the model
  and give the outcome and emissions written in their headers.
- 3 programs that declare a remote effect (1 under `examples/remote/`, 2 under
  `tests/frontend/remote/`) check, and elaborate twice to the same bytes of
  schema `tc1-handler-demo/3`. One performs nothing remote and runs to the
  outcome in its header; the other two leave their remote effect to the
  system, and `run` refuses them with status 2. One of those two,
  `outcomes-matched-in-place.fen`, has a remote perform matched in a
  function, in a lambda's callee, in a `do`, in an arm of another match and
  as an operand, with arms that do nothing. The example of
  `examples/remote/` elaborates to the bytes it had before the must-use rule.
- 89 wrong programs under `tests/frontend/bad/`, 20 of them about remote
  effects, are each rejected with the
  stated message at the stated line and column. The positions were recorded
  from the elaborator's output after reading each one against its program;
  they are regression expectations, not independent predictions (two were
  predicted by hand first, and one of those predictions was a miscount).
  Eleven are about must-use: an outcome bound by `let` and matched, dropped
  in a `do`, bound to `_`, put in a tuple, returned by a function, returned
  by a lambda, passed to a function, used as an operand, compared with `=`,
  reached through an `if` in the scrutinee, and the type `(Remote T)`
  written in a signature. One is a `handle` of a remote effect.
- 27 hand fixtures (17 of `fixtures/tc1`, 10 of `fixtures/tc0`) rewritten in
  surface syntax under `tests/frontend/roundtrip/`: the elaborated artifact
  has the fixture's outcome and emissions on the model, and is the fixture's
  program up to a renaming of IDs.
- Elaborating each example twice gives the same bytes.
- The 8 examples, elaborated, run in the Solo5 guest and agree with the model
  step for step; the guest's two injected defects are detected on them. Both
  sides stop at 200 steps, so `bytes`, `early-exit` and `list-sum` are compared
  over their first 200 steps only.

Not checked: any property of the inference beyond these programs; that the
elaborator rejects everything the validator rejects (the driver catches the
difference at run time instead); the reader on malformed UTF-8. The
elaborator, its tests and this document have one author.

## 8 For the owner to confirm

1. Shen-style `define` with the signature in braces, one clause, `->` before
   the body; `-->` in types and `->` in clauses and arms.
2. Lowercase variables, against Shen's convention, because Fenrir's
   constructors and types are capitalised; the capitalisation rule is enforced.
3. `(handle Effect clause... body)`: the contract's order, body last, like
   `let`. The alternative is body first.
4. `(perform Effect operation e)` names the effect each time. Calling the
   operation like a function would be shorter and needs a rule for an
   operation name declared by two effects.
5. `lambda` with a typed binder `(x : T)`; Shen's `/.` would be a one-word
   change.
6. Effect sets in types as `(A --> B ! E F)`.
7. `(Tuple A B)`, `(tuple a b)`, `(project e 0)`, rather than Shen's `*`, `@p`.
8. A string literal is `Bytes`; `#x...` for octets.
9. Several arguments mean one tuple, for calls, applications and performs.
10. `(type e T)` as the annotation form, after Shen's.
11. Symbols for arithmetic and comparison (`+`, `<=`, `=`), words for the rest.
12. `main : {I64 --> T}` as the entry, with input 0.
13. One error per run.
14. `(remote-effect Name ...)` as a form of its own, beside `effect`. The
    alternative is a marker inside `effect`.
15. `read-only` as a prefix word inside the operation, `(read-only total Unit
    --> I64)`.
16. The declaration states the peer's types and the key is not part of them:
    `(add I64 --> ...)` is performed as `(perform Ledger add key argument)`.
    The alternative writes the caller's view, `(add (Tuple I64 I64) --> ...)`.
17. `Reply`, `NotDelivered`, `TimedOut` as the names of the outcomes in a
    match, capitalised like every constructor; the artifact and the machines
    say `reply`, `not_delivered`, `timed_out`. *Decided in part, 16 November
    2026:* this item also proposed `(Remote T)` as a type a program writes.
    By the ruling on must-use (EFFECTS.md §12.10 question 11) and the rule
    that carries it out, the type is not written any more; the spelling
    survives in messages only. The three names are still to confirm.
18. `run` refuses a program that leaves a remote effect to the system, with
    status 2, and does not offer a stub. *Decided in part, 16 November 2026:*
    no handler stands in for a remote effect (ruling on question 16), so a
    stub is not something a program or this command can supply; with the
    binding in the manifest (question 14) it would be a member. The refusal
    and its status are still to confirm.
19. New with draft 3, from how the must-use ruling was carried out, for the
    owner to confirm or loosen: `(let o (perform E op a) (match o ...))` is
    rejected though the ruling would allow it, and an arm may do nothing,
    `(TimedOut -> unit)`.

Items 14, 15 and 16 are not touched by the rulings of 16 November 2026 on
questions 11, 12, 14 and 16 and stay as listed. Question 12 (each read-only
perform is its own request) has no surface spelling.

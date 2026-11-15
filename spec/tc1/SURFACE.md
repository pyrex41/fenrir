# Fenrir surface syntax

Draft 1 • 15 November 2026 • For owner review

**Status.** A first frontend, written in Shen, so that a Fenrir program can be
written as text, run, and its result seen. Every choice of spelling below is a
proposal for the owner to confirm or change (§8 lists them). Nothing here is
qualified, and nothing here adds to the language: the frontend translates text
into an artifact of schema `tc1-handler-demo/2` (contract
[EFFECTS.md](EFFECTS.md), slice TC1-H2). What a program means is decided by the
Shen model; whether an artifact is well formed is decided by two validators that
must agree: the JavaScript validator `tools/tc0/pure-call-artifact.mjs`, and the
Shen one of `typing/`, which checks the structural rules and then accepts the
artifact only when the fixed checker accepts a typing derivation for it under the
rules of [TYPING.md](TYPING.md).

```sh
sh frontend/fenrir.sh check FILE.fen           # elaborate and validate (both validators)
sh frontend/fenrir.sh run FILE.fen             # check, then run on the Shen model
sh frontend/fenrir.sh emit FILE.fen OUT.json   # check, then write the artifact
sh frontend/test.sh                            # the frontend's tests, about 75 seconds
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
           | (define name {type --> type} parameter... -> e)

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
           | (lambda (name : type) e)
           | (name e...)                           call a function, or apply a variable
           | (e e...)                              apply the value of an expression
           | (type e type)                         e, held against the type
           | (+ e e) | (- e e) | (* e e) | (/ e e) | (neg e)
           | (< e e) | (<= e e) | (> e e) | (>= e e) | (= e e) | (not e)
           | (bytes-length e) | (bytes-index e e) | (bytes-concat e e)
           | (emit "label" e)
           | (perform Effect operation e...)
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
(`let`, `if`, `handle`, `unit`, `not`, ...) cannot be used as names.

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
serializable, with input 0 (the harness's fixed input). Every user effect must
be handled by the time control reaches `main`'s caller: `main`'s effect set may
contain only `Emit`.

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
- field types of constructors and the argument and result type of operations;
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
no proof that this procedure agrees with the validators' rules. Both validators
run on every artifact produced: the JavaScript one, and the Shen one, which
searches for a derivation of the artifact under the rules of
[TYPING.md](TYPING.md) (Shen's sequent machinery, `typing/search.shen`) and
accepts only when the small fixed checker `typing/checker.shen` accepts that
derivation. What the inference concludes is thereby justified to the checker,
as the amendment (§3, "Programmable typing, fixed checking") requires: the
claim for an accepted program is "derivable under rule set R, soundness not
yet proved". The frontend treats a rejection of what it produced, and any
disagreement between the two validators, as a defect (exit status 3). An
exhausted search budget is UNKNOWN and is never acceptance.

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
| Effects | an effect that reaches `main` unhandled, at the perform, call or application it comes from; a handler with a clause missing or given twice; an effect in a lambda whose wanted type does not allow it; an operation type that is not serializable |
| Resumptions | never used; used twice on a path (at the second use); branches that disagree; used as a value; used inside a lambda or another handler's clause; `resume` or `discontinue` of something that is not a resumption |
| Entry | no `main`; `main` not taking `I64`; `main` returning a function |
| Size | the validator's caps: 200 expression nodes, nesting depth 64, 256 octets in a bytes literal. This message has no position |

Other exit statuses: 2 for usage or an unreadable file, 3 for a defect in the
frontend (including a validator rejection of what the elaborator accepted, and
the two validators disagreeing), 4
when a run exhausts its step budget (`FENRIR_FUEL`, default 100000). A trap is
an outcome, with status 0.

## 6 Not supported

- Anything outside schema `tc1-handler-demo/2`: tasks, scopes, channels, time,
  resources, multi-shot resumption, polymorphism, effect-row polymorphism,
  modules and imports.
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
  `tests/frontend/programs/`) elaborate, pass both validators, run on the model
  and give the outcome and emissions written in their headers. Every artifact a
  test elaborates or runs is judged by both validators; the Shen side's typing
  files are compiled once into a heap image under `build/typing/` (keyed by
  their contents and the Shen/JIT build), which keeps the added cost to about
  0.05 s a run: the suite took about 59 s before the Shen checker was wired in
  and about 75 s after, Solo5 skipped in both.
- 69 wrong programs under `tests/frontend/bad/` are each rejected with the
  stated message at the stated line and column. The positions were recorded
  from the elaborator's output after reading each one against its program;
  they are regression expectations, not independent predictions (two were
  predicted by hand first, and one of those predictions was a miscount).
- 27 hand fixtures (17 of `fixtures/tc1`, 10 of `fixtures/tc0`) rewritten in
  surface syntax under `tests/frontend/roundtrip/`: the elaborated artifact
  has the fixture's outcome and emissions on the model, and is the fixture's
  program up to a renaming of IDs.
- Elaborating each example twice gives the same bytes.
- The 8 examples, elaborated, run in the Solo5 guest and agree with the model
  step for step; the guest's two injected defects are detected on them. Both
  sides stop at 200 steps, so `bytes`, `early-exit` and `list-sum` are compared
  over their first 200 steps only.

- `sh typing/run.sh` elaborates the 39 programs above (examples, programs,
  round trips) and finds that both validators accept every one, with a checked
  derivation for each; `tests/typing/datatype-field-effect.fen` is a program the
  contract allows that the JavaScript validator rejects, so `check` reports the
  validators disagreeing ([TYPING.md](TYPING.md) §11).

Not checked: any property of the inference beyond these programs; that the
elaborator rejects everything the validators reject (the driver catches the
difference at run time instead); the reader on malformed UTF-8; the soundness
of TYPING.md's rules. The elaborator, its tests and this document have one
author.

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

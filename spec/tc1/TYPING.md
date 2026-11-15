# TC1 typing rules

Draft 1 • 15 November 2026 • For owner review

**Status.** The typing and effect rules of artifact schema `tc1-handler-demo/2`
and its subsets (`tc1-handler-demo/1`, `tc0-a-pure-call-demo/1` and `/2`),
written as named inference rules, together with the structural checks that are
not typing. Nothing here is qualified. The rules restate what
[EFFECTS.md](EFFECTS.md) §1–§3 and §7 and
[02_TINY_LANGUAGE_CORE.md](../../02_TINY_LANGUAGE_CORE.md) §2–§4 say, in the
form the amendment asks for ([04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md)
§3, "Programmable typing, fixed checking"); where those texts are silent the
rule follows the JavaScript validator and says so.

**The claim, exactly.** For a program the Shen side accepts: *derivable under
rule set R, soundness not yet proved*, where R is the set of rules in §4–§6
below. No soundness theorem for R exists: not that well-typed programs do not
get stuck, not that the one-shot judgment of §7 implies one resumption at run
time. §11 lists the bounded evidence there is.

## 1 What validation is

An artifact is accepted when

1. it passes every **structural check** of §2, and
2. a **derivation** (§8) is given whose root concludes `well-typed(A, v)` for
   this artifact A and entry input v, and every node of which is an instance of
   a rule of R, as decided by the **fixed checker** `typing/checker.shen`.

Where the derivation comes from does not matter. `typing/search.shen` finds one
with Shen's own sequent machinery (§9); it is untrusted, and a derivation it
builds counts for nothing until the checker accepts it. A search that finds
nothing, or runs out of its budget, means the program is not accepted:
**unknown is never permission**. Extensions (new search rules, strategies,
elaboration) make derivations easier to find; they cannot change what the
checker accepts.

```sh
sh typing/run.sh                       # the differential and checker evidence of §11
sh frontend/fenrir.sh check FILE.fen   # elaborate, then both validators (SURFACE.md §3)
```

The second implementation, `tools/tc0/pure-call-artifact.mjs`, a direct
monomorphic checker in JavaScript, stays as it is: its value is that it was
written independently.

## 2 Structural checks (not typing)

Checked by `typing/structure.shen` before any typing, in this order. A failure
is `invalid` with the check's name; a cap is `limit`, which is not a judgement
of the program (02 §2: "Validator size/work caps yield ValidationLimit, not
acceptance").

| Check | Condition |
| --- | --- |
| S-Transport | UTF-8 JSON with no BOM, no numeric token, no duplicate decoded key, object keys `[A-Za-z_][A-Za-z0-9_]*`, valid escapes and no unpaired surrogate (02 §2). Noncanonical spelling and whitespace are accepted and decoded, as the JavaScript decoder does |
| S-Shape | Every object closed with exactly its fields (artifact, datatype, constructor, effect, operation, function, input schema, source-map row); each field of the right kind (string, array); identifiers `[A-Za-z_][A-Za-z0-9_]*` of at most 64 characters for datatype, constructor, effect and operation names; every expression an array `[tag, id, ...]` with a tag of the schema and its arity: `unit` 0, `bool` `int` `bytes` `var` 1, `let` `if` 3, `prim` an operator of the schema with its operand count (data operators and `eq` only with data), `tuple` 1–8 operands, `project` 2 with an unsigned index, `construct` at least 2, `match` a scrutinee and at least one arm `[C, [x...], e]`, `emit` 2 with a string label, `lambda` 6 with an empty capture list, `apply` 2, `call` 2 with a string name, `perform` 3, `handle` 3 with an array of clauses `[op, x, e]` (or `[op, x, k, e]` under `/2`), `resume` 2 and `discontinue` 1 with an unsigned binder ID; every effect set an array of strings; every ID an unsigned decimal string |
| S-Identity | contract, schema and slice are one of `0.2 / tc0-a-pure-call-demo/1 / TC0-A`, `0.2 / tc0-a-pure-call-demo/2 / TC0-A`, `tc1-draft-1 / tc1-handler-demo/1 / TC1-H1`, `tc1-draft-1 / tc1-handler-demo/2 / TC1-H2` |
| S-Features | datatype declarations only with data (`/2` and TC1); effect declarations only in TC1 |
| S-Declarations | at most 16 datatypes, names not `Unit Bool I64 Bytes TrapCode` and unique; 1–16 constructors each, unique within their datatype; at most 8 fields; at most 8 effects, names not `Emit Task Channel Time Resource` and unique; 1–8 operations each, unique within their effect; 1–32 functions with unique names (any string) |
| S-Unique-IDs | function IDs, parameter IDs, expression node IDs and every binder (let, match, lambda, clause, resumption) one set, no ID twice |
| S-Source-Map | one row `{id, file, line, column}` for every function and expression node and no other, with unsigned id, line and column |
| L-Nodes | at most 200 expression nodes in all, and nesting depth at most 64 below a function body (one validator message, "AST cap", for both) |
| L-Type-Depth | type nesting (Arrow, and Tuple with data) at most 16 in any declared or annotated type |
| L-Bytes | a well-formed bytes literal or value of at most 256 octets |
| L-Values | at most 1000 value nodes in literals and the input. Unreachable while the node cap and the fixed input `["int","0"]` hold |
| L-Encoding | transport at most 1 MiB, JSON depth 128, 100,000 JSON values |

Not checked anywhere, because nothing depends on it: canonical byte order of
the transport (the frontend separately requires its own output to be
canonical, SURFACE.md §2); the order of source-map rows.

The checker relies on S-Unique-IDs for one thing: contexts never bind an ID
twice, so a context lookup is unambiguous.

## 3 Types, effect sets, values and side conditions

```text
T ::= Unit | Bool | I64                     every schema
    | Bytes | TrapCode                       with data (/2, TC1)
    | Tuple(T1..Tn)  1 <= n <= 8             with data
    | Data(D)        D declared              with data
    | Arrow(T1, T2, ε)                       a function type with effect set ε
ε ::= [E1, ..., En]                          a list of effect names
Γ ::= x1 : T1, ..., k : Resumption(B, T), ...   a context; Resumption is not a type
K ::= [n1, ..., nm]                          the use sites (resume / discontinue node IDs) of a resumption
```

Side conditions are decidable predicates and functions, each defined by
structural recursion on a finite type, effect set, value, list or context:

| Name | Meaning |
| --- | --- |
| WF-Type `⊢ T type` | T is of the grammar above for the schema; its effect sets are WF-Effects |
| WF-Effects `⊢ ε effects` | before TC1: `[]` or `[Emit]`. In TC1: each name is `Emit` or a declared effect, the list in strictly increasing unsigned byte order (so no duplicates and one spelling per set, EFFECTS.md §3) |
| `v ∈ ⟦T⟧` | `[unit]` : Unit; `[bool b]` : Bool with b a boolean; `[int n]` : I64 with n canonical decimal (no `+`, no leading zero, no `-0`) in −2^63 … 2^63−1; `[bytes h]` : Bytes with h lowercase even-length hex; `[tuple v1..vn]` : Tuple(T1..Tn) pointwise; `[data TrapCode C]` : TrapCode for C one of the six trap names; `[data D C v...]` : Data(D) for a constructor C of D, fields pointwise. No value has a function type |
| `ctors(T)` | the constructor table `[C : fields]` of Data(D) (declared order) or of TrapCode (`Overflow DivZero Bounds InvalidDuration TaskLimit ChildFailed`, no fields); undefined for other types |
| `ops(E)` | the operations `op : A → B` of declared effect E |
| `sig(op)` | add, sub, mul, div: I64 × I64 → I64; neg: I64 → I64; lt, le, gt, ge: I64 × I64 → Bool; not: Bool → Bool; with data, bytes_length: Bytes → I64, bytes_index: Bytes × I64 → I64, bytes_concat: Bytes × Bytes → Bytes (02 §3). `eq` has its own rule |
| `Γ(x) = T` | the first binding of x in Γ is x : T |
| `Γ⁻` | Γ without its resumption bindings: what a lambda body and a clause see |
| `ε1 ∪ ε2`, `ε ∖ E`, `ε1 ⊆ ε2` | on byte-ordered sets, giving byte-ordered sets |
| `K1 K2`, `|K|` | concatenation and length of use lists |

Type equality is structural equality of the JSON values (the validator's
canonical-encoding equality). There is no subtyping: function types with
different effect sets are different types.

## 4 Programs and functions

```text
            ⊢ T type   for every constructor field T and every operation type T
            ⊢plain[] A, ⊢plain[] B   for every operation op : A → B, in declaration order
            Σ ⊢ f ok                 for every function f, in order
            the entry f_e exists;  ε(f_e) ⊆ [Emit];  input_schema = {type: A_e};  v ∈ ⟦A_e⟧
            ⊢plain[] A_e,  ⊢plain[] B_e
Program   ─────────────────────────────────────────────────────────────────────────
            ⊢ well-typed(A, v)

            ⊢ A type   ⊢ B type   ⊢ ε effects
            x : A ⊢ e : B ! ε' ▷ []      ε' ⊆ ε
Function  ─────────────────────────────────────────  for f = {parameter x : A, result B, effects ε, body e}
            Σ ⊢ f ok
```

Σ, the artifact's declarations, is implicit in every rule. The premises of
Program are exactly the judgments listed, in that order (§8). A field type may
be a function type naming any effect the artifact declares (EFFECTS.md §3: an
effect set names Emit or declared effects; nothing restricts where); see §10
for the validator's departure.

## 5 Serializable and equality-compatible types

In this slice the two coincide (02 §3): both exclude functions, through
datatype declarations, with cycle detection. Δ is the set of datatypes being
traversed.

```text
P-Base     ──────────────    T ∈ {Unit, Bool, I64, Bytes, TrapCode}
           ⊢plainΔ T

           ⊢plainΔ T1  …  ⊢plainΔ Tn
P-Tuple    ─────────────────────────
           ⊢plainΔ Tuple(T1..Tn)

           ⊢plainΔ∪{D} F    for every field F of every constructor of D, in order
P-Data     ───────────────────────────────────────────────────────────    D declared, D ∉ Δ
           ⊢plainΔ Data(D)

P-Assumed  ──────────────────   D ∈ Δ
           ⊢plainΔ Data(D)
```

There is no rule for Arrow: a function type is not serializable. A recursive
datatype is serializable when nothing reachable is a function (P-Assumed closes
the cycle, as the validator's visiting set does).

## 6 Expressions

The judgment `Γ ⊢ e : T ! ε ▷ K` says: in context Γ, expression e has type T,
may perform exactly the effects ε (the least set, computed, never widened), and
uses the resumption bound in Γ at the sites K on the path the rule follows
(§7). Literal and variable nodes are written without their node ID; the rules
that name a node ID n use it. Rules marked *data*, *TC1* or *H2* exist only in
schemas with data, in TC1 schemas, or in `tc1-handler-demo/2`.

```text
T-Unit      Γ ⊢ unit : Unit ! [] ▷ []
T-Bool      Γ ⊢ bool(b) : Bool ! [] ▷ []                   b a boolean
T-Int       Γ ⊢ int(n) : I64 ! [] ▷ []                     n ∈ ⟦I64⟧
T-Bytes     Γ ⊢ bytes(h) : Bytes ! [] ▷ []                 h lowercase even hex                    data
T-Var       Γ ⊢ var(x) : T ! [] ▷ []                       Γ(x) = T, T not Resumption(..)

            Γ ⊢ e1 : T1 ! ε1 ▷ K1      Γ, x : T1 ⊢ e2 : T ! ε2 ▷ K2
T-Let       ──────────────────────────────────────────────────────
            Γ ⊢ let(x, e1, e2) : T ! ε1 ∪ ε2 ▷ K1 K2

            Γ ⊢ c : Bool ! ε0 ▷ K0   Γ ⊢ e1 : T ! ε1 ▷ K1   Γ ⊢ e2 : T ! ε2 ▷ K2    |K1| = |K2|
T-If        ──────────────────────────────────────────────────────────────────────────
            Γ ⊢ if(c, e1, e2) : T ! ε0 ∪ ε1 ∪ ε2 ▷ K0 K1

            Γ ⊢ ei : Ti ! εi ▷ Ki  (i = 1..n)    sig(op) = T1 × … × Tn → T
T-Prim      ─────────────────────────────────────────────────────────
            Γ ⊢ prim(op, e1..en) : T ! ∪εi ▷ K1…Kn

            Γ ⊢ e1 : T ! ε1 ▷ K1   Γ ⊢ e2 : T ! ε2 ▷ K2   ⊢plain[] T
T-Eq        ─────────────────────────────────────────────────────                              data
            Γ ⊢ prim(eq, e1, e2) : Bool ! ε1 ∪ ε2 ▷ K1 K2

            Γ ⊢ ei : Ti ! εi ▷ Ki  (i = 1..n, 1 ≤ n ≤ 8)
T-Tuple     ─────────────────────────────────────────────                                      data
            Γ ⊢ tuple(e1..en) : Tuple(T1..Tn) ! ∪εi ▷ K1…Kn

            Γ ⊢ e : Tuple(T0..Tm) ! ε ▷ K      0 ≤ i ≤ m
T-Project   ────────────────────────────────────────                                           data
            Γ ⊢ project(e, i) : Ti ! ε ▷ K

            Γ ⊢ ei : Fi ! εi ▷ Ki  (i = 1..n)    T = Data(D) with D declared, or T = TrapCode for D = TrapCode
            C : F1..Fn ∈ ctors(T)
T-Construct ─────────────────────────────────────────────                                      data
            Γ ⊢ construct(D, C, e1..en) : T ! ∪εi ▷ K1…Kn

            Γ ⊢ e : S ! ε0 ▷ K0        ctors(S) = [C1 : F̄1, …, Cm : F̄m]
            the arms name each Cj exactly once (any order): arm Cj(x̄j) => bj with |x̄j| = |F̄j|
            Γ, x̄j : F̄j ⊢ bj : T ! εj ▷ Kj   for every arm      |K1| = … = |Km|
T-Match     ────────────────────────────────────────────────────────────                       data
            Γ ⊢ match(e, arms) : T ! ε0 ∪ ε1 ∪ … ∪ εm ▷ K0 K1

            Γ ⊢ e : T ! ε ▷ K      ⊢plain[] T      label a string
T-Emit      ─────────────────────────────────────────
            Γ ⊢ emit(label, e) : Unit ! ε ∪ [Emit] ▷ K

            ⊢ A type   ⊢ B type   ⊢ ε effects   Γ⁻, x : A ⊢ e : B ! ε' ▷ []   ε' ⊆ ε
T-Lambda    ────────────────────────────────────────────────────────────────
            Γ ⊢ lambda(x : A, B, ε, [], e) : Arrow(A, B, ε) ! [] ▷ []

            Γ ⊢ e1 : Arrow(A, B, ε) ! ε1 ▷ K1      Γ ⊢ e2 : A ! ε2 ▷ K2
T-Apply     ──────────────────────────────────────────────────────
            Γ ⊢ apply(e1, e2) : B ! ε1 ∪ ε2 ∪ ε ▷ K1 K2

            Γ ⊢ e : A ! ε1 ▷ K      f declared with argument A, result B, effects ε
T-Call      ─────────────────────────────────────────────────────
            Γ ⊢ call(f, e) : B ! ε1 ∪ ε ▷ K

            Γ ⊢ e : A ! ε ▷ K      op : A → B ∈ ops(E)
T-Perform   ─────────────────────────────────────────                                           TC1
            Γ ⊢ perform(E, op, e) : B ! ε ∪ [E] ▷ K

            Γ ⊢ body : T ! ε0 ▷ K
            the clauses name each op of ops(E) exactly once (any order), and for each:
              op(x) => c        with op : A → B:   Γ⁻, x : A ⊢ c : B ! εc ▷ []
              op(x, k) => c     with op : A → B:   Γ⁻, x : A, k : Resumption(B, T) ⊢ c : T ! εc ▷ [n]    (H2)
T-Handle    ───────────────────────────────────────────────────────────────────                 TC1
            Γ ⊢ handle(E, clauses, body) : T ! (ε0 ∖ E) ∪ ∪εc ▷ K

            Γ(k) = Resumption(B, T)      Γ ⊢ e : B ! ε ▷ K
T-Resume    ─────────────────────────────────────────                                            H2
            Γ ⊢ resume_n(k, e) : T ! ε ▷ K [n]

T-Discontinue  Γ ⊢ discontinue_n(k) : Unit ! [] ▷ [n]       Γ(k) = Resumption(B, T) for some B, T     H2
```

Notes on the rules, each a reading of the contract:

- **Effects are exact.** Every rule computes its effect set from its premises;
  the only places a set may be larger than what is performed are the declared
  sets of Function and T-Lambda (`ε' ⊆ ε`). A call and an application
  contribute the callee's *declared* set (EFFECTS.md §3 table).
- **A clause sees the handle's bindings** (EFFECTS.md §3, §4), without any
  resumption: Γ⁻. A clause performing E itself goes to the next handler out,
  and so E stays in its effects (T-Handle removes E from the body's effects
  only).
- **Resumption types** (EFFECTS.md §7): in `op(x, k) => c` with `op : A → B`
  under a handle of type T, `k : Resumption(B, T)`, `resume(k, e)` takes e : B
  and has type T, `discontinue(k)` has type Unit, and c has type T.
- **The entry** may perform only Emit: every user effect is handled inside the
  program (EFFECTS.md §3).
- **Operation types are serializable** (EFFECTS.md §1), by the Program rule's
  plain premises.
- **Exhaustiveness**: T-Match and T-Handle require a bijection between arms and
  constructors, clauses and operations: as many as the table has, each named
  once, each found.
- The validator also requires a function body's free bindings to be its
  parameter ("Named function captures"). That follows from the rules: the
  body's context is the parameter alone, and every variable must be bound.

## 7 One-shot resumption as a usage-counting judgment

EFFECTS.md §7: on every path through a clause `op(x, k) => c`, k is used exactly
once, by one resume or one discontinue; k is not a value; a closure cannot
mention k; an inner handler's clause cannot use an outer clause's k.

The rules state it with the use list K:

- **At most one resumption is in scope anywhere.** Only the H2 clause premise
  of T-Handle binds one, and it extends Γ⁻, which has none; T-Lambda's body also
  sees Γ⁻. So K counts the uses of *the* resumption in Γ, and a number |K| is
  enough; the list of sites makes a derivation readable.
- Strict forms add their operands' uses (T-Let, T-Prim, T-Tuple, T-Apply, …);
  T-Resume and T-Discontinue add their own site.
- **Alternatives must agree.** T-If requires `|K1| = |K2|` and counts the
  condition plus one branch; T-Match requires every arm to have the same count
  and counts the scrutinee plus one arm. So "the number of uses" is the same on
  every path, and is that number.
- **The clause** requires exactly one use: `▷ [n]`.
- **Not a value**: T-Var refuses a resumption-typed binding; nothing else
  produces Resumption(..) as a type.
- **Not in a closure, not in an inner clause**: both see Γ⁻, so T-Resume and
  T-Discontinue find no binding for k there.
- Other judgments conclude `▷ []`: a function body, a lambda body, a tail
  clause (each sees no resumption).
- The body of a handle *inside* a clause sees k (it is in Γ, not Γ⁻), so a
  resume can happen under an inner handler, as EFFECTS.md §7 and the
  frontend's examples use.
- A path that traps before using k is not distinguished: traps are not part of
  typing, as EFFECTS.md §7 allows.

## 8 Derivations as data

A derivation is a JSON value, a tree of nodes

```text
node        ::= [rule-name, conclusion, [node...]]           premises in the order the rule lists them
conclusion  ::= ["well-typed", artifact, input]              Program
              | ["function", function-object]                Function
              | ["plain", [D...], T]                         P-*: ⊢plainΔ T, Δ as a list
              | ["expr", Γ, e, T, ε, K]                      T-*: Γ as [[x, T]...] innermost first,
                                                             e the expression, K the use sites
```

Contexts are lists of `[ID, type]` pairs, a resumption's type written
`["Resumption", B, T]`; a binding added by a rule goes in front (a match arm's
binders in their order, then the rest; a clause's k before its x). Premise
order: Program as in §4 (operation types by effect and operation, then
functions, then the entry's argument and result); T-If condition, then, else;
T-Match scrutinee then arms in the artifact's order; T-Handle body then clauses
in the artifact's order; T-Eq the two operands then the plain premise; T-Emit
the operand then the plain premise; P-Data the fields of each constructor in
order. Everything is strings, booleans, lists and objects, so `json.stringify`
writes a derivation and `json.parse` reads one back. An example for each
frontend program is written to `build/typing/*/derivations/` by `typing/run.sh`.

## 9 The rule set given to Shen

`typing/search.shen` states R to Shen as one datatype, `fenrir-typing`, of
sequent rules, and finds derivations with `shen.typecheck`: to type a function
body it asks Shen to prove `body : (ts.j Γ T F K D)` with F, K and D unknown, and
the D a proof binds is the derivation. This is the same machinery
[verification/shen-proving/](../../verification/shen-proving/README.md) used for
2 + 1 = 3. The relation between that rule set, R_S, and R:

- **One Shen rule per rule of R** for the expression and plain judgments, each
  building the node of the R rule it states, by name. Program and Function nodes
  are assembled by an ordinary function (`ts.assemble`), which has nothing to
  choose.
- **Auxiliary judgments**, because a Shen side condition can only see what the
  conclusion has bound and premise results are needed: `ts.close` (union of
  effects, concatenation of uses, the node), `ts.same-length`, `ts.table`,
  `ts.covers`, `ts.arm-uses`, `ts.nth`, `ts.handled`, `ts.lambda`, `ts.none`,
  `ts.one`; and list forms `ts.rows`, `ts.arms`, `ts.clauses`, `ts.plains` for
  variable-length premise lists. None of them appears in a derivation.
- **Terms and types are quoted**: Shen's checker holds a list `[X | Y]` in a
  term or type as `[cons X Y]`; the driver quotes the artifact and unquotes the
  derivation.
- **R_S may check less than R** (it does not check function signatures, which
  the checker does: the probe `bytes-type-under-schema-1` is a derivation the
  search builds and the checker rejects) **or more** (budget). Neither matters
  for what is accepted: if R_S is wrong, search fails, or builds a derivation the
  checker rejects; either way the program is not accepted, which on a valid
  program shows up as a disagreement with the JavaScript validator. Proof search is bounded by `maxinferences` (2,000,000
  inferences per proof); running out is UNKNOWN.
- Shen's checker *was* drivable for the object language here; the costs found
  were load time (a rule that spelled the derivation node out as its type
  pattern took Shen about a second to compile; built by `ts.close` it takes
  milliseconds; the whole rule set about 0.3 s, which the frontend saves by
  running from a Shen/JIT heap image that holds it compiled) and the quoting.

`typing/unsound.shen` adds three deliberately unsound rule sets to the search
(any expression has any type; the one-shot rule forgotten; perform without its
effect), the analogue of `unsound-rule.shen`. Shen takes them silently and
finds "derivations" of ill-typed programs; the checker rejects every one (§12).

## 10 The fixed checker

`typing/checker.shen`: `(tc.check A v D)` is true iff D is JSON data, D's root
concludes `["well-typed", A, v]`, and every node is an instance of its rule.
One clause of `tc.rule` per rule of §4–§6, whose pattern is the rule's
conclusion and its premises' conclusions (a repeated pattern variable ties a
premise to its conclusion) and whose body is the side conditions; 65
lines of rules and 255 of side conditions and transport, 322 lines without comments and
blank lines in all.

It is total. `tc.node` recurses only into the premises of the node in hand,
which are proper parts of D; every side condition recurses only into a proper
part of a finite type, value, context or list it was given; nothing follows a
datatype reference (P-Data's premises do, in the derivation, which is finite
data). Every function has a last clause for shapes it does not expect, so no
call fails as a partial function (which in Shen/JIT would read standard input),
and any run-time error is caught and rejects. Unknown rule names, missing or
extra premises, and failed side conditions reject. It does no search: the only
choice it makes is which `tc.rule` clause a rule name selects.

## 11 Against the JavaScript validator

Rejection classes. The validator's messages map onto §2 and §4–§6 as follows
(`typing/families.mjs`, `CLASSES`); the differential compares the coarse class
(structure, typing, limit) of each rejection.

| Validator message | Here |
| --- | --- |
| Identity | S-Identity |
| Effect declarations unsupported, Declarations unsupported | S-Features |
| Closed object fields, Array required, String required, Identifier, Unsigned ID, Expression, Arity, Unsupported tag, Primitive, Tuple arity, Match arm, Handler clause, Empty capture support required | S-Shape |
| Datatype count, Datatype name, Constructor count, Duplicate constructor, Field count, Effect count, Effect name, Operation count, Duplicate operation, Function count, Duplicate function name | S-Declarations |
| Duplicate ID | S-Unique-IDs |
| Source map location, Source map incomplete | S-Source-Map |
| AST cap; Type depth; Bytes cap; Value cap | L-Nodes; L-Type-Depth; L-Bytes; L-Values |
| Type; Effect set, Effect set order | WF-Type; WF-Effects (Function, T-Lambda, Program) |
| Operation types must be serializable, Entry, Entry must handle every user effect, Serializable entry, Input schema | Program |
| Value type/range; Bytes hex | T-Int, T-Bool, entry value; T-Bytes, entry value |
| Function signature, Named function captures | Function |
| Unknown binding, A resumption is not a value | T-Var |
| If types | T-If |
| A resumption must be used on every path | T-If, T-Match (`|K1| = |K2|`) |
| Equality type; Primitive type; Projection | T-Eq; T-Prim; T-Project |
| Unknown datatype, Constructor, Constructor field type | T-Construct |
| Match scrutinee type, Non-exhaustive or duplicate match arms, Match binders, Match arm types | T-Match |
| Emit serializable; Lambda signature; Apply type | T-Emit; T-Lambda; T-Apply |
| Unknown function, Call argument | T-Call |
| Unknown effect operation, Perform argument | T-Perform |
| Unknown effect, Handler clauses, Handler clause type, A resumption must be used exactly once on every path | T-Handle |
| Unknown resumption; Resume argument | T-Resume, T-Discontinue; T-Resume |

The validator reuses "Array required" and "String required" for a type that is
neither a built-in name nor an array (for example `Bytes` under schema `/1`),
which here is WF-Type: the class differs, both reject.

**Disagreements found, and which side is wrong.**

1. **The validator rejects an effectful function type in a datatype field.**
   `{name: Box, constructors: [{name: Box, fields: [Arrow(I64, I64, [Ask])]}]}`
   with effect Ask declared is rejected with "Effect set": the validator checks
   field types before it has read the effect declarations, so only `Emit` is
   known then. EFFECTS.md §3 allows any declared effect in an effect set and
   restricts nowhere where a function type may appear; the rules here accept.
   **The validator is wrong** (an order-of-processing defect, not a rule); it is
   reported, not fixed here (`tools/tc0/pure-call-artifact.mjs` is not this
   work's to change). It reaches users: the surface program
   `tests/typing/datatype-field-effect.fen` is valid by the contract, and
   `fenrir.sh check` reports the two validators disagreeing (status 3).
2. **Order, in programs with two faults.** Where an artifact breaks a structural
   check and a typing rule, the validator reports whichever it meets first in
   its single pass, and the Shen side always reports the structural check. Both
   reject. The invalid programs of `tests/tc1/handler-artifact.test.mjs` and
   `pure-data-invalid.mjs` mostly have such a second fault: replacing a node
   leaves its source-map rows behind. With the source map made exact
   (`invalid-resynced` family) the classes agree on all but two, which still
   have two genuine faults (duplicate binder IDs in a copied clause; a Data type
   in a signature and data tags in the body under schema `/1`).

No disagreement on acceptance was found anywhere else (§12).

## 12 Evidence and what is not done

`sh typing/run.sh` (development evidence; status `development-pass`,
qualification `UNKNOWN`, about 95 s: 23 s of it the JavaScript side): the structure checks, search and checker
against the validator on every family in the repository; the model run on every
program the Shen side accepts; and the forged-derivation tests. Its report
gives the numbers per family; the figures as of this draft:

| Family | Programs | Both accept | Both reject | Disagree |
| --- | --- | --- | --- | --- |
| TC0-A hand fixtures | 23 | 23 | 0 | 0 |
| generated pure-call / pure-data | 32 / 24 | 32 / 24 | 0 | 0 |
| exact arithmetic | 8,745 | 8,745 | 0 | 0 |
| exhaustive-small to 5 nodes | 5,695 | 5,695 | 0 | 0 |
| TC1 hand fixtures | 20 | 20 | 0 | 0 |
| TC1 exhaustive grammar H to 7 nodes | 12,693 | 12,693 | 0 | 0 |
| frontend programs (examples, tests/frontend/programs, roundtrip), elaborated | 39 | 39 | 0 | 0 |
| pure-data-invalid | 27 | 0 | 27 | 0 |
| handler-artifact test rejections | 26 | 0 | 26 | 0 |
| the same, source map made exact | 52 | 0 | 52 | 0 |
| single-point mutants (`typing/mutate.mjs`) | 7,060 | 413 | 6,647 | 0 |
| boundary probes (`typing/probes.mjs`) | 57 | 29 | 27 | 1 (§11, 1) |

- **Forged derivations**: every node of the derivations of 328 valid programs
  corrupted eleven ways (rule name wrong or swapped for another rule's, premises
  swapped, dropped or duplicated, conclusion type altered, context weakened, a
  use or an effect added or dropped): 55,014 corruptions, all rejected.
  Derivations of valid programs transplanted onto their 6,646 ill-typed
  mutants: all rejected. The three unsound search extensions of §9 built 9,614
  derivations for ill-typed programs: all rejected.
- **Type safety, bounded**: every program the Shen side accepts in these
  families (27,714) runs on the Shen model for 200 steps without reaching a
  state the model cannot step (traps are outcomes); 4 stop at the step bound,
  the frontend programs that run longer. For the two exhaustive scopes this
  repeats what `harness/run-model-vs-candidate.sh` and
  `harness/run-tc1-exhaustive.sh` already show for the same programs (every one
  completes and agrees with the JavaScript machine); it adds that the set the
  checker accepts is exactly that set.

Not done: any soundness proof of R (progress, preservation, or that the
one-shot judgment implies one-shot behaviour), and the Búri contract that would
state it; a proof that the checker implements R (it is short so that it can be
read against §4–§6); exhaustive invalid-program exploration (the mutants are
single-point and bounded); inputs other than `["int","0"]`; effect-row
inference at the surface (the frontend's inference produces explicit sets that
these rules check); the tasks and channels schema being added to the validator
in parallel. The rules, the checker, the search, the families and this
document have one author.

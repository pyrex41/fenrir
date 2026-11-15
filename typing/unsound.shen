\\ Fenrir typing: three UNSOUND additions to the search, for the checker's soundness
\\ evidence only (typing/run.shen). Never loaded by the frontend. Each is a set of
\\ Shen sequent rules that conclude what TYPING.md does not allow, the way
\\ verification/shen-proving/unsound-rule.shen adds 0 + 1 = 0: Shen's search takes
\\ them silently and then finds "derivations" for ill-typed programs. The point is
\\ that the checker, not the rule set given to Shen, decides what counts: every
\\ derivation built with one of these active must be rejected by typing/checker.shen.
\\ All three are precluded here; typing/run.shen includes one at a time.

\\ Any expression has any type, with no effects and no uses, by T-Unit.
(datatype fenrir-unsound-anything
  ["ts.close" "T-Unit" G E T [] [] []] : (ts.out F K D);
  _______________________________________________________
  E : (ts.j G T F K D);)

\\ The one-shot rule forgotten: a clause may use its resumption any number of times,
\\ and the branches of an if need not agree.
(datatype fenrir-unsound-resume
  if (ts.resumptions?)
  let O (ts.op Op Ops)
  if (not (= O none))
  let Ta (ts.first O)
  let Tr (ts.second O)
  C : (ts.j [[Kv ["Resumption" Tr T]] [X Ta] | G] T F K D);
  Cs : (ts.clauses G T Ops Ds Fs);
  _______________________________________________________
  [[Op X Kv C] | Cs] : (ts.clauses G T Ops [D | Ds] [F | Fs]);

  C : (ts.j G "Bool" F0 K0 D0);
  E1 : (ts.j G T F1 K1 D1);
  E2 : (ts.j G T F2 K2 D2);
  ["ts.close" "T-If" G ["if" N C E1 E2] T [F0 F1 F2] [K0 K1] [D0 D1 D2]] : (ts.out F K D);
  _______________________________________________________
  ["if" N C E1 E2] : (ts.j G T F K D);)

\\ An effect forgotten: perform adds nothing to the effects of its argument.
(datatype fenrir-unsound-perform
  if (ts.handlers?)
  let O (ts.operation Eff Op)
  if (not (= O none))
  let Ta (ts.first O)
  let T (ts.second O)
  E : (ts.j G Ta F1 K1 D1);
  ["ts.close" "T-Perform" G ["perform" N Eff Op E] T [F1] [K1] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["perform" N Eff Op E] : (ts.j G T F K D);)

\\ A scope or a task result that need not be serializable: a handle or a closure may
\\ leave its scope (CONCURRENCY.md §3 forgotten).
(datatype fenrir-unsound-scope
  if (ts.tasks?)
  B : (ts.j G T F1 K1 D1);
  ["ts.close" "T-Scope" G ["scope" N B] T [F1 ["Task"]] [K1] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["scope" N B] : (ts.j G T F K D);

  if (ts.tasks?)
  E : (ts.j G ["Arrow" "Unit" T Ef] F1 K1 D1);
  ["ts.close" "T-Spawn" G ["spawn" N E] ["Task" T] [F1 Ef ["Task"]] [K1] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["spawn" N E] : (ts.j G ["Task" T] F K D);)

(preclude [fenrir-unsound-anything fenrir-unsound-resume fenrir-unsound-perform fenrir-unsound-scope])

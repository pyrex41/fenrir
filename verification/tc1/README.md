# Remote-effect TLA+ model

`RemoteEffect.tla` is a model of EFFECTS.md §12 and `supervisor/README.md`: one caller, one peer, a supervisor with a journal, and a network that can drop and duplicate. It is not a translation of `models/tc1/remote-system.shen`.

`F(version, arg) = 10*version + arg`. Reply records are indexed by request id and store the operation and argument. `everHanded` is a history variable used by `NDSound`.

The model matches master `a89bf40`. The journal is RAM (`SupVMLoss` clears `handed` and `accepted`). Upgrade increments the peer version and does not change the signature digest.

## Run

From this directory, with `tla2tools.jar` and Java:

```sh
java -jar tla2tools.jar -workers 2 -config baseline.cfg RemoteEffect.tla
java -jar tla2tools.jar -workers 2 -config vmloss.cfg RemoteEffect.tla
java -jar tla2tools.jar -workers 2 -config upgrade.cfg RemoteEffect.tla
java -jar tla2tools.jar -workers 2 -config liveness.cfg RemoteEffect.tla
```

## What each config is expected to show

| Config | Expected |
| --- | --- |
| `baseline.cfg` | No violation. Supervisor-restart is the §12.7 step (`handed` becomes the accepted set). 2 crashes, 2 intents, 2 attempts, 1 duplicate. |
| `vmloss.cfg` | `NDSound` fails: Issue, Deliver, SupVMLoss, NotDelivered. `NoDoubleApply` fails on the longer trace that then issues a fresh key and Acts again. Comment out `NDSound` to get that trace. `PerKey` and `SingleOutcome` hold when checked on their own. |
| `upgrade.cfg` | `VersionSafe` fails: a request issued at version 1 is answered with `F` of version 2 (21 instead of 11 for argument 1). |
| `liveness.cfg` | `EventuallySettled` fails under weak fairness. `timed_out` is not a definite result, and a fair run can stop there. |

Checked at `a89bf40` with TLC (tla2tools 1.8, Java 21): baseline 137,874 distinct states, depth 24, no error; the three failure configs violate as above.

# A3 storage validation: process crash is not power loss

## What we can check now

- **Connection contract.** Each new or reopened adapter connection requires
  WAL, FULL (`sync_off` test mutant excepted), foreign keys and a 50 ms busy
  timeout. The host tests observe those settings, refuse a database that
  cannot enter WAL, reject an orphan insert on a configured connection, and
  check the busy outcome under a second writer's lock. The crash audit also
  checks `foreign_key_check` independently of the adapter.
- **Sync requests.** On a fresh database measure the SQLite VFS write and sync
  counter deltas around one real adapter commit. FULL must write and request
  sync; OFF must write without requesting sync. These counters observe calls to
  SQLite's delegated VFS, not whether persistent media retained the writes.
  This is a configuration/mechanism check, not a `sync_off` campaign detection.
- **Process crash and lost acknowledgment.** Sweep the actual child port at
  statement/write/sync boundaries, kill host processes at named hooks, and
  independently audit reopened files against the acknowledged receipts and
  canonical state. After a witnessed post-COMMIT port kill with no reply, an
  identical retry must return the stored receipt with no second mutation.
  `SIGKILL` does not evict dirty kernel pages, and reopening the database can
  checkpoint or otherwise modify it; archive the pre-recovery disk image when
  the test needs raw evidence.

Assume one host with a local filesystem supporting SQLite WAL, cooperating
SQLite locking, and no external writes/copies, journal deletion or sharing over
a network filesystem. A deployment must preserve the database and its WAL as a
unit. SQLite, its VFS, the OS and storage must honor the requested syncs and
ordering for any durability claim beyond process death. Schema creation and
checkpoint behavior, disk errors, encryption and alternative VFS/filesystems
are not validated by the narrow sync counter test.

## Next evidence, in increasing order of realism (not run here)

1. **Controlled discard of unsynced writes.** In an offline test runner using a
   disposable image, an instrumented VFS or virtual block device should record file
   operations and keep a durable shadow updated only by successful syncs
   (including the applicable metadata, size, truncation and file creation/deletion
   rules). A cut drops volatile state, not just userspace; restart on a fresh
   copy of the shadow. Document what flush, ordering, torn writes and writeback
   behavior the model does or does not represent. Run the same process-crash
   workload as a comparison.
2. **Run a fixed oracle for both FULL and OFF.** Outside the failure domain,
   record the acknowledged submit receipt or delivery, and record the confirmed
   cut location independently. Start from a synced baseline; require at least
   one post-ack, **pre-checkpoint** cut with committed WAL writes still
   volatile in OFF. Under FULL every prior acknowledged acceptance must
   survive with its key, report, job, payload and counter; delivered status
   must survive too. Every operation without a reply is allowed to be wholly
   present or wholly absent, never partial. Compare pre- and post-retry state,
   check SQLite integrity and foreign keys, and check tenant separation and no
   duplicate allocations. Cover WAL creation, later appends, checkpoints,
   truncation/reuse and first reopen, recording platform versions, fault
   positions, recovery and oracle results. If OFF looks safe at every relevant
   cut, investigate the harness rather than count that as a validated contrast.
3. **Target stack.** After approval, repeat on dedicated disposable hardware
   or a storage test rig with the actual filesystem, mount options,
   VFS/SQLite build, controller and device cache settings. A guest reboot or
   VM stop above a live host cache is not a physical power cut. If the test is
   physical, use an independent acknowledgment recorder and power-cut witness
   not powered by the device under test. Preserve the failing pre-recovery
   images and report exact bounds; this is still bounded evidence, not proof
   of fsync honesty.

Owner decisions: choose the supported target stack and durability scope;
approve an isolated simulator/rig, control criteria and evidence budget
before any destructive experiment. Never test a cut on a live service,
shared host or non-disposable volume.

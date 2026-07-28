# PLANS.md

Use this file for tasks that are large, risky, or likely to span multiple
rounds.

Create or update a plan before major edits when the task:
- Touches Noise, BLE, mesh, or database internals
- Changes behavior across multiple files or layers
- Needs phased verification
- Requires careful rollback or migration thinking

Keep plans concrete. Avoid filler.

## Plan Template

```md
# <task title>

## Goal
- What outcome is required?

## Constraints
- Repo invariants
- User constraints
- Tooling or environment limits

## Facts
- What is already true in the codebase?
- What was verified from docs, tests, or logs?

## Approach
- Chosen implementation path
- Why this path over obvious alternatives

## Steps
1. First concrete change
2. Next concrete change
3. Verification step

## Verification
- `flutter analyze`
- Targeted `flutter test ...`
- Full suite if warranted
- Manual checks if needed

## Risks
- What could regress?
- What remains uncertain?

## Open Questions
- Questions that must be answered before proceeding
```

## Update Rules

- Update the plan when facts change.
- Mark completed steps explicitly.
- Remove stale assumptions.
- Keep the plan short enough to stay usable.

## Closeout

Before finishing a multi-step task:
- Reconcile plan steps against the actual result
- Note any skipped verification
- Call out remaining risks

---

# Public-claim and CI truth reconciliation (Codex, 2026-07-14)

## Goal

Reconcile the current local durability/route hardening chain with the public
README, live status/SRS surfaces and the latest GitHub Actions evidence without
pushing or claiming hardware validation.

## Constraints

- Keep the canonical repository as the sole active PakConnect worktree.
- Do not push, force-push, merge, or write directly to public `main` in this
  pass.
- Promote a new runtime/device-test baseline because the notification copy,
  Flutter/lockfile authority, workflow definitions, Android compatibility
  flags, archive truthfulness, platform branding and BLE contract comments are
  runtime/build-input changes after `53bb4fe`.
- Local green tests do not prove an unrun GitHub workflow; desktop tests do not
  prove BLE, mobile SQLCipher, background delivery, signed release, iOS or
  multi-device behavior.

## Facts

- Public `main` is `df30c99`; publication of the local hardening chain remains
  intentionally pending.
- Public Flutter run `29215130687` failed with 5,537 passes and two SQLite
  `database is locked` failures. Both suites had reverted to the shared
  production filename `pak_connect.db` while test files ran in parallel.
- Local commit `569ff9a` preserves the suites' isolated database names instead
  of serializing the entire workflow.
- `db529df` removes the false killed-process notification claim from runtime
  copy and adds an Android widget regression.
- `eccced7` pins the Flutter 3.44.4
  dependency resolution and workflow behavior, adds CodeQL push/manual
  triggers, upgrades the artifact action, and records Flutter's Android
  compatibility flags so a build no longer mutates tracked inputs.
- `5142358` reports archive compression requests honestly as uncompressed;
  `d584f44` replaces public Flutter template branding; and `7944c93` labels
  dormant BLE contract seams without changing the active route.
- Flutter 3.44.4 bundles Dart 3.12.2. The package keeps Dart 3.10.3 as its
  language floor while Flutter 3.44.4 is the minimum and canonical toolchain.
- `53bb4fe`, docs descendant `ed4d416`, and toolchain checkpoint `eccced7`
  remain previous-baseline provenance, not current device-run authority.

## Approach

1. Audit public claims, GitHub runs and live status documents against current
   code/configuration.
2. Split runtime truth and CI/toolchain corrections into independent commits.
3. Run the exact local coverage command, debug APK build and all fail-closed
   workflow gates on the final build-input commit.
4. Repin documentation/status surfaces to the verified baseline.
5. Verify links, paths, baseline/build-input identity and diff hygiene, then
   commit the readiness closeout locally.

## Exit evidence

- Baseline `7944c93` passes 5,691 tests with zero failures (reporter 5m37s;
  measured command wall 353,083ms). `flutter_test_latest.log` is 9,268,167
  bytes, SHA-256
  `78798AD4575FB77E3B99F50C5D30B4715CE44CAA9BDC5245982CAF5F3892C905`.
- Its coverage artifact is 426,546 bytes, SHA-256
  `57F95535FC93711B39344343A1D8F2DE644B9697EA23F45204D1529CE84BF794`.
- Its debug APK is 205,113,616 bytes, SHA-256
  `84C9B0F5E32D34C90C06D2F9CE7787E23AF60CF79692395B75C2B5DC0BF46059`.
- Analyzer, dependency-lock enforcement, DI/runtime/reachability/suppression
  gates, the 108-test strict BLE suite, all 14 crypto-policy cases and
  `git diff --check` pass on Flutter 3.44.4 / Dart 3.12.2.
- The first post-upgrade targeted test exposed a stale Flutter 3.41.5 shader
  artifact; one `flutter clean` removed it and the 18-test file then passed.
  The first APK build exposed Flutter's two compatibility flags; they were
  committed before the final full-suite and APK verification.
- README and live status/SRS documents disclose the red public workflow and
  pending exact-head GitHub validation.
- `git diff 7944c93..HEAD -- lib test integration_test android ios linux macos
  web windows assets pubspec.yaml pubspec.lock .metadata analysis_options.yaml`
  remains empty for runtime/build inputs after the readiness closeout.

## Remaining boundary

Fresh GitHub Actions, public-branch publication and all physical-device gates
remain pending until a later explicitly authorized push/PR and device run.

---

# Fail-closed offline queue durability (Codex, 2026-07-13)

## Goal

Prevent the canonical runtime from reporting a message as queued when its
durable queue could not initialize, load, or store that message.

## Constraints

- Production direct-message admission must remain persistence-before-delivery.
- Deliberately volatile relay/test queues may remain available only through an
  explicit opt-in.
- Preserve the existing queue contracts and database schema.
- A failed durable write must not publish a callback, increment statistics, or
  leave a ghost message in the in-memory retry queue.

## Facts

- Durable queue initialization now fails when storage is missing or cannot be
  loaded; volatile storage requires an explicit opt-in.
- `MessageQueueRepository` propagates load/write failures and stages complete
  queue/tombstone snapshots before replacing live state.
- New direct and queue-sync admissions persist before memory publication.
- AppCore retries with a fresh runtime, and router initialization is serialized,
  reset-cancellable, and published only after its queue is ready.
- Rebootstrap waits for owned BLE/chat teardown, clears session/topology state,
  and publishes Noise only after successful initialization; partial Noise key
  generation is zeroized on failure.
- Ephemeral-contact cleanup uses the shared queue and keeps contacts whenever
  queue availability is uncertain.

## Approach

1. Make durable storage the default queue policy and require an explicit flag
   for volatile fallback.
2. Propagate queue repository load/write failures after logging.
3. Persist a durable message before publishing it to the in-memory queue.
4. Prove missing-provider, initialization-failure, write-failure, explicit
   volatile-mode, and healthy SQLite restart behavior.

## Verification

- 265 focused queue-store, repository, SQLite restart, sync, cleanup, router,
  AppCore retry, Noise cleanup, chat lifecycle, and app-tree tests pass.
- A broader affected-surface run passed 2,357 tests before the final router
  cancellation/fallback-init hardening; its follow-up regressions are included
  in the 208-test pass.
- Targeted `flutter analyze --no-pub` and `git diff --check` pass.
- Full suite and Android debug APK are green in promoted baseline `53bb4fe`.

## Risks

- Existing unit tests that implicitly depended on the production queue's
  volatile fallback must opt in or use an in-memory test double.
- Other queue mutation paths have memory/database ordering debt; keep them in
  the debt inventory unless they are made atomic in this bounded pass.

## Status

- **Complete and promoted:** the fail-closed queue change, full suite and debug
  APK are included in device baseline `53bb4fe`.

---

# Target-bound BLE reconnect (Codex, 2026-07-13)

## Goal

Make automatic reconnect after link loss or Bluetooth power cycling retry only
the previously connected platform peripheral, while preserving that target
through cleanup and cancelling delayed reconnect work when state changes.

## Constraints

- Preserve the existing dual-role, collision-resolution, and handshake flows.
- Do not infer a cryptographic identity from a platform peripheral UUID.
- Never auto-connect to a different service advertiser when the expected UUID
  is absent; timeout is the safe outcome.
- Keep manual chat reconnect identity verification unchanged.
- No claim that platform peripheral UUIDs remain stable across every Android
  power cycle until two-device hardware evidence exists.

## Facts

- Power-off handling saves `_lastConnectedDevice` and then cleanup immediately
  clears it.
- Starting monitoring while disconnected overwrites the saved target with
  `null`.
- The reconnect scan currently accepts the first service advertiser, even when
  it is not the previous peripheral.
- The policy's 800 ms resume timer is not owned/cancelled on later state changes
  or manager disposal.

## Approach

1. Preserve a non-null last target through monitoring startup and monitored
   cleanup; explicitly restore it after power-off cleanup.
2. Add a target-bound scan that ignores nonmatching advertisers and returns
   `null` on timeout.
3. Route automatic health-monitor reconnect through that target-bound scan;
   leave the generic/manual scan behavior intact.
4. Own and cancel the delayed power-on timer on state transitions, explicit
   monitoring stop, and disposal.
5. Prove target preservation, wrong-then-right filtering, timeout, and timer
   cancellation with focused tests before broader BLE verification.

## Verification

- Reconnect-policy and BLE connection-manager tests.
- Connection-health-monitor and BLE service/facade tests.
- `flutter analyze --no-pub`.
- Full suite and Android debug APK are green in promoted baseline `53bb4fe`.

## Risks

- Android may rotate the exposed peripheral UUID after power state changes;
  this patch must fail closed rather than dial an unrelated advertiser.
- Reconnect retries must remain live after a failed dial without reviving work
  after an explicit stop or dispose.

## Status

- **Complete:** last-target preservation, target-bound service scan, false-link
  success rejection, retry-preserving failure cleanup, and owned/cancellable
  power-on restart timer.
- **Regression evidence:** 39 focused manager/health/policy tests and 213
  affected BLE service/facade tests pass; analyzer is clean.
- **Device boundary:** validate whether each Android phone keeps the same
  exposed peripheral UUID across Bluetooth off/on. Rotation must produce a
  safe timeout/manual identity-verified reconnect, not first-advertiser dial.
- **Promoted verification:** full suite and Android debug APK are green in
  device baseline `53bb4fe`.

---

# Atomic archive restore (Codex, 2026-07-13)

## Goal

Make restore all-or-preserve: either the selected archived snapshot becomes a
complete live chat and the archive is removed, or every live/archive row stays
as it was before the attempt.

## Constraints

- Preserve archive-field decoding before writing live-message rows.
- Treat overwrite as permission to replace only the selected target chat.
- A message-ID collision outside that target must fail the whole restore.
- Do not delete the archive until every live row is committed successfully.
- Keep schema and migration semantics unchanged.

## Facts

- Current restore saves messages one at a time through forgiving upsert logic
  and deletes the archive after any partial success.
- Archive rows and live rows have different identity, timestamp, target-chat,
  JSON-validation, and audit-timestamp semantics, so raw `INSERT ... SELECT`
  is not a valid restore path. Current archive field wrappers are pass-through;
  intended mobile at-rest encryption is provided by SQLCipher.
- The detail/dialog double-owner restore flow is already fixed separately.

## Approach

1. Extend the repository contract with target/overwrite arguments.
2. Decode and validate the complete archive before mutation.
3. In one SQLite transaction, revalidate counts, enforce target conflicts,
   reconstruct the chat, strictly insert every decoded message, and delete the
   archive only after exact row-count checks.
4. Prove rollback, collision, overwrite, custom-target and corrupt-count paths
   with SQLite-backed tests.

## Verification

- Focused archive repository/service/provider tests.
- `flutter analyze`.
- Full suite and Android debug APK are green in promoted baseline `53bb4fe`.

## Risks

- Archive/live schemas do not store identical representations; mapping must be
  explicit and strict.
- Existing tests that recreate an empty target chat must opt into overwrite or
  stop creating a conflicting target.

## Status

- **Complete:** repository target/overwrite contract, strict row validation,
  single SQLite transaction, original-message-ID restoration, service
  forwarding/event identity, and regenerated mock contract.
- **Regression evidence:** nine SQLite-backed atomic tests cover implicit
  conflict rejection, explicit overwrite, overwrite rollback, new-target
  rollback, cross-chat ID collision, custom target rewrite, stored/actual
  count mismatch, malformed JSON, contact-FK retention/fallback, and archive
  child cleanup. Existing archive mapping semantics remain unchanged.
- **Promoted verification:** full suite and Android debug APK are green in
  device baseline `53bb4fe`.

---

# Canonical publication + duplicate-clone retirement (Codex, 2026-07-13)

## Goal

Make `%USERPROFILE%\repos\pak_connect` the only PakConnect working clone,
preserve the old compressed state without keeping a second editable checkout,
reconcile remaining public claims and CI defects, and publish the reconciled
history to `AbubakarMahmood/pak_connect` through a normal branch and pull
request.

## Constraints

- Do not force-push or write directly to public `main`.
- Preserve the verified BLE/Noise/identity/database invariants and keep
  device-only claims explicitly gated.
- Do not delete unique ignored evidence or nested reference repositories with
  the duplicate working tree.
- A code or bundled-asset change after `5a2cb8e` requires a new verified
  device-test baseline and APK hash.
- Fresh GitHub Actions on the exact PR head, not an older local run, is the
  public CI authority.

## Facts

- GitHub redirects the old
  `AbubakarMahmood1/pak_connect_final` URL to the current public
  `AbubakarMahmood/pak_connect` repository; there is one remote project.
- The compressed checkout was clean at `79b5c80`. Its five commits are
  patch-equivalent to the canonical replay ending at `e70c7a8`; it had no
  unique tracked semantics. The editable duplicate repository is now retired.
- The canonical branch is a clean descendant of `origin/main`, seven commits
  ahead and zero behind at the start of this pass.
- Every compressed ref is preserved in a verified complete Git bundle. The
  distinct historical test/analyzer/coverage evidence is archived separately
  under `%USERPROFILE%\Documents\repo-archives\pak_connect-compressed-20260713`.
  The complete bundle SHA-256 is
  `ABF2B337E41DDDF2127A0EBEF2C92E263B53FAE9E431D7DC6A75D347BA297AD3`.
- Three clean third-party reference clones were moved intact to
  `%USERPROFILE%\repos\_references`.
- Public `main` began this pass with a stale Flutter CI failure, moving Flutter
  channel, non-fatal analysis, and failure-skipped artifact upload. Those
  defects are fixed and PR #71 passed the pinned Flutter 3.44.4 coverage job
  plus Android and Actions CodeQL before merge.
- The public README, bundled privacy policy, SRS, security, architecture and
  toolchain guidance now distinguish implemented behavior from device-gated,
  deferred and historical claims.
- The current build-input baseline is commit
  `5a2cb8e7d1485687b4529dd3e8c90c1d4f628b95`. On local Flutter 3.41.5 /
  Dart 3.11.3, analysis passed, the uninterrupted suite passed 5,539 tests in
  5m20s; the 9,515,985-byte test log has SHA-256
  `152F6CABA2083675728A7F0A1CDEF6CEA20AA7BDECFE96BDD4C912AE2BAE53FE`.
  The debug APK built at 203,988,403 bytes with SHA-256
  `3A0B32EBBB8255C539C62BDD6ACA077108BC5EEF0D431AAEBA5232FB64E28B50`.
- The first Flutter 3.44 CI run exposed four `use_null_aware_elements`
  analyzer infos that local Flutter 3.41.5 did not report. Commit `5a2cb8e`
  applies the equivalent null-aware collection-element fixes; the prior
  `0c8fa87` build is superseded as a candidate baseline. Exact-head CI passed.
- CI hardening is committed separately as `b32438d`; the green PR #71 checks
  on final head `f094474` are the public CI authority.
- PR #71 merged through a normal merge commit as `f99ed90`; local `main` and
  `origin/main` were synchronized afterward.

## Approach

1. Preserve the duplicate repository and ignored evidence before retirement.
2. Fix the current-Flutter Material issue and align bundled privacy/toolchain
   inputs, with targeted regressions.
3. Reconcile remaining public claims and make CI reproducible/fail-closed.
4. Run analyzer, reachability, focused tests, the full suite, and Android APK
   build; record the resulting code commit as the new device baseline.
5. Push the branch explicitly to `origin`, open a normal PR, inspect/fix its
   GitHub Actions checks, and merge only after required checks are green.
6. Remove stale compressed-remote tracking and retire the duplicate directory,
   then leave the canonical local `main` synchronized to GitHub.

## Verification

- `git bundle verify` and SHA-256 for the compressed archive.
- `flutter pub get`, `flutter analyze --no-pub`.
- `pwsh -NoProfile -File tools/dart_reachability_audit.ps1 -FailOnUnreviewed`.
- Targeted message-bubble/context-menu widget tests.
- Full `flutter test --no-pub` with captured log.
- `flutter build apk --debug --no-pub` and SHA-256.
- `git diff --check`, Markdown link/absolute-path audit.
- Fresh PR Flutter coverage and CodeQL checks on the exact head.
- Final one-working-clone filesystem and remote/upstream audit.

## Risks

- Flutter 3.44 tightened Material assertions that the older local 3.41.5 run
  did not expose.
- The old directory contains reproducible SDK/build caches; retire only after
  preserving non-reproducible refs/evidence and moving the clean reference
  repositories.
- Physical BLE, mobile SQLCipher-at-rest, background delivery, signed release,
  multi-link payload and three-device relay evidence remain outside this
  publication pass.

## Status

- **Complete:** two-repository authority audit and zero-loss archive/move of
  unique useful state.
- **Complete:** Flutter compatibility fix, authenticated final-relay delivery,
  strict BLE/crypto/reachability gates, full-suite verification, and the new
  `5a2cb8e` device-test baseline plus APK/log hashes.
- **Complete:** final public-claim/status reconciliation and exact two-device
  execution checklist.
- **Complete:** final PR-head Flutter/CodeQL checks, normal PR #71 merge, local
  and public `main` synchronization, stale remote/branch removal, and editable
  duplicate-repository retirement.

---

# Canonical reconciliation + FYP readiness (Codex, 2026-07-11)

## Goal

Reconcile the authoritative repository with the freshest preserved work, vet
the inherited BLE/Noise/mesh patch adversarially, close demonstrable defects,
and leave PakConnect with durable architecture/status/device/debt evidence and
a defensible FYP/portfolio readiness verdict.

## Constraints

- Preserve the identity, Noise, mesh, BLE and database invariants in
  `AGENTS.md`.
- Keep the compressed source checkpoint as recovery evidence; make new changes
  only in the canonical repository.
- Prefer focused fixes and red/green regressions over broad rewrites.
- Desktop success cannot substitute for two-device BLE or SQLCipher evidence.
- Do not promote placeholder transports or UI affordances as completed.

## Facts

- Canonical remote is `AbubakarMahmood/pak_connect`; reconciled branch is
  `codex/reconcile-pakconnect`.
- The pre-patch desktop suite passed 5,748 tests and static analysis.
- The post-patch desktop suite passes 5,534 tests in 3m13s. The count changed
  because six isolated dead implementations and their dedicated test clusters
  were removed; output is saved in `flutter_test_latest.log`.
- `flutter analyze --no-pub`, enforced Dart reachability, `git diff --check`
  and runner shell syntax all pass.
- The debug Android APK builds at
  `build/app/outputs/flutter-apk/app-debug.apk` (203,988,860 bytes; SHA-256
  `3B541A9C734977BF43E2621BFE300EB7CB316DFA391430722E6375DD6CF1F040`).
- The exact verified code/test/tooling tree is committed as `979e106`
  (`fix: harden runtime and prune unreachable code`) and has not been pushed.
- No Android device is attached; Windows/Chrome/Edge are visible and Visual
  Studio is absent.
- Desktop database tests can fall back to plaintext SQLite; SQLCipher remains
  a device gate.
- The preserved patch had seven promotion blockers in queue correlation,
  targeted MTU/routing, strict-TDM attempt ownership, resume aliases, active
  link inventory and failure signaling.
- Direct user payload state is global rather than per-link. The safe current
  policy is single-link delivery; exact multi-link control routing does not
  imply multi-link payload readiness.
- Change-log peer replay is explicitly absent from production composition;
  local capture, export/import and bounded pruning remain active.

## Approach

1. Checkpoint the exact source tree and rebase its commits onto canonical main.
2. Establish a clean baseline before changing semantics.
3. Review high-risk diffs as an adversary, add focused regressions, then patch.
4. Promote live architecture/status/device/debt documents from verified code.
5. Reconcile misleading docs/tooling and fix remaining bounded defects.
6. Run full verification, Android build and finally the physical-device matrix.

## Steps

1. **Complete:** preserve compressed source and reconcile canonical history.
2. **Complete:** analyze, run critical suites and capture a full baseline.
3. **Complete for desktop promotion:** harden queue correlation, single-link
   payload containment, shared ACK ownership, BLE routing/TDM, GATT failure
   signaling, reconnect/resume identity and fragment reassembly.
4. **Complete:** maintain the live codebase/runtime/status/device/debt maps.
5. **Complete:** reconcile security/testing/SRS/README/tooling claims and
   close remaining `Now` debt.
6. **Complete for local evidence:** analyzer, reachability enforcement, full
   suite, runner syntax and Android debug APK.
7. **Hardware/environment gate:** two-device BLE, Android SQLCipher-at-rest,
   native background lifecycle, signed release and install evidence.

## Verification

- `flutter analyze --no-pub`: clean
- Focused queue-sync, BLE lifecycle/TDM, messaging, fragment, reveal,
  change-log and broadcast-list suites: green
- Full `flutter test` with output saved to `flutter_test_latest.log`: 5,534
  passed, 0 failed
- `flutter build apk --debug --no-pub`: green
- Two-device Android matrix in
  `docs/testing/DEVICE_VALIDATION_STATUS.md`, executed with
  `docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md`

## Risks

- BLE plugin inbound events do not expose a native connection generation.
- A large formatting delta exists in inherited previously-unformatted tests;
  review semantic diffs with whitespace ignored and commit mechanically where
  practical.
- Native background delivery, release signing and SQLCipher proof remain
  external/device work.
- Multi-link user payloads remain disabled until address/generation,
  handshake identity, Noise readiness and ACK routing are one link-owned
  record.

## Resolved decisions

- Root Node/MCP manifests were orphan research tooling and were removed.
- Whole-library reachability is enforced: 433 runtime libraries plus four
  reviewed test-only/dormant candidates, with zero unreviewed candidates.
- The Group* implementation is a sender-local Broadcast Lists feature, not a
  shared group protocol; product copy and SRS now state that boundary.
- Metadata-only change-log peer replay remains out of production until it has
  authenticated row transport and convergence semantics.

## Closeout boundary

Local implementation and build evidence is green. Final FYP demo/release
readiness is still unproven until the hardware rows in
`docs/testing/DEVICE_VALIDATION_STATUS.md` pass. The objective remains active;
  the next work was device evidence against code baseline `979e106`, not
speculative feature expansion. This closeout is historical and was superseded
  by the 2026-07-13 plan and device-test baseline `5a2cb8e`.

---

# Bug-hunt + fix pass (Claude Fable 5, 2026-07-07)

## Goal
Full review of the codebase; find bugs, vet each with tests, fix. Priority:
queue-sync/gossip correctness for imminent two-device testing.

## Constraints
- Repo invariants per AGENTS.md (identity resolution, handshake phases,
  relay dedup, DB migrations).
- Baseline: flutter analyze clean; 5729 tests passing.
- Working tree already contains uncommitted two-device prep diff; do not
  regress its intent (peer-targeted sync, TDM bringup milestones).

## Facts (verified)
- Opus #1 (KK 96-byte check) and #2 (static key zeroing): already fixed.
- PC-QSYNC-001 (callback wiring), PC-BLE-001, PC-UI-001, PC-TDM-001: fixed
  in working tree.
- Node identity flavors in play: 64-hex ephemeral session key (mesh node id,
  currentSessionId), 64-hex relationship hint (dedup ephemeralHint,
  becomes transport fromNodeId), persistent key. They are distinct strings.

## Confirmed bugs to fix (test-first where feasible)
1. BUG-1 mesh_queue_sync_coordinator.dart:531 — debounce keyed by fromNodeId
   applies to responses; bidirectional sync drops the peer's response ->
   initiator 15s timeout. Fix: debounce inbound *requests* only, in a
   dedicated map (BUG-7: shared _lastQueueSyncAt cross-poisons outbound
   sync attempts).
2. BUG-6 queue_sync_manager.dart:274 — pending sync keyed by targetNodeId
   (currentSessionId) but completed by transport fromNodeId (often the
   relationship hint) -> completer never completes. Fix: alias resolution
   (hasPendingSyncWith + coordinator alias set incl. message.nodeId,
   currentSessionId, theirEphemeralId, theirPersistentKey).
3. BUG-5 coordinator._handleSyncRequest — discards Future<bool> send result;
   failed send burns full 15s timeout. Fix: failPendingSync(nodeId) on false.
4. BUG-2 ble_messaging_service.dart — _resolvePeerAddress only knows
   _nodeIdToAddress (populated after first non-handshake inbound; wrong
   flavor for gossip peerIds) -> peer-targeted queue-sync returns false and
   is dropped on first sync. Fix: resolve via state-manager identity match;
   fall back to global route when no targeted match and exactly one link;
   populate _nodeIdToAddress before processReceivedData.
5. BUG-4 sendQueueSyncMessage can throw through unawaited callers ->
   unhandled async error. Fix: catch, return false.
6. BUG-3 ble_messaging_transport_helper.processWriteQueue — pops a queued
   write then aborts on stale *global* link check: write dropped, its
   completer dangles (await hangs); global check false-negative for
   peer-targeted/server routes. Fix: remove pre-write gate (each write
   self-checks and completes its completer).
7. PC-BLE-003 client_links:50 — markAttempt before duplicate-pending check
   inflates backoff. Fix: reorder.
8. PC-GATT-003 lifecycle_coordinator:414 — central notification handler
   processes any characteristic; filter to message characteristic + 0x2A05.
9. PC-CHLOG-001 app_core:871 — onSendChangeLogToPeer logs as if it
   transmits; make the log honest (transport not implemented).
10. Opus #7 — pruneChangeLog() has zero callers; change_log grows unbounded.
    Fix: invoke during app maintenance.

## Noted, not fixed (documented risks)
- PC-GATT-002 (GATT ACK success on failed parse) needs protocol status refactor.
- PC-DISC-001 dedup/no-hint UX; PC-FRAG-001 legacy 6-char fragment ids (only
  single-chunk path uses legacy fragmenter now).
- Strict-TDM isReady requires MTU event; platforms without peripheral MTU
  events fall back to connect-lock timeout (intent locked by test).
- iOS background timers, placeholder service UUID, AppCore all-or-nothing
  init, groups schema-only.

## Verification
- Per-fix targeted flutter test; flutter analyze; full suite at end
  (capture flutter_test_latest.log).

---

# Deferred-items + cleanup pass (Claude Fable 5, 2026-07-07, round 2)

## Goal
Tackle the previously-deferred items test-first, and bring the repo to
tip-top condition (remove scratch/log cruft). Vet prior-round work first.

## Prior-round vetting
- Noise replay-window shift fix re-reviewed line-by-line (left-shift with
  inter-byte carry, high→low iteration avoids aliasing, zero-fill of low
  bytes, bit-0 marks new highest). Correct. Regression tests green.
- Queue-sync cluster changes coherent; no stale refs after param rename.

## Deferred items — outcomes
1. PC-FRAG-001 (legacy 6-char fragment ids): FIXED. `MessageFragmenter` now
   assigns a random ~64-bit base64url wire id per message (not a truncated
   caller id); `MessageChunk.toBytes` emits it verbatim; header budget made
   dynamic. Wire id is transport-only (reassembly grouping key), never
   correlated to the semantic protocol id. Tests: collision reproduction +
   interleaved-reassembly + updated contract assertions.
2. PC-GATT-002 (GATT ACK on parse failure): FIXED via a bounded protocol
   status. `IBLEMessageHandlerFacade.processingFailedMarker` sentinel emitted
   ONLY from structural `ProtocolMessage.fromBytes` failures + method-level
   catch (NOT from fail-closed decrypt drops — those are legitimately
   not-for-us and must not NACK relay traffic). `processIncomingPeripheralData`
   now returns `InboundProcessStatus`; the peripheral write handler NACKs on
   `failed`, ACKs otherwise. Tests: facade marker end-to-end + coordinator
   NACK/ACK.
3. Placeholder BLE service UUID: FIXED. Replaced the `12345678-...` sample
   with a random UUIDv4 base (effb4bc7-...-e0/e1/e2). Referenced only via
   BLEConstants; no native/hardcoded copies. Both peers must share — lockstep.
4. AppCore all-or-nothing init: LARGELY ALREADY ADDRESSED by the existing
   `runBackgroundStage` degraded-mode wrapper (BLE warm-up / enhanced /
   integrated). Added: `_initializeMonitoring` now degrades gracefully
   (PerformanceMonitor = telemetry, AdaptiveEncryptionStrategy has a sync
   fallback). Critical phases (DB/queue/identity) still fatal by design.
5. iOS background delivery: PARTIAL (Dart-side). On `AppLifecycleState.resumed`
   `main.dart` now calls `meshNetworkingService.reprocessQueuedMessages()` →
   coordinator `reprocessPendingDeliveries()` reuses the connection-ready
   per-peer delivery path to push a backlog stranded by suspended timers.
   Full native background execution (BGTaskScheduler/WorkManager) remains out
   of scope. Tests: resume-flush delivers backlog; no-op without a link.
6. Groups "schema-only": CLAIM OUTDATED. Groups are functional — GroupRepository
   registered unconditionally, GroupMessagingService does real multi-unicast
   (one Noise-encrypted queued message per member), Riverpod providers + 3 UI
   screens, 57 passing tests. Resolution is NPE-safe (service-locator
   fallback). No code change warranted.

## Repo cleanup
- Removed untracked, already-gitignored scratch logs from the working tree
  (root flutter_*.log + assorted *.log, runtime logs/ dir).
- git rm of tracked scratch: validation_outputs/ (20 benchmark files) and
  stray root flutter_01.png. gitignore hardened: binary_payloads/, logs/,
  validation_outputs/.
- LEFT for user decision (surfaced, not deleted): root package.json /
  package-lock.json (MCP tooling: @tavily/core, gemini-mcp-tool — not app
  code), .tmp_flutter_sdk_10/ (local Flutter SDK fallback), and the two
  untracked review notes (pakconnect_*.md).

## Verification
- Per-item targeted flutter test (all green); flutter analyze clean; full
  suite at end.

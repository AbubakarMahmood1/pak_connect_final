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

# PakConnect: Two-Way Gossip Sync — Self-Contained Implementation Prompt

**Use this prompt to give a fresh AI agent the full context needed to implement gossip sync.**

---

## Context for the Agent

I'm working on **PakConnect**, a Flutter/Dart BLE mesh messaging app with end-to-end encryption. The project has AGENTS.md and CLAUDE.md files that provide full project context — **read those first**.

I want to implement **two-way gossip sync** — the ability for two BLE-connected peers to efficiently reconcile their local databases so both sides end up with the same messages, contacts, and chat state. Think of it like `git fetch + merge` between two phones.

## What Already Exists (READ THESE FILES FIRST)

The codebase already has **~80% of the infrastructure** built. Here's what's there:

### 1. GossipSyncManager (584 lines, FULLY FUNCTIONAL)
**File:** `lib/domain/messaging/gossip_sync_manager.dart`
- Periodic sync every 30s (broadcasts "here's what I have" to peers)
- Hash-based fast-path: if queue hashes match → skip sync (98% of the time)
- GCS filter integration (Golomb-Coded Sets): 98% bandwidth reduction for "I have these messages" signaling
- Battery-aware emergency mode: skips periodic sync when battery < 10%
- Handles incoming sync requests: detects which messages peer is missing, sends them
- **Known gap (line 269-273):** Detects missing queued messages but CAN'T actually send them — logs "Would send queued message" instead. Needs QueuedMessage → MeshRelayMessage conversion callback.

### 2. QueueSyncManager (710 lines, FULLY FUNCTIONAL)
**File:** `lib/domain/messaging/queue_sync_manager.dart`
- `initiateSync(targetNodeId)`: rate-limited (60/hr, 30s min interval, 15s timeout)
- `handleSyncRequest()`: compares message IDs, finds missing/excess, sends excess
- `processSyncResponse()`: INSERT OR IGNORE only — no overwrites, deletion is final
- Tracks `_syncInProgress`, `_lastSyncWithNode`, `_pendingSyncs`

### 3. QueueSyncCoordinator (332 lines, core service)
**File:** `lib/core/services/queue_sync_coordinator.dart`
- `calculateQueueHash()`: SHA256 of sorted (messageIds + statuses + timestamps + deleted IDs), cached 30s
- `needsSynchronization(otherHash)`: simple string comparison
- `addSyncedMessage()`: skip if deleted, skip if exists, insert only if new
- `getExcessMessages()` / `getMissingMessageIds()`: set difference operations
- `markMessageDeleted()` + `cleanupOldDeletedIds()`: keeps top 1000 deleted IDs

### 4. MeshQueueSyncCoordinator (orchestrator)
**File:** `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart`
- Bridges BLE connections → sync initiation
- Debounces sync requests (10s)
- Tracks in-flight syncs per peer

### 5. GCSFilter (299 lines, FULLY FUNCTIONAL)
**File:** `lib/domain/utils/gcs_filter.dart`
- Golomb-Coded Set: probabilistic set membership (like Bloom filters but smaller)
- `buildFilter(ids, maxBytes: 512, targetFpr: 0.01)`: 1% false positive, fits in single BLE frame
- `decodeToSortedList()` → `contains()`: O(log n) membership test
- Already used by GossipSyncManager when building sync requests

### 6. change_log Table + 9 Triggers (DB-level change tracking)
**File:** `lib/data/database/database_schema_builder.dart` (lines 421-523)
```sql
CREATE TABLE change_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,     -- 'contacts', 'chats', 'messages'
  operation TEXT NOT NULL,      -- 'INSERT', 'UPDATE', 'DELETE'
  row_key TEXT NOT NULL,        -- primary key of changed row
  changed_at INTEGER NOT NULL   -- milliseconds since epoch
);
```
- 9 triggers: INSERT/UPDATE/DELETE on contacts, chats, messages
- Used by incremental backup (`selective_backup_service.dart`) and restore (`selective_restore_service.dart`)
- Pruning: entries older than 30 days are cleaned up

### 7. Existing Sync Wire Format
**File:** `lib/domain/models/mesh_relay_models.dart` (QueueSyncMessage class)
```dart
class QueueSyncMessage {
  final String queueHash;
  final List<String> messageIds;
  final DateTime syncTimestamp;
  final String nodeId;
  final QueueSyncType syncType;           // request, response, update
  final Map<String, String>? messageHashes;
  final QueueSyncStats? queueStats;
  final GCSFilterParams? gcsFilter;
}
```

### 8. Database Tables for Sync State
```sql
CREATE TABLE queue_sync_state (
  device_id TEXT PRIMARY KEY,
  last_sync_at INTEGER,
  pending_messages_count INTEGER,
  last_successful_delivery INTEGER,
  consecutive_failures INTEGER,
  sync_enabled INTEGER,
  metadata_json TEXT,
  updated_at INTEGER NOT NULL
);

CREATE TABLE deleted_message_ids (
  message_id TEXT PRIMARY KEY,
  deleted_at INTEGER NOT NULL,
  reason TEXT
);
```

### 9. Existing Tests
- `test/gossip_sync_manager_test.dart`
- `test/domain/messaging/gossip_sync_manager_phase12_test.dart`
- `test/domain/messaging/queue_sync_manager_phase13_test.dart`
- `test/domain/messaging/queue_sync_manager_phase11_test.dart`
- `test/core/services/queue_sync_coordinator_simple_test.dart`
- `test/core/messaging/queue_sync_system_test.dart`

## Current Conflict Resolution (Important Limitation)

**Current strategy: First-Write-Wins (INSERT OR IGNORE) + Deletion-is-Final**

| Scenario | Current Behavior |
|----------|-----------------|
| Both nodes have message A | Skip (already exists) |
| Node A has message, Node B doesn't | B gets it via sync |
| Node A deleted message, Node B has it | B's copy survives until A's change_log DELETE propagates |
| Both modify same message status | First-write-wins (no conflict detection) |

**What's NOT implemented:**
- ❌ Vector clocks / logical ordering
- ❌ Timestamp comparison during merge  
- ❌ Three-way merge
- ❌ Conflict detection or resolution
- ❌ Bidirectional change_log exchange during live sync (only used in export/import)

## What Needs To Be Built (The Gap Analysis)

### Gap 1: change_log Exchange During Live P2P Sync
The change_log table captures all changes (INSERT/UPDATE/DELETE) but is only used during file-based export/import. The live gossip sync (GossipSyncManager) only syncs the offline_message_queue — it does NOT sync contacts, chats, or message status changes.

**Need:** During BLE peer sync, exchange change_log entries since last sync with that peer, then replay them.

### Gap 2: QueuedMessage → MeshRelayMessage Conversion
Line 269-273 of gossip_sync_manager.dart: detected missing queued messages can't be sent because there's no conversion from QueuedMessage (queue model) to MeshRelayMessage (wire format).

**Need:** A callback or converter that turns QueuedMessage back into a sendable MeshRelayMessage.

### Gap 3: Bidirectional Sync Protocol
Current sync is **one-directional per round**: Node A says "here's my hash", Node B compares and sends missing messages TO A. But A never sends its excess TO B in the same round (B would need to initiate its own sync later).

**Need:** After B sends missing messages to A, A should also send its excess messages to B in the same session. This makes every connection fully synchronizing.

### Gap 4: Conflict Resolution for Mutable Data
Messages are mostly immutable (content doesn't change), but status fields (read/delivered/failed) and contact fields (name, trust score) DO change. INSERT OR IGNORE silently drops updates.

**Need:** For mutable fields, use last-write-wins (compare `updated_at` timestamps) instead of first-write-wins. This is the simplest correct strategy for a decentralized system.

### Gap 5: Per-Peer Sync Cursor
Currently, sync compares full message sets every time. With change_log, we could track "last synced change_log ID" per peer and only exchange entries since then.

**Need:** Store `last_synced_changelog_id` per peer in `queue_sync_state.metadata_json`. On next sync, only send change_log entries with `id > last_synced_changelog_id`.

## Implementation Plan: 4 Phases

### Phase 1: Bidirectional Sync + Conversion Fix (Small effort)
**Goal:** Make every sync session fully bidirectional and fix the QueuedMessage send gap.

**Sub-tasks:**
- **1A:** Add `onSendQueuedMessageToPeer` callback to GossipSyncManager that accepts QueuedMessage objects and handles conversion externally (in the coordinator layer that has access to both models).
- **1B:** In `handleSyncRequest()`, after sending our excess announcements, also trigger sending excess queue messages via the new callback.
- **1C:** In QueueSyncManager, after `processSyncResponse()` completes (we received missing messages), trigger a "reverse excess send" — send OUR excess messages to the peer.
- **1D:** Add integration test: two GossipSyncManagers with different message sets → after one sync round, both have all messages.

**Files to modify:**
- `lib/domain/messaging/gossip_sync_manager.dart` (add callback, wire up queue message sending)
- `lib/domain/messaging/queue_sync_manager.dart` (add reverse-send in processSyncResponse)
- `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart` (wire new callback)
- New test file for bidirectional sync

**Complexity: 3/10** — straightforward plumbing, no new algorithms.

### Phase 2: change_log Exchange in Live Sync (Medium effort)
**Goal:** During peer sync, exchange change_log entries (including DELETEs) so contacts/chats/messages stay consistent.

**Sub-tasks:**
- **2A:** Add `ChangeLogSyncMessage` model (or extend QueueSyncMessage) carrying serialized change_log entries since a cursor.
- **2B:** Add `last_synced_changelog_id` field to `queue_sync_state` table. Track per-peer.
- **2C:** In GossipSyncManager, after hash-based message sync completes, exchange change_log entries:
  - Query `change_log WHERE id > last_synced_changelog_id_for_this_peer`
  - Send entries to peer as part of sync response
  - Receive peer's entries, replay them (INSERT OR REPLACE for INSERT/UPDATE, DELETE for DELETE)
  - Update `last_synced_changelog_id` for peer
- **2D:** Prune change_log entries older than 30 days (already exists in selective_backup_service — reuse logic).
- **2E:** Handle first-sync case: when `last_synced_changelog_id` is null, do full sync (exchange all entries from last 30 days).
- **2F:** Add tests: change_log exchange, DELETE propagation, first-sync, cursor tracking.

**Files to modify:**
- `lib/domain/models/mesh_relay_models.dart` (new ChangeLogSyncMessage or extend QueueSyncMessage)
- `lib/domain/messaging/gossip_sync_manager.dart` (add change_log exchange phase)
- `lib/data/database/database_schema_builder.dart` (add last_synced_changelog_id to queue_sync_state)
- `lib/data/database/database_migration_runner.dart` (schema migration)
- `lib/data/database/database_helper.dart` (bump version)
- New test file for change_log sync

**Complexity: 5/10** — Moderate. The building blocks exist (change_log table, triggers, replay logic). The new part is wiring them into live P2P sync instead of file export.

### Phase 3: Last-Write-Wins Conflict Resolution (Small-Medium effort)
**Goal:** When syncing mutable data (message status, contact info), use timestamp comparison instead of INSERT OR IGNORE.

**Sub-tasks:**
- **3A:** In `addSyncedMessage()` (queue_sync_coordinator.dart), when message already exists: compare `updated_at` timestamps. If incoming is newer, UPDATE the existing row's mutable fields (status, delivery_receipt, read_receipt, reactions). Immutable fields (content, sender, timestamp) are NEVER overwritten.
- **3B:** In change_log replay for contacts: compare `updated_at` before applying UPDATE operations. Newer wins.
- **3C:** For DELETE conflicts (deleted on A, modified on B): **deletion wins** (already the current behavior, and correct for a messaging app — if someone deleted a message, respect that).
- **3D:** Add conflict counter metric to sync stats (how many conflicts resolved per sync).
- **3E:** Add tests: concurrent modification, newer-wins, deletion-wins, immutable field protection.

**Files to modify:**
- `lib/core/services/queue_sync_coordinator.dart` (timestamp comparison in addSyncedMessage)
- `lib/domain/messaging/gossip_sync_manager.dart` (timestamp comparison in change_log replay)
- Sync stats models
- New test file for conflict resolution

**Complexity: 4/10** — LWW is the simplest correct conflict resolution. No vector clocks needed.

### Phase 4: Merkle Tree Optimization (OPTIONAL — Medium-High effort)
**Goal:** Replace full hash comparison with per-table Merkle trees for O(log n) sync diff detection.

**Why this is optional:** The GCS filter already provides 98% bandwidth reduction. Merkle trees add value only when databases are large (10k+ messages) and you want to detect WHICH subtree differs without exchanging full ID lists. For PakConnect's typical use (hundreds to low thousands of messages on a BLE mesh), the current hash + GCS approach is probably sufficient.

**Sub-tasks (if you choose to implement):**
- **4A:** Define Merkle tree structure: partition messages by timestamp ranges (e.g., hourly buckets). Each bucket's hash = SHA256(sorted message hashes in that hour). Root hash = SHA256(all bucket hashes).
- **4B:** Create `MerkleTreeBuilder` service that maintains a cached tree, updating incrementally as messages arrive.
- **4C:** Sync protocol becomes: exchange root hashes → if different, exchange bucket hashes → only sync buckets that differ.
- **4D:** Store cached Merkle tree state in DB (avoid recomputing on every sync).
- **4E:** Tests for tree construction, incremental update, diff detection, sync integration.

**Files to create:**
- `lib/domain/utils/merkle_tree.dart` (tree data structure + builder)
- `lib/domain/services/merkle_sync_service.dart` (sync protocol using Merkle diffs)
- Test files

**Complexity: 7/10** — This IS the "research-grade" part. But it's well-studied (git, IPFS, Cassandra all use variants). The algorithm is straightforward; the complexity is in maintaining the tree incrementally and handling edge cases (clock skew, bucket boundaries, partial syncs).

## Feasibility / Practicality / "Can I Debug This?" Assessment

| Phase | Difficulty | Can You Debug It? | Is It Worth It? |
|-------|-----------|-------------------|-----------------|
| Phase 1 (bidirectional) | Easy | ✅ Yes — it's just callbacks and set operations | **Yes** — fixes a real functional gap |
| Phase 2 (change_log sync) | Medium | ✅ Yes — builds on existing change_log + replay logic | **Yes** — enables DELETE propagation and contact sync |
| Phase 3 (LWW conflicts) | Easy-Medium | ✅ Yes — timestamp comparisons, very debuggable | **Yes** — prevents data staleness |
| Phase 4 (Merkle tree) | Medium-High | ⚠️ Somewhat — tree algorithms are trickier to debug | **Maybe** — only worth it at scale (10k+ messages) |

**My recommendation:** Do Phases 1-3. They're all standard engineering (callbacks, SQL queries, timestamp comparisons). Skip Phase 4 unless you hit performance issues with the current hash+GCS approach at scale.

**"Research-grade" clarification:** I used that phrase loosely. Phases 1-3 are **standard distributed systems engineering** — the same patterns used in every sync app (Dropbox, iCloud, Signal). Phase 4 (Merkle trees) is also well-understood but is the only one that requires implementing a non-trivial data structure from scratch. None of this is uncharted territory. You will NOT be the first person solving these problems.

## Architecture Rules (MUST follow)

1. **Layer boundary**: Domain models can't import from core. Pure data → `lib/domain/models/`, business logic → `lib/domain/messaging/` or `lib/domain/services/`, infrastructure → `lib/core/`.
2. **Test harness**: DB tests need `TestSetup.initializeTestEnvironment(dbLabel: ...)`. BLE tests use `IBLEPlatformHost` seam.
3. **DB migrations**: New schema → bump version in `database_helper.dart`, add migration in `database_migration_runner.dart` with `IF NOT EXISTS` guards.
4. **Logging**: Use `logging` package with emoji prefixes (🔄 for sync, 📡 for network, ✅ for success).
5. **Test patterns**: Arrange-Act-Assert. Use `allowedSeverePatterns` for expected SEVERE logs. Target >80% coverage.
6. **Git**: Conventional commits (`feat:`, `fix:`). Include `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.

## Current Test Baseline
- **5634 pass, 1 skip, 0 failures** (after gas fees commit `3078487`)
- DB schema version: **11**
- Run with: `flutter test` (NOT `dart test`)

## Start Here
1. Read `AGENTS.md` and `CLAUDE.md`
2. Read the existing files listed above (especially gossip_sync_manager.dart and queue_sync_manager.dart)
3. Run existing gossip/queue sync tests to verify baseline
4. Implement Phase 1 first (smallest, most impactful)
5. Run full test suite after each phase

---

*Generated from PakConnect security hardening session, March 2026. All prior commits on main.*

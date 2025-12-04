# ID Types Migration Summary (Phase 3 Status)

## Current status
- Phases 1–2 are delivered, and Message/Chat value objects now flow through domain entities, repositories, and UI/service layers; storage/DTO boundaries unwrap via `.value`.
- Analyzer baseline: `flutter analyze --no-pub` passes.
- Checkpoints: `.progress_backup.patch` (pre-queue retype) and `id_migration_checkpoint2.patch` (pre-ChatId-cache) remain as fallbacks.

## Active TODO (current + next)
- [ ] Current: Audit remaining transport/mesh DTO callers that still pass raw string IDs and add wrap/unwrap adapters where missing.
- [ ] Next: Refresh documentation (progress percentages, remaining hotspots) now that `UserId` helpers and contact/pairing controllers are typed.

## Completed scope
- Value object infrastructure + unit tests (`test/domain/values/id_types_test.dart`).
- Archive domain/repo/UI use `ArchiveId` throughout.
- Message/EnhancedMessage constructors take `MessageId`; repositories, DTOs, and migrations map to string storage; boundary serialization uses `.value`.
- Chat and message entities/repos/UI/services now accept `ChatId`/`MessageId` (chat session state, pinning cache, retry coordination, home/chat facades) and unwrap only at persistence/logging boundaries.
- Queue → repository delivery paths now persist `reply_to_message_id` using `MessageId` (AppCore, MeshQueueSyncCoordinator) and queue persistence normalizes reply IDs before writing; deleted-ID tracking uses `MessageId` in-memory while persisting strings.
- Contact exposes typed accessors (`userId`, `persistentUserId`, `chatUserId`, `chatIdValue`) and the contact repository adds typed lookups; regression coverage added in `test/domain/entities/contact_id_wrappers_test.dart`.
- Identity/pairing flows and providers expose `UserId` helpers (IdentitySessionState, IIdentityManager extension setters, contact provider delete path) while keeping string entry points for compatibility.
- Protocol envelope and mesh relay/queue sync DTOs expose typed helpers/constructors for `MessageId`/`ChatId` while keeping wire payloads string-based.
- Queue sync/offline queue bridges and retry scheduler adapters wrap inbound IDs to `MessageId` and emit strings on transport; fragmentation/BLE handlers, mesh interfaces/results, and routing/logging helpers expose typed wrappers while keeping public APIs string-based.
- Mesh relay internals expose typed callbacks/helpers (engine, handler, send pipeline, decision engine, gossip manager) so relay processing can use `MessageId` while emissions/logging stay string-based.
- Group providers/repo now expose typed adapters for message delivery updates (`MessageId`/`ChatId`) while keeping storage string-based.
- BLE send paths and queue sync handlers emit both string and typed callbacks (MessageId/ChatId) for observability; router results now include typed factories.

## Remaining gaps (Phase 3)
- Transport/mesh/BLE DTOs and handlers still surface string IDs (protocol envelope, mesh relay models, fragmentation, BLE handlers, queue/mesh service interfaces); they need adapters that wrap on inbound and unwrap on outbound.
- Mesh networking interfaces/results and routing/logging utilities still expect strings; internal handling should move to value objects with string logging only.
- Documentation should be refreshed with updated progress and coverage after each slice.

## Boundary strategy for Phase 3
- Keep public queue/mesh interfaces string-based until >80% of consumers are migrated; wrap/unwrap at boundaries rather than changing signatures prematurely.
- Migrate in tiny slices (one helper/mapper at a time). For each slice: add adapters to wrap incoming strings to `MessageId`/`ChatId` internally, unwrap with `.value` on outbound, then run `flutter analyze --no-pub` immediately.
- Defer mesh/BLE DTO changes until queue/pinning/retry slices are stable to avoid multi-surface breakage.
- Use `.progress_backup.patch` only as reference; do not reapply wholesale.

## Suggested next slices
1. Protocol envelope and mesh relay DTO adapters (wrap on inbound, unwrap on outbound) while keeping wire payloads as strings.
2. Queue sync/offline queue bridges and retry scheduler adapters to hold `MessageId` in-memory but emit string payloads.
3. Fragmentation/BLE handlers and mesh interfaces/results to add typed helpers, keeping public APIs stringly until consumers are migrated.
4. Propagate `UserId` through identity/contact/auth flows once message/chat transport surfaces are adapted.

## Progress estimate
- Overall migration progress: roughly 70–75% complete; remaining work centers on transport/DTO adapters, mesh/queue interfaces, and `UserId` propagation.

## Testing guidance
- Run `flutter analyze --no-pub` after each slice; for queue/pinning changes, also run the relevant tests (`test/message_repository_sqlite_test.dart`, `test/chats_repository_sqlite_test.dart`, queue/pinning suites) to catch regressions early.

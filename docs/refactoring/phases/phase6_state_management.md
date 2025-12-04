# Phase 6 – State Management Audit (current codebase)

## Snapshot
- Scope: production code under `lib/` (tests/mocks noted separately). Source: fresh `rg` scan across modules.
- Metrics: 22 prod files declare `StreamController` (~57 definitions / 70 hits); 51 prod files use `Timer` (295 hits); 17 prod files use `StreamSubscription` (25 hits). Tests/mocks add ~10 more controller-bearing files.
- State: core runtime notifiers exist (`appBootstrapProvider`, `bleRuntimeProvider`, `meshRuntimeProvider`, `securityStateProvider`), but UI/screen controllers still own timers/subscriptions directly. New controllers/timers introduced in Phase 0-5 (home_screen_facade tests, chat list coordinator, topology manager, mesh monitor, archive/batch timers, etc.) remain manual.

## Manual StreamControllers – ownership, lifecycle, disposal notes
- BLE stack (core/data):
  - `lib/data/services/ble_service_facade.dart` – orchestrator owns broadcast controllers for connection info, discovery results, hint matches, handshake spy/identity; closed in `dispose`, but lifecycle is manual and presentation subscribes directly.
  - `lib/data/services/ble_connection_service.dart`, `ble_discovery_service.dart`, `ble_messaging_service.dart`, `ble_handshake_service.dart`, `lib/core/bluetooth/handshake_coordinator.dart`, `lib/core/bluetooth/bluetooth_state_monitor.dart` – subservices expose broadcast streams for state/handshake; disposal occurs only when the caller invokes `dispose`/`disposeHandshakeCoordinator`.
  - `lib/core/scanning/burst_scanning_controller.dart` – broadcast status stream with timers; disposed via `AppCore` teardown.
  - `lib/core/discovery/device_deduplication_manager.dart` – static broadcast of deduped devices; no dispose path (lifetime = process); risk of stale listeners across hot restarts.
- Messaging/mesh/topology:
  - `lib/domain/services/mesh/mesh_network_health_monitor.dart` – mesh/relay/queue/delivery broadcasts; manual `dispose`, not tied to provider lifecycle.
  - `lib/core/networking/topology_manager.dart`, `lib/core/routing/network_topology_analyzer.dart` – topology broadcasts plus cleanup timers; dispose methods exist but depend on manual invocation.
  - `lib/core/app_core.dart` – status broadcast; closed in `dispose`/`resetForTesting`.
- Chat/presentation-facing services:
  - `lib/core/services/chat_connection_manager.dart`, `chat_list_coordinator.dart`, `home_screen_facade.dart`, `lib/presentation/services/chat_interaction_handler.dart` – broadcast connection/unread/intent streams; each closes in `dispose` but currently owned directly by UI facades/controllers.
  - `lib/domain/services/archive_management_service.dart`, `archive_search_service.dart`, `chat_notification_service.dart`, `lib/core/services/pinning_service.dart` – broadcast updates; disposal is manual per service owner.
  - `lib/data/repositories/user_preferences.dart` – static broadcast for username propagation; explicit static `dispose` exists but is not automatically invoked, so listeners can persist for the app lifetime.
- Notes on tests/mocks: additional controllers live in `test/*` fakes (BLE platform/service facades, chat screen controller tests, mesh queue sync tests) and mirror the prod patterns.

## Timers – ownership and lifecycle highlights
- Presentation/UI:
  - `lib/presentation/controllers/home_screen_controller.dart` – refresh + search debounce timers; manual cancel in `dispose`.
  - `lib/presentation/controllers/chat_screen_controller.dart` – mesh init timeout timer and other screen-level timers; cancelled manually.
  - `lib/presentation/controllers/discovery_overlay_controller.dart`, `chat_search_bar.dart`, `relay_queue_widget.dart`, `archive_screen.dart`, `archive_detail_screen.dart`, `contacts_screen.dart`, `permission_screen.dart` – debounce/poll/cleanup timers owned by widgets/controllers.
- Core/data/services:
  - Retry/batch/polling: `core/services/retry_scheduler.dart`, `core/discovery/batch_processor.dart`, `data/services/relay_coordinator.dart`, `data/services/contact_status_sync_controller.dart`, `data/services/contact_request_controller.dart`, `data/database/database_query_optimizer.dart`.
  - BLE/handshake lifecycle: `core/bluetooth/handshake_timeout_manager.dart`, `core/bluetooth/connection_cleanup_handler.dart`, `core/bluetooth/bluetooth_state_monitor.dart`, `data/services/ble_state_coordinator.dart`, `data/services/ble_discovery_service.dart`, `data/services/ble_message_handler.dart`.
  - Mesh/queue: `core/messaging/gossip_sync_manager.dart`, `core/messaging/queue_sync_manager.dart`, `core/messaging/offline_message_queue.dart`, `core/messaging/message_ack_tracker.dart`, `core/routing/smart_mesh_router.dart`, `core/routing/connection_quality_monitor.dart`, `core/networking/topology_manager.dart`, `core/routing/network_topology_analyzer.dart`.
  - Message routing/fragmentation: `data/services/ble_message_handler_facade.dart`, `ble_message_handler_facade_impl.dart`, `data/services/ble_message_handler.dart`, `data/services/message_fragmentation_handler.dart`, `core/interfaces/i_retry_scheduler.dart` (interface keeps Timer contracts).
  - Power/performance: `core/power/adaptive_power_manager.dart`, `core/power/battery_optimizer.dart`, `core/security/background_cache_service.dart`, `core/security/spam_prevention_manager.dart`, `core/performance/performance_monitor.dart`.
  - Pairing/lifecycle: `data/services/pairing_request_coordinator.dart`, `pairing_service.dart`, `pairing_ui_orchestrator.dart`, `data/services/connection_health_monitor.dart`, `data/services/ble_connection_manager.dart`.
  - Archive/auto archive: `domain/services/auto_archive_scheduler.dart`, `presentation/providers/archive_provider.dart` (poll), `presentation/screens/archive_*` still poll for updates.
  - Lifecycle: most timers are cancelled in `dispose` methods, but ownership is spread across services and UI (not yet ref-managed), leaving room for missed cancellation when screens/services are recreated.

## StreamSubscriptions – ownership and lifecycle highlights
- UI/home/chat flows:
  - `home_screen_facade.dart` (intent subscription), `home_screen_controller.dart` (peripheral connection, connection info, discovery data, global message streams), `chat_screen_controller.dart` (message/delivery streams), `discovery_overlay.dart` widget – all manually cancelled in `dispose`.
  - `persistent_chat_state_manager.dart` – holds per-chat subscriptions and buffers; relies on manual cleanup (`cleanupChatListener`/`cleanupAll`), not provider-scoped.
- Core/services:
  - `burst_scanning_controller.dart`, `chat_connection_manager.dart`, `chat_list_coordinator.dart`, `battery_optimizer.dart`, `mesh_queue_sync_coordinator.dart`, `ble_handshake_service.dart`, `ble_connection_manager.dart`, `ble_discovery_service.dart`, `presentation/providers/archive_provider.dart` – manual cancellation in `dispose`/teardown.
- Riverpod runtime (ref-managed): `presentation/providers/runtime_providers.dart`, `ble_providers.dart`, `mesh_networking_provider.dart` use `ref.onDispose` to cancel subscriptions; safer but still new code paths to monitor.
- Observations: disposals are present but rely on callers; screen controllers/widgets still bypass provider lifecycles, so leaks remain possible when screens are recreated or services are re-instantiated.

## Gaps and risks to carry into Phase 6 refactor
- Static/long-lived controllers without lifecycle binding: `DeviceDeduplicationManager` and `UserPreferences.usernameStream` never close unless explicitly disposed; `PersistentChatStateManager` keeps subscriptions until cleanup is called.
- UI still owns timers/subscriptions; presentation widgets touch core BLE/mesh controllers directly rather than via providers.
- Service disposals depend on manual calls (e.g., mesh network health monitor, topology manager/analyzer); missing provider-scoped teardown could keep streams/timers alive after feature exit.
- New controllers/timers introduced since the prior estimate (home_screen_facade, chat_list_coordinator, topology manager, mesh health monitor, archive/batch handlers) need inclusion in upcoming refactors.

## Milestone status
- Audit & ownership map: refreshed above with current counts and owners (this document).
- Riverpod standardization: core runtime notifiers (`appBootstrapProvider`, `bleRuntimeProvider`, `meshRuntimeProvider`, `securityStateProvider`) exist and use `ref.onDispose`, but UI still wires manual timers/subscriptions on top.
- Screen controller conversions: largely complete; `home_screen_controller.dart` and `chat_screen_controller.dart` now flow through `ChangeNotifierProvider.autoDispose` (Riverpod-driven rebuilds + lifecycle disposal), Archive screen dropped UI debounce timer in favor of provider debouncing, Contacts search routes through provider debounced queries, Permission screen timeout lives in an `AutoDisposeNotifier` (timer lifecycle managed), Archive detail search dialog no longer owns a debounce timer, and chat search bar removed its widget-owned debounce `Timer`. Remaining: timers inside chat/home scrolling controllers are still manual and should be migrated in the manual timer removal milestone.
- Manual stream/timer removal: presentation-owned timers are eliminated (home screen search/refresh timers removed; archive detail and chat search bar debounces removed; relay queue loading timeout removed; permission timeout is provider-managed). Remaining timers live inside controller classes (`chat_scrolling_controller.dart`, `home_screen_controller.dart` unread stream periodic) and provider-managed notifiers; lifecycle is scoped and cleaned via `ref.onDispose`/`dispose`.
- Performance/UX (pagination/off-thread work): pagination hooks added to `IChatsRepository.getAllChats` and `IArchiveRepository.getArchivedChats` (limit/offset); Home uses paged loading (page size 50) with infinite scroll + spinner; Archive uses paged loading (page size 25) with infinite scroll; periodic refresh removed; Home load/init now batches startup with `Future.wait`, and `PerformanceMonitor` instruments chat list loading.
- Performance/UX (pagination/off-thread work): not started.

## Next milestone (20% → Screen controller conversions)
- Target: move Home/Chat/Archive/Contacts timers/subscriptions into Riverpod `StateNotifier`/`AsyncNotifier` with `ref.onDispose`, and convert widgets to `ConsumerWidget` listeners to drop manual `StreamController`/`Timer` ownership in the UI layer.

## ADR-006: Replace Manual StreamControllers with Riverpod Notifiers
- **Status**: Accepted  
- **Date**: 2026-02-09  
- **Context**: 20+ services/widgets own `StreamController`/`StreamSubscription`/`Timer` lifecycles manually, leading to leaks when screens are recreated and complicating testing. Riverpod providers already wrap runtime state (`bleRuntimeProvider`, `meshRuntimeProvider`, etc.) with `ref.onDispose`.
- **Decision**: New and refactored state flows should be exposed via Riverpod notifiers (StateNotifier/AsyncNotifier/StreamProvider) instead of ad-hoc `StreamController`. Controllers that must consume external streams should wrap them in providers and manage subscriptions with `ref.onDispose`.
- **Rationale**: 
  1) Lifecycle safety: provider scope handles dispose, reducing leaks.  
  2) Testability: providers are override-friendly; no manual controller wiring in tests.  
  3) Consistency: unified access pattern for UI and services; fewer bespoke listeners.  
  4) Observability: provider-based state is easier to mock/trace in harness.
- **Consequences**: 
  - Migration effort to wrap existing controllers (BLE facade, chat/home controllers, archive services) in providers.  
  - Temporary shims needed while legacy `StreamController` APIs remain; mark them `@visibleForTesting` or `@deprecated` once wrapped.  
  - Provider scopes must be available in headless services (fallback: create scoped containers in service factories).
- **Alternatives**: 
  - Keep manual controllers and standardize disposal checklists (rejected: still leak-prone).  
  - Introduce an event-bus wrapper (rejected: adds indirection without lifecycle guarantees).  
  - Use `ValueNotifier`/`ChangeNotifier` only (rejected: less suitable for async/stream-heavy flows).
- **Implementation Plan**:
  1) Add provider wrappers for controller-like services (BLE facade, mesh health monitor, archive search) with `ref.onDispose`.  
  2) Redirect UI/controllers to consume provider state instead of raw streams; delete direct `StreamController` fields.  
  3) Deprecate legacy stream getters; keep thin adapters for backward compatibility during rollout.  
  4) Update tests to override providers instead of injecting fake controllers; remove manual controller cleanup in fixtures.  
  5) Lock production logging to provider state changes (riverpod observers) instead of per-message stream logs.

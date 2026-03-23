# DI Unification Roadmap (0-100%)

**Last Updated**: 2026-03-24 (checkpoint 7 final cleanup)

---

## Progress Scale

- 0-5%: Pass 0 (baseline and guardrails)
- 5-15%: Pass 1 (presentation DI firewall)
- 15-30%: Pass 2 (single runtime owner, no provider side-effects)
- 30-45%: Pass 3 (constructor-first domain/core)
- 45-60%: Pass 4 (explicit composition root object)
- 60-75%: Pass 5 (test DI unification)
- 75-90%: Pass 6 (BLE/mesh runtime hardening)
- 90-100%: Pass 7 (cleanup and policy lock)

---

## Pass Status

| Pass | Progress Band | Status | Goal |
|---|---:|---|---|
| Pass 0 | 0-5% | Complete | Baseline metrics + DI guardrails |
| Pass 1 | 5-15% | Complete | No direct `GetIt` usage in presentation code paths |
| Pass 2 | 15-30% | Complete | Remove provider-driven global register/unregister patterns |
| Pass 3 | 30-45% | Complete | Constructor-first dependency flow in core/domain |
| Pass 4 | 45-60% | Complete | `AppServices` composition root + provider wiring |
| Pass 5 | 60-75% | Complete | Test strategy convergence (provider overrides first) |
| Pass 6 | 75-90% | Complete | Connection runtime serialization hardening |
| Pass 7 | 90-100% | Complete | Remove legacy fallbacks, enable strict guardrails |

---

## Latest Snapshot (Historical Pass 7 Baseline)

Source: `validation_outputs/di_pass7_snapshot.json`

This snapshot predates the final registry cleanup completed on 2026-03-24.
Use the checkpoint notes below for the current end state.

- `GetIt` resolutions in `lib/**`: 43
- `.instance` usages in `lib/**`: 24
- `GetIt` resolutions in `lib/presentation/**`: 2
- `get_it` imports in `lib/presentation/**`: 1 file (`di_providers.dart`)
- Presentation import guard violations: 0
- Presentation DI mutation sites (`register*`/`unregister`): 0

Residual `.instance` usage is now primarily framework/plugin access
(`WidgetsBinding.instance`, `SharePlus.instance`) plus explicit DI boundary
files (`service_locator.dart`, `di_providers.dart`).

Pass 3 progress highlights:

- Constructor-first composition added for `ContactManagementService`,
  `ArchiveManagementService`, `ArchiveSearchService`, and
  `ChatManagementService`.
- `AppCore` now composes these services explicitly and installs singleton
  instances, reducing hidden global lookups.
- `AutoArchiveScheduler` now uses explicit app-composed dependencies instead of
  internal global resolution.
- Notification handler creation is now prefs-injected through
  `NotificationHandlerFactory` from both app boot and settings toggle paths.
- Message retry orchestration now requires explicit `IRepositoryProvider`
  injection from the caller.
- Hint cache and device dedup intro-hint resolution now use configured
  repositories instead of direct global lookup.
- `MessageRouter` no longer resolves preferences/shared queue dependencies via
  internal `GetIt` lookups; these are configured at composition/harness edges.
- `MeshNetworkingService` now requires explicit `IRepositoryProvider` and
  `ISharedMessageQueueProvider` constructor dependencies.
- `ArchiveManagementService`, `ArchiveSearchService`,
  `ContactManagementService`, and `ChatManagementService` legacy singleton
  fallbacks are now resolver-configured from composition/harness code rather
  than directly reading `GetIt` internally.
- `MeshRelayEngine`/`RelayDecisionEngine` no longer perform internal `GetIt`
  fallback resolution for repository/seen-store/identity paths; those are now
  configured at AppCore/test harness edges.
- `HandshakeCoordinator` and `SmartHandshakeManager` now resolve repository
  dependencies via composition-configured resolvers instead of internal
  `GetIt` fallback lookups.
- `SecurityManager` now resolves optional contact repository fallback via
  composition-configured resolver hooks, not internal `GetIt` access.
- `RelayCoordinator`, `MeshRelayHandler`, `ProtocolMessageHandler`, and
  `EphemeralContactCleaner` now use resolver hooks configured by the data DI
  registrar instead of internal `GetIt.instance` lookups.
- `BLEHandshakeService`, `BLEMessageHandlerFacade`,
  `BLEMessageHandlerFacadeImpl`, and `BLEServiceFacade` now use explicit
  resolver/registrar hooks for legacy fallback paths in place of internal
  `GetIt.instance` reads.
- `AppCore` now exposes a typed `AppServices` composition snapshot scaffold and
  reuses app-composed repository/security references, cutting additional
  composition-root locator calls.

Pass 4 progress highlights:

- `AppCore` now publishes a typed `AppServices` snapshot through DI after
  successful bootstrap, enabling provider-layer composition access.
- Presentation DI helpers now support `AppServices`-first resolution with
  service-locator fallback for lifecycle-safe migration.
- Provider wiring migrated to consume `AppServices` first for core seams:
  `IConnectionService`, `IMeshNetworkingService`, contact and preferences
  repositories, and mesh health access.
- `AppServices` now carries additional stable app-composed seams
  (`IChatsRepository`, `ISharedMessageQueueProvider`), and `AppCore` reuses
  those composed references across core startup flows.
- Provider wiring migration expanded to runtime/chat/group seams:
  `runtime_providers.dart`, `pinning_service_provider.dart`,
  `chat_messaging_view_model.dart`, plus partial group-provider migration
  (contact/shared queue paths).
- Screen-level DI resolution now follows the same `AppServices`-first path for
  core chat/group/home flows (`chat_screen.dart`, `create_group_screen.dart`,
  `group_chat_screen.dart`, `home_screen.dart`, `qr_contact_screen.dart`),
  removing direct locator guard checks from those entry points.
- Additional presentation resolver paths (settings/profile/discovery overlays
  and import/export dialogs) now route through centralized DI helpers rather
  than local `getServiceLocator()` checks, reducing ad-hoc DI access points.
- Chat lifecycle helpers (`chat_interaction_handler.dart`,
  `chat_retry_helper.dart`, `chat_session_lifecycle.dart`) now resolve shared
  queue/repository-provider dependencies through AppServices-aware optional
  resolvers instead of direct locator availability checks.
- Presentation direct `getServiceLocator()` usage is now isolated to
  `di_providers.dart`; all other presentation paths consume the centralized DI
  helper APIs.

Pass 5 progress highlights:

- Test harness now registers an `AppServices` snapshot after DI bootstrap and
  after test DI overrides (`TestSetup.initializeTestEnvironment` and
  `TestSetup.configureTestDI`), so provider tests read the same composition seam
  used by runtime code.
- `AppServices` mesh seam moved to the interface contract
  (`IMeshNetworkingService`) with an explicit `MeshNetworkHealthMonitor`
  field, reducing test coupling to concrete mesh runtime types.
- Added harness-safe fallback doubles for missing runtime-only services
  (`_NoopMeshNetworkingService`, `_NoopSecurityService`, `MockConnectionService`)
  so tests can progressively override only what they need.
- Presentation mesh health provider now resolves directly from
  `AppServices.meshNetworkHealthMonitor`, removing a concrete-type dependency
  chain from provider DI resolution.
- `test/presentation/controllers/home_screen_controller_test.dart` no longer
  mutates global locator state via `configureTestDI`; dependencies are injected
  locally through constructor/provider wiring.
- `test/core/di/phase3_integration_flows_test.dart` dropped its legacy
  `configureTestDI()` bootstrap; all test suites now use
  `initializeTestEnvironment(...)` as the shared DI baseline.

Pass 6 progress highlights:

- `BLEServiceFacade` now tracks runtime owner lifecycle (`instanceId`,
  live-instance counter) and logs split-brain risk when multiple owners exist.
- Added optional strict singleton guard for debug sessions via
  `PAKCONNECT_BLE_STRICT_SINGLETON_GUARD`.
- Added connection-info subscription counters to expose duplicate listener
  patterns and underflow issues in teardown paths.
- Disposal flow now accounts for listener removal and owner disposal in a
  `finally` path, improving lifecycle observability without behavior changes.
- Bluetooth monitor callbacks now run behind a lifecycle-epoch guard so stale
  async callbacks from previous facade epochs are ignored.
- Connection operations (`connectToDevice`/`disconnect`) now execute through a
  facade-level serialized queue so overlapping connect attempts cannot run
  concurrently.
- Duplicate in-flight connect calls for the same target address now join the
  active operation, reducing duplicate dial races.
- Added explicit overlapping-connect regression coverage in
  `test/data/services/ble_service_facade_test.dart` with central manager
  concurrency tracking to enforce one-at-a-time connect execution.
- `BleConnectionTracker` now exposes read-only cooldown introspection
  (`retryBackoffRemaining`, `nextAllowedAttemptAt`, `pendingAttemptCount`),
  and reconnect/tie-break code paths log deterministic cooldown + token
  comparison context for runtime verification.
- Feature-flagged post-disconnect reconnect cooldown enforcement is now active
  (`PAKCONNECT_BLE_ENFORCE_POST_DISCONNECT_COOLDOWN`, default `true`) and
  preserved across connection-state cleanup transitions to reduce reconnect
  thrash after disconnect.
- Client connect runtime now uses attempt-scoped stale guards across async
  stages, so stale failure/finalizer callbacks from old attempts cannot tear
  down newer active flows.

Pass 7 progress highlights:

- BLE facade lifecycle tests now await disposal and avoid ad-hoc secondary
  facade instances, making strict singleton validation reliable within the
  suite.
- Strict singleton guard mode (`PAKCONNECT_BLE_STRICT_SINGLETON_GUARD=true`)
  now passes for the full `ble_service_facade_test.dart` suite, establishing a
  stable policy lock baseline before CI wiring.
- CI now enforces the strict singleton guard suite via
  `.github/workflows/flutter_coverage.yml` and publishes
  `ble_strict_singleton_latest.log` as an artifact for regression triage.
- `SecurityServiceLocator` no longer supports implicit fallback instance
  registration; runtime/tests now use explicit resolver configuration,
  reducing a legacy global escape hatch.
- Presentation providers now resolve app-composed management services through
  `AppServices` first (`ContactManagementService`, `ChatManagementService`,
  `ArchiveManagementService`, `ArchiveSearchService`) instead of direct
  singleton `.instance` access in those provider paths.
- Test harness `AppServices` snapshot wiring now composes and publishes the
  same management-service seams so provider/runtime DI behavior stays aligned
  under test.
- Presentation chat flows now resolve `ISecurityService` through
  `resolveFromAppServicesOrServiceLocator(...)` (AppServices-first) instead of
  direct `SecurityServiceLocator.instance` calls in chat screen/controller/view
  model paths.
- `MessageRouter.instance` call sites were removed from presentation paths;
  chat lifecycle/viewmodel code now uses optional router access
  (`MessageRouter.maybeInstance`) with existing fallback initialization logic.
- `OutboundMessageSender` now resolves security operations through an injected
  `ISecurityService` dependency (defaulted once at construction), replacing
  repeated static security locator calls across outbound send paths.
- `InboundTextProcessor` now also uses an injected `ISecurityService`
  dependency (defaulted once during construction), replacing repeated static
  security locator usage in inbound decrypt + identity-mapping paths.
- Pairing orchestration services now inject `ISecurityService` once per class
  and resolve it lazily at use-sites (`PairingLifecycleService`,
  `PairingFailureHandler`, `PairingRequestCoordinator`), reducing repeated
  static security locator access while preserving test harness behavior.
- `ProtocolMessageHandler` now takes an explicit `ISecurityService`
  dependency, and `BLEMessageHandlerFacade` supplies/uses that shared service
  for protocol decrypt + binary payload decrypt paths.
- Security locator callsites migrated from singleton-style
  `SecurityServiceLocator.instance` to explicit
  `SecurityServiceLocator.resolveService()` across remaining data/BLE paths,
  preserving behavior while reducing singleton access footprint.
- `ChatManagementService.fromServiceLocator()` no longer reaches through
  `ArchiveManagementService.instance` / `ArchiveSearchService.instance`;
  fallback composition now uses their constructor-first locator factories.
- `HandshakeCoordinator` now resolves Noise service and topology announcement
  writes through injected/defaulted callbacks instead of repeated direct
  singleton reach-through, and related app-core call sites now prefer
  constructor-style singleton access (`SecurityManager()`, `TopologyManager()`)
  plus local `_isInitialized` checks over `AppCore.instance` self-access.
- `AppCore` now exposes constructor-style singleton access (`factory AppCore()`)
  and app bootstrap/shared queue wrappers consume a retained `AppCore` handle
  instead of repeating `AppCore.instance` lookups throughout lifecycle methods.
- Remaining singleton call sites in runtime services were normalized to
  constructor-style access (`NavigationService`, `BluetoothStateMonitor`,
  `RelayConfigManager`, `DatabaseQueryOptimizer`, `SeenMessageStore`,
  `TopologyManager`, `ChatManagementService`) so call paths avoid direct
  static `.instance` reach-through while preserving existing singleton behavior.

2026-03-23 boundary checkpoint:

- `lib/presentation/**` no longer imports `package:get_it/get_it.dart`.
- The presentation-layer bridge to the runtime locator is isolated to
  `lib/presentation/providers/di_providers.dart`.
- Additional `AppServices` seams now cover database/group/import/export
  dependencies and chat/home factory seams, so presentation callers can prefer
  the typed composition root before falling back to the legacy bridge.
- Repo guardrails now enforce:
  - no direct `get_it` imports or `GetIt`/`getIt` usage in presentation code
  - no direct `service_locator.dart` import in presentation outside
    `di_providers.dart`

2026-03-24 composition-root checkpoint:

- `AppCore` now resolves a typed `AppBootstrapServices` bundle from the
  service-locator boundary instead of issuing ad-hoc `getIt.get(...)` calls
  throughout startup.
- `AppCore` now publishes and clears the runtime `AppServices` snapshot through
  dedicated `service_locator.dart` helpers, reducing direct container mutation
  outside the DI boundary.
- The data-layer registrar now depends on a `ServiceRegistry` abstraction
  rather than raw `GetIt`, so checkpoint 6 can replace the container mechanics
  without rewriting data registration again.
- Guardrails now enforce that direct runtime `getIt` usage in `lib/**` is
  quarantined to `lib/core/di/service_locator.dart`.

2026-03-24 explicit runtime composition checkpoint:

- `AppCore` no longer publishes the live `AppServices` runtime snapshot into
  `GetIt`; it now uses `AppRuntimeServicesRegistry` as an explicit in-memory
  composition holder.
- Early startup runtime services (`ISecurityService`, `IConnectionService`,
  mesh coordinators/health) are likewise published through explicit runtime
  bindings instead of `registerSingleton(...)` calls.
- `service_locator.dart` still owns bootstrap/data registration, but
  `resolveRegistered(...)` and presentation DI helpers now consult the runtime
  composition registry first, reducing `GetIt` to a bootstrap-only role for
  the next checkpoint.
- Test harness snapshot wiring now mirrors production by publishing
  `AppServices` through the runtime registry instead of stuffing snapshots
  into `GetIt`.

2026-03-24 final cleanup checkpoint:

- `lib/core/di/service_locator.dart` now uses an internal `ServiceRegistry`
  implementation; production code no longer imports `package:get_it/get_it.dart`.
- The repo no longer declares `get_it` in `pubspec.yaml`; lockfile and package
  graph were refreshed after removal.
- Test suites now use `test/test_helpers/test_service_registry.dart` instead of
  importing `get_it` directly, preserving layer-boundary compliance while
  keeping the registry API stable during the final transition.
- Bootstrap/data registration remains centralized in `service_locator.dart`,
  while runtime `AppServices` and live service bindings stay in
  `AppRuntimeServicesRegistry`.
- Guardrails now cover the post-`get_it` state: no direct `get_it` dependency,
  no presentation-layer locator globals, and no runtime service publication back
  into the bootstrap registry.

---

## Definition of Done by Milestone

### Bare Minimum / Good Enough (30%)

- Passes 0-2 complete
- Presentation has one DI access path
- Runtime owners are not created/disposed by incidental provider churn

### Strong Maintainability (60%)

- Passes 0-4 complete
- Explicit composition root established
- Domain/core constructors are primary dependency path

### Best of Both Worlds (90%)

- Passes 0-6 complete
- Riverpod testability/scoping benefits preserved
- Global runtime behavior stabilized for BLE/mesh operations

### Ultimate Goal (100%)

- Passes 0-7 complete
- Legacy split-brain paths removed
- Guardrails enforced in CI

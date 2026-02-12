# DI Unification Roadmap (0-100%)

**Last Updated**: 2026-02-12 (Pass 5 in progress)

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
| Pass 5 | 60-75% | In Progress | Test strategy convergence (provider overrides first) |
| Pass 6 | 75-90% | Pending | Connection runtime serialization hardening |
| Pass 7 | 90-100% | Pending | Remove legacy fallbacks, enable strict guardrails |

---

## Latest Snapshot (Pass 5 Current)

Source: `validation_outputs/di_pass5_snapshot.json`

- `GetIt` resolutions in `lib/**`: 43
- `.instance` usages in `lib/**`: 92
- `GetIt` resolutions in `lib/presentation/**`: 2
- `get_it` imports in `lib/presentation/**`: 1 file (`di_providers.dart`)
- Presentation import guard violations: 0
- Presentation DI mutation sites (`register*`/`unregister`): 0

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

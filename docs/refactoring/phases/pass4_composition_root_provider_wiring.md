# Pass 4: Composition Root + Provider Wiring (In Progress)

**Status**: In Progress  
**Date**: 2026-02-12  
**Owner**: Architecture Refactor Track

---

## Objective

Start consuming a typed composition root (`AppServices`) from provider wiring,
instead of ad-hoc service-locator reads in presentation logic.

---

## Completed In This Slice

- Added typed composition-root model:
  - `lib/core/di/app_services.dart`

- AppCore now builds and publishes an `AppServices` snapshot after successful
  initialization, and unregisters it during dispose:
  - `lib/core/app_core.dart`

- Added `AppServices`-aware provider DI helpers:
  - `lib/presentation/providers/di_providers.dart`
  - `maybeResolveAppServices()`
  - `resolveFromAppServicesOrServiceLocator(...)`
  - `maybeResolveFromAppServicesOrServiceLocator(...)`

- Migrated provider-layer dependency resolution to prefer `AppServices` first
  (with safe DI fallback):
  - `lib/presentation/providers/contact_provider.dart`
  - `lib/presentation/providers/theme_provider.dart`
  - `lib/presentation/providers/security_state_provider.dart`
  - `lib/presentation/providers/ble_providers.dart`
  - `lib/presentation/providers/ble_service_facade_provider.dart`
  - `lib/presentation/providers/mesh_networking_provider.dart`
  - `lib/presentation/providers/mesh_health_provider.dart`
  - `lib/presentation/providers/runtime_providers.dart`
  - `lib/presentation/providers/pinning_service_provider.dart`
  - `lib/presentation/providers/chat_messaging_view_model.dart`
  - `lib/presentation/providers/group_providers.dart` (contact/shared queue)

- `AppServices` now includes additional stable app-composed seams:
  - `IChatsRepository`
  - `ISharedMessageQueueProvider`

- `AppCore` now reuses app-composed `IChatsRepository` and
  `ISharedMessageQueueProvider` references across initialization paths, reducing
  duplicated locator reads.

- `ble_core_service_providers.dart` now bridges through
  `connectionServiceProvider` first for BLE sub-service interfaces, with
  locator fallback only when required by legacy/test implementations.

---

## Verification

Commands run:

```powershell
flutter analyze lib/core/di/app_services.dart lib/core/app_core.dart lib/presentation/providers/di_providers.dart
flutter analyze lib/presentation/providers/di_providers.dart lib/presentation/providers/contact_provider.dart lib/presentation/providers/theme_provider.dart lib/presentation/providers/security_state_provider.dart lib/presentation/providers/ble_providers.dart lib/presentation/providers/ble_service_facade_provider.dart lib/presentation/providers/mesh_networking_provider.dart lib/presentation/providers/mesh_health_provider.dart
flutter analyze lib/core/di/app_services.dart lib/core/app_core.dart lib/presentation/providers/di_providers.dart lib/presentation/providers/chat_connection_provider.dart lib/presentation/providers/home_screen_providers.dart lib/presentation/providers/runtime_providers.dart lib/presentation/providers/group_providers.dart lib/presentation/providers/pinning_service_provider.dart lib/presentation/providers/ble_providers.dart lib/presentation/providers/chat_messaging_view_model.dart lib/presentation/providers/ble_core_service_providers.dart lib/presentation/providers/mesh_health_provider.dart
flutter test test/widget_test.dart test/presentation/chat_screen_controller_test.dart test/presentation/controllers/home_screen_controller_test.dart
flutter test test/widget_test.dart test/presentation/chat_screen_controller_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass4_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
```

Results:

- Targeted analyze: **No issues found**
- Targeted tests: **All passed**
- Pass 4 snapshot:
  - `GetIt` resolutions in `lib/**`: **43**
  - `.instance` usages in `lib/**`: **92**
  - Presentation import guard violations: **0**
  - Presentation DI mutation violations: **0**

---

## Remaining Pass 4 Work

- Continue provider wiring migration for remaining presentation modules that
  still resolve services directly from locator helpers.
- Introduce typed provider accessors for additional `AppServices` fields where
  it reduces locator coupling without forcing lifecycle regressions.
- Keep Pass 0 guardrails and targeted provider tests green after each slice.

# Pass 2: Single Runtime Owner (No Provider DI Mutations)

**Status**: Complete  
**Date**: 2026-02-12  
**Owner**: Architecture Refactor Track

---

## Objective

Ensure presentation providers do not mutate global DI state or own disposal of
AppCore/DI-managed singletons.

Pass 2 focus:

1. Remove provider-driven `register*`/`unregister` patterns.
2. Keep runtime ownership in AppCore + service locator.
3. Avoid provider disposal hooks that can tear down app-global singletons.

---

## Deliverables

- `lib/presentation/providers/mesh_networking_provider.dart`
  - Removed fallback path that created and registered/unregistered
    `MeshNetworkingService` and mesh coordinators from provider scope.
  - Provider now resolves `IMeshNetworkingService` from DI only and throws a
    clear runtime-init error if unavailable.

- `lib/presentation/providers/ble_service_facade_provider.dart`
  - Removed provider `onDispose` teardown of DI-owned `IConnectionService`.
  - Kept singleton resolution read-only.

- `lib/presentation/providers/mesh_health_provider.dart`
  - Removed provider `onDispose` teardown of DI-owned
    `MeshNetworkHealthMonitor`.

- `lib/presentation/providers/ble_core_service_providers.dart`
  - Removed disposal side-effects for DI-owned BLE services.
  - Converted these providers to non-`autoDispose` singleton access providers.

- `scripts/di_pass0_audit.ps1`
  - Added Pass 2 guardrail switch:
    - `-EnforcePresentationDiMutationGate`
  - New metric/guardrail output:
    - `presentationDiMutationCount`
    - `presentationDiMutationViolationCount`
  - Hardened count handling for single-item/single-object query results.

- `.github/workflows/flutter_coverage.yml`
  - Added CI guardrail enforcement:
    - install `ripgrep`
    - run DI audit with:
      - `-EnforcePresentationImportGate`
      - `-EnforcePresentationDiMutationGate`

- Snapshot:
  - `validation_outputs/di_pass2_snapshot.json`

---

## Verification

Commands run:

```powershell
pwsh -File scripts/di_pass0_audit.ps1 -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
flutter analyze lib/presentation
flutter test test/presentation/chat_screen_controller_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass2_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
```

Results:

- Presentation import guard violations: **0**
- Presentation DI mutation sites: **0**
- `flutter analyze lib/presentation`: **No issues found**
- `chat_screen_controller_test.dart`: **All tests passed**

---

## Exit Criteria

Pass 2 is complete when:

- Presentation providers do not call `registerSingleton`, `registerLazySingleton`,
  `registerFactory`, or `unregister` on DI.
- Presentation providers do not dispose AppCore/DI-owned singleton runtimes.
- Guardrails are enforceable locally and in CI.

All criteria are satisfied.

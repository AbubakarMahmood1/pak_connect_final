# Pass 1: Presentation DI Firewall

**Status**: Complete  
**Date**: 2026-02-12  
**Owner**: Architecture Refactor Track

---

## Objective

Remove direct `GetIt` usage from `lib/presentation/**` (except the bridge) so
presentation code resolves dependencies through a single adapter path:

- `lib/presentation/providers/di_providers.dart`

This pass focuses on access-path unification only. It does not yet remove
provider side-effects such as register/unregister patterns.

---

## Deliverables

- Expanded bridge helpers in:
  - `lib/presentation/providers/di_providers.dart`
  - Added non-`Ref` helpers:
    - `getServiceLocator()`
    - `resolveFromServiceLocator<T>()`
    - `maybeResolveFromServiceLocator<T>()`
    - `isRegisteredInServiceLocator<T>()`
- Migrated all presentation direct imports/usages of `get_it` to the bridge.
- Hardened audit script for single-result cases:
  - `scripts/di_pass0_audit.ps1`
- Snapshot after migration:
  - `validation_outputs/di_pass1_snapshot.json`

---

## Verification

Commands run:

```powershell
pwsh -File scripts/di_pass0_audit.ps1 -EnforcePresentationImportGate
flutter analyze lib/presentation
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass1_snapshot.json
```

Results:

- Import guard violations: **0**
- `get_it` imports in presentation: **1 file** (`di_providers.dart`)
- Presentation `GetIt` resolutions: **2** (both in `di_providers.dart`)
- `flutter analyze lib/presentation`: **No issues found**

---

## Exit Criteria

Pass 1 is complete when:

- `lib/presentation/**` has no direct `get_it` imports except bridge allowlist.
- Import guard in enforce mode passes.
- Presentation compiles/analyzes cleanly.

All criteria are satisfied.

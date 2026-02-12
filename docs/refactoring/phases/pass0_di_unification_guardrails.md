# Pass 0: DI Unification Guardrails

**Status**: Complete  
**Date**: 2026-02-12  
**Owner**: Architecture Refactor Track

---

## Objective

Set hard guardrails before migration work so DI changes are measurable and do not
create additional split-brain patterns.

This pass does not refactor runtime behavior. It establishes:

1. A single presentation-layer bridge for `GetIt`
2. Baseline metrics for current DI/singleton usage
3. An optional import gate that can move from advisory to enforced mode

---

## Target Composition Model (Current)

Near-term model:

- `GetIt` remains the construction/composition container.
- Presentation code consumes dependencies through Riverpod providers.
- Direct `get_it` imports in `lib/presentation/**` are limited to one adapter:
  `lib/presentation/providers/di_providers.dart`.

Long-term model:

- Keep reducing global lookups and singletons.
- Move toward explicit constructor/provider wiring.

---

## Deliverables

- `lib/presentation/providers/di_providers.dart`  
  Single Riverpod bridge to `GetIt` with resolver helpers.

- `scripts/di_pass0_audit.ps1`  
  Produces baseline metrics and supports optional presentation import gate.

- `validation_outputs/di_pass0_baseline.json`  
  Snapshot generated from the script.

---

## Baseline Snapshot (2026-02-12 UTC)

Source: `validation_outputs/di_pass0_baseline.json`

| Metric | Value |
|---|---:|
| `GetIt` resolutions in `lib/**` | 153 |
| `.instance` usages in `lib/**` | 206 |
| `GetIt` resolutions in `lib/presentation/**` | 54 |
| `get_it` imports in `lib/presentation/**` | 28 lines in 28 files |
| Import gate violations (allowlist = `di_providers.dart`) | 27 |

Enforcement behavior validated:

- `pwsh -File scripts/di_pass0_audit.ps1 -EnforcePresentationImportGate` fails as expected until Pass 1 migration reduces violations.

---

## Usage

Generate/refresh baseline snapshot (advisory mode):

```powershell
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline
```

Run import guard in enforcement mode (use in CI once Pass 1 migration is done):

```powershell
pwsh -File scripts/di_pass0_audit.ps1 -EnforcePresentationImportGate
```

---

## Exit Criteria

Pass 0 is complete when:

- Baseline snapshot exists and is committed.
- Adapter provider file exists.
- Guardrail script is documented and runnable.
- Roadmap/progress tracker is published for Pass 1+.

# Contributing to PakConnect

PakConnect is a publicly visible proprietary repository. External contributions
are not accepted at this time. This guide is intended for authorized team
members only.

---

## Development Environment Setup

- Flutter 3.38.4 or higher (CI is pinned to 3.44.4)
- Dart 3.10.3 or higher
- Android or iOS physical hardware for Bluetooth Low Energy (BLE) testing — emulators do not support BLE
- Ensure `flutter doctor` reports no critical issues before beginning work

## Code Standards

### Logging

Do not use `print()` anywhere in runtime code. Use the project's structured logging utilities exclusively. Raw print statements will be flagged in review and must be removed before merge.

### Architecture

The project follows a layered architecture. Keep boundaries intact:

- `lib/core/` — shared utilities, security, and messaging primitives
- `lib/data/` — repositories, services, and data sources
- `lib/domain/` — entities, use cases, and repository interfaces
- `lib/presentation/` — UI, view models, and state management

Keep `domain/` independent of `core/`, `data/`, and `presentation/`. `core/`
may consume domain contracts but must not import `data/` or `presentation/`;
`data/` must not import `presentation/`. When in doubt, consult the existing
import graph before adding a cross-layer dependency.

### General

- Keep functions focused and testable
- Prefer explicit types over `var` where the type is not immediately obvious
- Remove dead code rather than commenting it out

---

## Testing

All functional changes must be accompanied by new or updated tests. Run the full test suite locally before pushing:

```
flutter analyze --no-pub
flutter test
```

The `flutter_coverage.yml` workflow runs repository audit gates, a strict BLE
singleton test, and the full VM-friendly suite with coverage. It uploads LCOV
and test/analyzer logs, but it does not currently enforce a numeric coverage
threshold. Static analysis and the reachability review are fatal on every
workflow run. Physical-device tests under `integration_test/` are a separate
manual gate and are not run by CI.

The separate `codeql.yml` workflow runs for pull requests targeting `main` and
on its weekly schedule. It analyzes Android Java/Kotlin and GitHub Actions
definitions; it does not analyze Dart code.

If code is genuinely device-bound (for example, a platform-channel wrapper),
document the limitation and the required device evidence in the pull request.

---

## High-Scrutiny Areas

The following areas require extra care and closer review. Changes here should be well-justified, minimally scoped, and thoroughly tested:

- **`lib/core/security/`** — encryption, key management, and secure storage. Any change here has direct security implications. Involve at least two reviewers.
- **BLE lifecycle code (`lib/data/services/ble_*`)** — connection state machines, scanning, and pairing logic are fragile across OS versions and hardware. Test on real devices before submitting.
- **Mesh routing (`lib/core/messaging/`)** — changes to routing logic can have non-obvious effects on message delivery and network topology. Include integration tests where possible.
- **Export/Import (`lib/data/services/export_import/`)** — data integrity and forward/backward compatibility matter here. Ensure existing export formats remain readable after any change.

---

## Branch Strategy

- All development happens on feature branches cut from `main`
- Branch naming convention: `feature/<short-description>`, `fix/<short-description>`, `refactor/<short-description>`
- A pull request is required to merge into `main` — direct pushes are not permitted
- PRs require at least one approval before merge
- Resolve all review comments before requesting re-review

---

## Commit Message Format

This project uses [Conventional Commits](https://www.conventionalcommits.org/). Each commit message must begin with one of the following prefixes:

| Prefix       | When to use                                      |
|--------------|--------------------------------------------------|
| `feat:`      | A new feature or user-facing capability          |
| `fix:`       | A bug fix                                        |
| `docs:`      | Documentation changes only                      |
| `refactor:`  | Code restructuring with no behavior change       |
| `test:`      | Adding or updating tests                         |
| `ci:`        | CI configuration or pipeline changes             |

Example:

```
feat: add retry logic for BLE reconnection after signal loss
```

Keep the subject line under 72 characters. Add a body if the change requires context that is not evident from the subject alone.

---

## Questions

For questions about the codebase or this guide, reach out to the project maintainer directly.

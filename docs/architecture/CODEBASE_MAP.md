# PakConnect codebase map

Last reconciled: 2026-07-14

This is the live orientation map for maintainers and reviewers. It describes
the code that is wired today; historical plans and review reports are not
architecture authority.

## Repository authority

- Canonical remote: `https://github.com/AbubakarMahmood/pak_connect.git`
- Repo-wide rules and invariants: `AGENTS.md`
- Long-running work protocol and active plan: `PLANS.md`
- Runtime overview: `README.md`
- Security authority: `ThreatModel.md`, `docs/security/security_overview.md`,
  and `docs/security/security_guarantees.md`
- Automated verification: `TESTING_STRATEGY.md`
- Physical Android evidence protocol:
  `docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md`; the legacy
  `docs/testing/QUICK_START_TESTING.md` is non-evidentiary by itself
- Current engineering truth: `docs/status/ENGINEERING_STATUS.md`
- Objective-level readiness audit: `docs/status/READINESS_AUDIT.md`
- Device-only evidence: `docs/testing/DEVICE_VALIDATION_STATUS.md`
- Accepted and deferred liabilities: `docs/maintenance/DEBT_REGISTER.md`

## Scale snapshot

Physical line and file counts under `lib/` after the bounded reachability and
route/durability hardening passes:

| Layer | Dart files | Physical lines | Primary responsibility |
|---|---:|---:|---|
| `core` | 60 | 17,025 | BLE/security/mesh infrastructure and low-level services |
| `data` | 89 | 34,153 | SQLCipher/SQLite, repositories, BLE service implementations |
| `domain` | 200 | 42,413 | Entities, contracts, use cases, messaging and mesh policy |
| `presentation` | 87 | 30,869 | Flutter UI, controllers, view models and Riverpod providers |
| `lib/` root | 1 | 444 | Application entry point |
| Total | 437 | 124,904 | Excludes tests and generated platform files |

The practical dependency shape is not four isolated boxes. `domain` is the
base contract/policy layer; `core` and `data` both depend on it, and
`presentation` depends primarily on `domain`. A few deliberate data-to-core
and presentation-to-core imports remain. Architecture tests, not a simplified
README slogan, define the currently allowed edges.

## Accepted inventory boundary

The completion boundary for this map is **whole-library coverage plus
owner/layer mapping**, not a hand-maintained 437-row file or class catalogue.
Every library under `lib/` is included in the layer counts and evaluated by
`tools/dart_reachability_audit.ps1`; the runtime-owner table, layer map,
high-scrutiny list and invariants identify the maintainership and review route
for live behavior. The four non-runtime libraries have explicit owners,
classifications and exit conditions in
`tools/dart_reachability_allowlist.json`.

This is the accepted readiness boundary because a per-library prose appendix
would duplicate the source tree and drift without adding an enforcement gate.
It does not claim that every member inside a reachable library is live. New
libraries must fit a named layer/owner and become runtime-reachable or receive
a reviewed allowlist entry; member-level stubs remain liabilities in the debt
register.

## Runtime ownership

| Area | Main owner | Important collaborators |
|---|---|---|
| Process bootstrap | `lib/main.dart`, `lib/core/app_core.dart` | database factory, DI registrars, AppServices |
| BLE orchestration | `lib/data/services/ble_service_facade.dart` | lifecycle coordinator, role scheduler, connection/discovery/advertising/messaging/handshake services |
| Link state | `lib/data/services/ble_connection_manager.dart` | client/server runtime parts, health monitor, GATT controller |
| Noise sessions | `lib/core/security/noise/` | security manager, handshake service, session repository |
| Direct messaging | `lib/data/services/ble_messaging_service.dart` | transport helper, outbound sender, handler facade |
| Mesh relay | `lib/domain/services/mesh_networking_service.dart` | relay coordinator, seen-message store, health monitor |
| Offline delivery | `lib/core/messaging/offline_message_queue.dart` | queue repository, queue-sync manager/coordinator |
| Persistence | `lib/data/database/` | repositories and migrations |
| App state/UI | `lib/presentation/` | Riverpod providers, controllers, view models |

## Layer map

### `lib/core/`

- `bluetooth/`: BLE constants, helpers and lower-level platform-facing logic.
- `security/`: Noise XX/KK, key/session state, encryption policy and replay
  protection.
- `messaging/`: offline queue, relay engine, deduplication and persistence
  helpers.
- application bootstrap/infrastructure shared by the runtime.

### `lib/data/`

- `services/`: concrete BLE facade and its connection, discovery,
  advertising, handshake, messaging and lifecycle components.
- `database/`: schema v12, migrations, SQLCipher-capable factory and SQLite
  utilities.
- `repositories/`: persistence implementations for contacts, chats,
  messages, sender-local broadcast lists (legacy Group* names), archive state,
  hints and related data.
- models/adapters that translate storage or platform state into domain types.

### `lib/domain/`

- `entities/`, `models/`, `values/`: stable application vocabulary.
- `interfaces/`: cross-layer contracts used for DI and test isolation.
- `messaging/`: queue sync, gossip, routing and delivery policy.
- `services/mesh/`: relay, queue-sync and network-health coordination.
- application services and use cases for contacts, chats, broadcast lists,
  archive, security and background behavior.

### `lib/presentation/`

- `providers/`: Riverpod 3 dependency/state surfaces.
- `controllers/` and `viewmodels/`: screen/session behavior.
- `screens/` and `widgets/`: Flutter UI.
- `services/`: presentation-facing interaction and notification helpers.

## Critical invariants by owner

| Invariant | Primary enforcement points |
|---|---|
| Immutable `Contact.publicKey`; persistent key only after MEDIUM+ pairing | contact entity/repository, handshake/contact services |
| Resolve chat identity as `persistentPublicKey ?? publicKey` | contact/chat services and message routing |
| Noise phases are sequential; no encryption before established | handshake coordinator/service, Noise session/security manager |
| Noise nonces are sequential; rekey at 10k messages or one hour | Noise session and security/session management |
| Mesh IDs remain stable and opaque; local delivery precedes forwarding; hop cap and persistent capped dedup | relay coordinator/engine and seen-message store |
| BLE Phase 1 response is the ACK; Noise blocks Phase 2; Phase 0 negotiates MTU | lifecycle, handshake and connection services |
| Foreign keys cascade; WAL stays enabled; schema changes use migrations | database factory/schema/migrations |

Direct queued user payloads currently require exactly one active BLE route.
Queue-sync control frames can target concrete addresses, but multi-link payload
delivery remains disabled until link records bind an address/generation to the
verified handshake identities and ACK route. See `DEBT-QUEUE-LINK-001`.

## High-scrutiny surfaces

Changes in these areas require a concrete `PLANS.md` entry, focused regression
tests and full-suite verification:

- `lib/core/security/noise/`
- `lib/data/services/ble_connection_manager*`
- `lib/data/services/ble_role_scheduler.dart`
- `lib/data/services/ble_messaging*`
- `lib/domain/services/mesh/`
- `lib/domain/messaging/queue_sync_manager.dart`
- `lib/core/messaging/offline_message_queue.dart`
- `lib/data/database/`

## Reachability caution

The deterministic whole-library audit now reports 437 libraries: 433 reachable
from `lib/main.dart` and four explicitly reviewed test-only candidates. There
are no unreviewed app/test-unreachable libraries, and enforcement with
`tools/dart_reachability_audit.ps1 -FailOnUnreviewed` passes. The audit is not a
member-level linter; use `docs/maintenance/REACHABILITY_AUDIT.md` and the
machine-readable allowlist before changing its roots or retained candidates.

## Navigation order for a change

1. Read `AGENTS.md` and the relevant current status/debt row.
2. Start from the public domain contract or runtime entry point.
3. Follow the owning implementation and its focused tests.
4. Check the critical invariants above before changing behavior.
5. Update the status/debt/device ledger when the evidence or risk changes.

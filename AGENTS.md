# PakConnect - Agent Guidelines

`AGENTS.md` is the canonical source of truth for AI-assisted work in this
repository. Tool-specific files such as `CLAUDE.md`, `GEMINI.md`,
`.cursor/rules/*`, `.claude/*.mdc`, and `.github/copilot-instructions.md`
should defer to this file instead of redefining project behavior.

If a tool-specific file conflicts with `AGENTS.md`, follow `AGENTS.md`.

---

## Project Snapshot

PakConnect is a secure peer-to-peer BLE mesh messaging app built with
Flutter/Dart.

Core characteristics:
- Decentralized BLE mesh communication
- Noise Protocol for end-to-end encryption
- Dual-role BLE (central + peripheral)
- SQLCipher-backed local persistence
- Riverpod 3.0 state management

Primary stack:
- Flutter 3.9+
- Dart 3.9+
- Riverpod 3.0
- Noise Protocol (XX/KK patterns)
- SQLite + SQLCipher
- `bluetooth_low_energy`

## Documentation Order

Read documentation in this order:
1. `AGENTS.md` for repo-wide rules and invariants
2. `PLANS.md` for long-running task planning rules
3. Relevant surviving repo docs for the subsystem you are touching:
   - `CONTRIBUTING.md` for workflow and high-scrutiny paths
   - `README.md` for architecture and runtime overview
   - `ThreatModel.md`, `docs/security/security_overview.md`, and
     `docs/security/security_guarantees.md` for security-sensitive work
   - `TESTING_STRATEGY.md` and `docs/testing/QUICK_START_TESTING.md` for
     verification workflow
   - `docs/srs/README.md` for requirements context

Use Context7 before manually browsing package/plugin docs when up-to-date
library documentation is needed.

## Repository Structure

Layered architecture is mandatory:

```text
lib/
├── presentation/  # UI, widgets, Riverpod providers
├── domain/        # Business logic, use cases, entities
├── core/          # BLE, security, mesh, infrastructure
└── data/          # Database, repositories, models
```

Critical directories:
- `lib/core/security/noise/`
- `lib/core/bluetooth/`
- `lib/core/messaging/`
- `lib/data/database/`
- `test/`

## Working Defaults

These are the repo defaults unless the user explicitly asks otherwise:

- Use Flutter/Dart terminology and solutions. This is not a TypeScript/NestJS
  codebase.
- Preserve the existing layered architecture.
- Stay within the existing Riverpod 3.0 provider architecture.
- Do not introduce `provider`, `ChangeNotifier`, `go_router`, MVVM rewrites, or
  alternate app-wide state management unless explicitly requested.
- Use the `logging` package, not `print()`.
- Prefer targeted fixes over broad rewrites.
- Treat reviews as findings-first: bugs, regressions, risks, then summary.

## Build, Test, and Verification

- Use `flutter pub get` after dependency changes.
- Use `flutter analyze` for static analysis.
- Use `flutter test`, not `dart test`, for this repo.
- Use `flutter test integration_test/` for integration coverage.
- For full-suite runs, capture output in `flutter_test_latest.log`.
- Format Dart with `dart format lib test`.

Flutter sandbox notes:
- In Codex-like sandboxes, Flutter commands may require elevation because the
  SDK cache writes outside the repo.
- If the normal Flutter wrapper is unavailable on Windows, use the local
  `.tmp_flutter_sdk_*` fallback described in previous repo guidance, but never
  commit that scratch directory.

## Planning Workflow

Use `PLANS.md` for any task that is not obviously small.

Create or update a plan before major edits when a task:
- Touches critical systems
- Spans multiple modules
- Changes architecture or public behavior
- Is likely to take more than about 30 minutes
- Requires staged verification or rollback thinking

Critical systems:
- Noise protocol and key handling
- BLE handshake/state machine logic
- Mesh relay/routing/duplicate detection
- Database schema or migrations

Keep the plan concrete. Include:
- Goal
- Constraints
- Facts
- Approach
- Step list
- Verification
- Risks
- Open questions

## Critical Invariants

These must not be violated.

### Identity Management

1. `Contact.publicKey` is immutable and is the database primary key.
2. `Contact.persistentPublicKey` is nullable and only set after MEDIUM+
   security pairing.
3. `Contact.currentEphemeralId` rotates per connection/session.
4. Chat identity resolution uses `persistentPublicKey ?? publicKey`.

### Noise Protocol State Machine

1. Handshake phases are sequential:
   - Phase 0: `CONNECTION_READY`
   - Phase 1: `IDENTITY_EXCHANGE`
   - Phase 1.5: `NOISE_HANDSHAKE`
   - Phase 2: `CONTACT_STATUS_SYNC`
2. No encryption before the Noise handshake reaches `established`.
3. Nonces must be strictly sequential.
4. Sessions rekey after 10k messages or 1 hour.
5. Noise operations must be serialized per session.

### Mesh Relay

1. Message IDs are deterministic:
   `SHA-256(timestamp + senderKey + content)`.
2. Duplicate detection window is 5 minutes.
3. Local delivery happens before forwarding.
4. Relay hops are capped at 3-5.

### BLE Handshake

1. Phase 1 response is the acknowledgement; do not add a separate ACK.
2. Phase 1.5 Noise handshake is blocking and must complete before Phase 2.
3. MTU negotiation happens in Phase 0, targeting up to 512 bytes.

### Database

1. Foreign keys use `ON DELETE CASCADE`.
2. WAL mode remains enabled.
3. Schema changes are tracked in migrations.
4. SQLCipher keys derive from user passphrase -> PBKDF2 -> SQLCipher key.

## Common Pitfalls

BLE:
- Do not cache characteristics across reconnections.
- Do not assume MTU >160 without negotiation.
- Do not run BLE operations on the UI thread.
- Always verify connection state before writes.

Noise:
- Do not encrypt before handshake completion.
- Do not reuse nonces.
- Do not store private keys unencrypted.
- Always validate handshake state before crypto operations.

Mesh:
- Do not relay without duplicate detection.
- Do not invent arbitrary message IDs.
- Do not relay indefinitely.
- Always consult `SeenMessageStore` before relaying.

Database:
- Do not run migrations outside a transaction.
- Do not use raw unparameterized SQL.
- Do not store sensitive data unencrypted.
- Always think about migration compatibility.

## Test Harness Expectations

- DB-heavy and service-level tests should boot via
  `TestSetup.initializeTestEnvironment(dbLabel: ...)`.
- Use `configureTestDatabase` and `setupTestDI` so each suite gets an isolated
  SQLCipher file and DI graph.
- BLE tests must go through `IBLEPlatformHost`.
- For BLE facade tests, inject `_FakeBlePlatformHost`.
- Stub messaging/advertising/handshake sub-services to avoid platform channel
  leakage in unit tests.

## Tool Projection Rules

The following files are projections of this guidance and should stay thin:
- `CLAUDE.md`
- `GEMINI.md`
- `.cursor/rules/global.mdc`
- `.cursor/rules/flutter.mdc`
- `.claude/flutter.mdc`
- `.github/copilot-instructions.md`
- `.github/instructions/*.instructions.md`
- `.github/agents/*.agent.md`

They may add tool-specific behavior, but they should not redefine repo
architecture, state management, testing commands, or security invariants.

## When To Stop And Ask

Pause and ask before making risky changes when you are unsure about:
- Nonce sequencing
- Identity resolution (`publicKey` vs `persistentPublicKey`)
- Handshake phase transitions
- Relay ID generation or dedup behavior
- Database schema or migration semantics

If you are only missing implementation detail, consult the relevant
surviving repo doc first.

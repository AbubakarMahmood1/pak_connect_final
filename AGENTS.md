# PakConnect - Agent Guidelines

**Context**: You are assisting with **PakConnect**, a secure peer-to-peer BLE mesh messaging app built with Flutter/Dart. This file provides guidance for AI coding agents (like Codex, ChatGPT, or other LLMs) when working with this codebase.

**Companion File**: `CLAUDE.md` contains detailed implementation specifics for Claude Code. This file (AGENTS.md) provides high-level context and critical invariants that apply to **all** AI agents.

---

## Project Overview

**What is PakConnect?**
- Secure, decentralized BLE mesh messaging application
- End-to-end encryption using Noise Protocol Framework (XX/KK patterns)
- Multi-hop mesh networking with smart relay policies
- SQLite-backed persistence with SQLCipher encryption
- Dual-role BLE (simultaneous central + peripheral)

**Tech Stack**:
- Flutter 3.9+, Dart 3.9+
- Riverpod 3.0 (state management)
- Noise Protocol (X25519 + ChaCha20-Poly1305)
- SQLite with SQLCipher (encrypted storage)
- BLE mesh networking (custom protocol)

## Documentation Lookup with Context7 API
- Use the Context7 API to search libraries and fetch documentation programmatically before opening plugin docs manually.
- Call the search endpoint with the `query` parameter (search term). Example response:
```
{
  "results": [
    {
      "id": "/react-hook-form/documentation",
      "title": "React Hook Form",
      "description": "📋 Official documentation",
      "totalTokens": 50275,
      "totalSnippets": 274,
      "stars": 741,
      "trustScore": 9.1,
      "versions": []
    },
    ...
  ]
}
```
- Use the returned `id` to fetch documentation; rely on this flow so you do not need to read plugin documentation unless necessary.

---

## Project Structure & Module Organization

**Layered Architecture** (strict separation):
```
lib/
├── presentation/     # UI layer (screens, widgets, Riverpod providers)
├── domain/          # Business logic (services, entities, use cases)
├── core/            # Infrastructure (BLE, security, mesh, power management)
└── data/            # Persistence (repositories, database, models)
```

**Key Directories**:
- `lib/core/security/noise/` - Noise Protocol implementation (CRITICAL - security sensitive)
- `lib/core/bluetooth/` - BLE handshake and dual-role management
- `lib/core/messaging/` - Mesh relay engine and routing logic
- `lib/data/database/` - SQLite schema and migrations
- `test/` - Mirrors lib/ structure with unit/widget/integration tests

## Build, Test, and Development Commands
- `flutter pub get` retrieves dependencies; run after pulling main.
- `flutter analyze` enforces the lints in `analysis_options.yaml`.
- **Use `flutter test`, not `dart test`, for this repo** — `package:flutter_test` pulls in `dart:ui`, which only exists when the Flutter engine is running. Running with plain `dart test` will fail; stick to `flutter test …` (including single-file runs). `flutter analyze` is preferred; only use `dart analyze` if you are certain it won’t trip `dart:ui` dependencies.
- `dart format lib test` formats Dart code before commits.
- `flutter run -d chrome` or `flutter run -d emulator-id` launches the app locally.
- `flutter test` runs the unit and widget suites; use `flutter test integration_test/` for device-level coverage.
- **Always capture full-suite test runs**: when executing `flutter test` against the full suite, pipe the output to `flutter_test_latest.log` (or the appropriate log listed in `TESTING_STRATEGY.md`) and review it before ending the session so regressions are documented.
- **Sandbox note**: When running Flutter CLI commands from Codex, request elevated permissions up front—the CLI sandbox otherwise blocks writes to `/home/abubakar/flutter/bin/cache` (e.g., `engine.stamp` updates) and causes false "Permission denied" failures. Asking the user to approve elevated execution keeps `flutter analyze`, `flutter run`, and `flutter test` working.
- **Windows fallback when Flutter wrapper/Puro is unavailable in agent sandbox**:
  - If `flutter` / `flutter.bat` fails due to wrapper/path/mount issues, invoke Flutter tools directly via the copied SDK Dart binary:
    - `& "$PWD\\.tmp_flutter_sdk_<N>\\bin\\cache\\dart-sdk\\bin\\dart.exe" "$PWD\\.tmp_flutter_sdk_<N>\\packages\\flutter_tools\\bin\\flutter_tools.dart" analyze --no-pub`
    - `& "$PWD\\.tmp_flutter_sdk_<N>\\bin\\cache\\dart-sdk\\bin\\dart.exe" "$PWD\\.tmp_flutter_sdk_<N>\\packages\\flutter_tools\\bin\\flutter_tools.dart" test --no-pub <path-or-args>`
  - Keep `.tmp_flutter_sdk_*` as local scratch only; do not commit/push it.
  - If accidentally staged, unstage with `git rm --cached -r .tmp_flutter_sdk_*`.

## Coding Style & Naming Conventions
- Follow Flutter default lints: two-space indentation, trailing commas for multiline widgets, const constructors when possible.
- Name classes and widgets using UpperCamelCase, methods and variables in lowerCamelCase, files in snake_case (`message_router.dart`).
- Keep widgets lean; extract shared UI to `lib/presentation/widgets/` and reuse providers from `lib/presentation/providers/`.

## Testing Guidelines
- Target >80% coverage on critical flows per `TESTING_STRATEGY.md`; prioritize flaky fixes before adding new specs.
- Organize tests with the Arrange-Act-Assert pattern and prefer descriptive `group` + `test` names (`archive_service_test.dart`).
- Reset shared state between tests (e.g., close mock databases) and use fakes for networking (`lib/core/messaging`).
- Record failing cases in `flutter_test_output.log` and update or disable only with justification.

## Test Harness & BLE Host Expectations
- All DB-heavy or service-level tests must boot through `TestSetup.initializeTestEnvironment(dbLabel: …)` plus `configureTestDatabase`/`setupTestDI` so each suite has its own SQLCipher file and DI graph.
- Never talk to `CentralManager()`/`PeripheralManager()` directly in tests—route BLE access through the `IBLEPlatformHost` seam (`lib/core/interfaces/i_ble_platform_host.dart`) and, when testing the facade, inject `_FakeBlePlatformHost` (`test/services/ble_service_facade_test.dart`).
- Battery/ephemeral-key plugins are disabled automatically inside the harness; do not re-enable them from tests unless you are running on real hardware.
- BLEServiceFacade and related suites should pass stub sub-services (messaging, advertising, handshake) so no platform channels or timers leak into unit tests.

## Commit & Pull Request Guidelines
- Git history mixes free-form and Conventional Commits; prefer the structured format (`feat: add archive sync`, `fix: resolve logger recursion`).
- Write focused commits with passing tests; reference related docs or issues in the body.
- Pull requests should include: purpose summary, testing evidence (`flutter test` output), screenshots for UI changes, and security considerations when touching `lib/core/security/`.
- Request review from module owners (core, data, presentation) and leave TODOs only when tracked by an issue.

## Security & Configuration Tips
- Never commit secrets; keep environment credentials outside the repo and load via runtime configuration.
- Auditing-sensitive code lives in `lib/core/security/`; flag risky changes in PR descriptions and ensure analyzers stay clean.

---

## 🚨 Critical Invariants (MUST NOT VIOLATE)

### Identity Management
1. **Contact.publicKey is IMMUTABLE** - Used as primary key in database, NEVER changes
2. **Contact.persistentPublicKey is nullable** - Only set after MEDIUM+ security pairing
3. **Contact.currentEphemeralId rotates** - Updates per connection for privacy
4. **Chat ID resolution**: Use `persistentPublicKey ?? publicKey` (security-level aware)

### Noise Protocol State Machine
1. **Handshake phases are SEQUENTIAL**:
   - Phase 0: CONNECTION_READY
   - Phase 1: IDENTITY_EXCHANGE
   - Phase 1.5: NOISE_HANDSHAKE (XX or KK pattern, 2-3 messages)
   - Phase 2: CONTACT_STATUS_SYNC
2. **No encryption before Noise handshake completes** (state == established)
3. **Nonces MUST be sequential** - Gaps trigger replay protection
4. **Sessions rekey after 10k messages or 1 hour** - Forward secrecy requirement
5. **Thread safety**: Serialize all Noise operations per session

### Mesh Relay Rules
1. **Message IDs are deterministic**: `SHA-256(timestamp + senderKey + content)` ensures consistent IDs across devices
2. **Duplicate detection window = 5 minutes** - SeenMessageStore entries expire after 5min
3. **Relay MUST deliver locally before forwarding** - Prevents message loss
4. **Max relay hops = 3-5** - Prevent network flooding

### BLE Handshake Sequence
1. **Phase 1 response acts as acknowledgment** - No separate ACK messages
2. **Noise handshake (Phase 1.5) is blocking** - Must complete before Phase 2
3. **MTU negotiation happens in Phase 0** - Request max 512 bytes

### Database Schema
1. **Foreign keys ON DELETE CASCADE** - Enforced at DB level
2. **WAL mode enabled** - Required for concurrency
3. **Schema version in migrations table** - Track all schema changes
4. **Encryption key derivation**: User passphrase → PBKDF2 → SQLCipher key

---

## 🎯 Common Pitfalls to Avoid

### BLE Issues
- ❌ Don't cache BLE characteristics across reconnections
- ❌ Don't assume MTU >160 bytes without negotiation
- ❌ Don't run BLE operations on UI thread
- ✅ Always check connection state before writes

### Noise Protocol Issues
- ❌ Don't encrypt before handshake completes
- ❌ Don't reuse nonces (replay attack vector)
- ❌ Don't store private keys unencrypted
- ✅ Always validate handshake state before operations

### Mesh Networking Issues
- ❌ Don't relay without duplicate detection
- ❌ Don't use arbitrary message IDs (use SHA-256)
- ❌ Don't relay indefinitely (cap at 3-5 hops)
- ✅ Always check SeenMessageStore before relay

### Database Issues
- ❌ Don't run migrations without transactions
- ❌ Don't use raw SQL without parameterization
- ❌ Don't store sensitive data unencrypted
- ✅ Always test migrations backwards compatibility

---

## 🔍 When to Ask for Clarification

**Before making changes to**:
1. **Security-critical code** (Noise Protocol, key storage, encryption)
2. **BLE handshake phases** (connection sequencing, state machines)
3. **Mesh relay logic** (routing algorithms, duplicate detection)
4. **Database schema** (migrations, foreign keys, indexes)

**Red flags that warrant stopping**:
- Uncertainty about nonce sequencing
- Confusion about identity resolution (publicKey vs persistentPublicKey)
- Unclear about handshake phase transitions
- Unsure about message ID generation logic

---

## 🤝 Collaboration with Other Agents

**If Claude Code is also working on this codebase**:
- Claude has access to full implementation details via `CLAUDE.md`
- You (Codex/GPT-5) provide fresh, unbiased perspective
- Typical workflow: Claude implements → You review for edge cases/security
- Focus on: Security vulnerabilities, race conditions, alternative approaches

**Coordination**:
- Both agents read this file for shared context
- Claude follows implementation patterns from `CLAUDE.md`
- You focus on critique, validation, and alternative solutions

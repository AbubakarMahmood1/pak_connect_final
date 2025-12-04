# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

**PakConnect** is a secure, peer-to-peer BLE mesh messaging application built with Flutter/Dart. It features end-to-end encryption using the Noise Protocol Framework, decentralized mesh networking with smart relay, and advanced chat management capabilities.

**Key Technologies**: Flutter 3.9+, Dart 3.9+, Riverpod 3.0, Noise Protocol (XX/KK patterns), SQLite with SQLCipher, BLE mesh networking

## Quick Start Commands

```bash
# Essential commands
flutter pub get              # Install dependencies
flutter run                  # Run app
flutter test                 # Run tests
flutter analyze              # Static analysis

# Testing with logs
set -o pipefail; flutter test --coverage | tee flutter_test_latest.log
```

📖 **Full development guide**: See `docs/claude/development-guide.md`

## Architecture (Layered Pattern)

```
PRESENTATION (UI + Providers) → Riverpod state management
    ↓
DOMAIN (Business Logic) → Services, use cases
    ↓
CORE (Infrastructure) → BLE, Security, Mesh, Power
    ↓
DATA (Storage) → SQLite, Repositories
```

## Critical File Reference

### BLE Stack
- `lib/data/services/ble_service.dart` - Main orchestrator
- `lib/core/bluetooth/handshake_coordinator.dart` - 4-phase handshake

### Security (Noise Protocol)
- `lib/core/security/noise/noise_encryption_service.dart` - Noise API
- `lib/core/services/security_manager.dart` - Security levels (LOW/MEDIUM/HIGH)

### Mesh Networking
- `lib/core/messaging/mesh_relay_engine.dart` - Relay logic
- `lib/core/routing/network_topology_analyzer.dart` - Topology analysis

### Database
- `lib/data/database/database_helper.dart` - Schema v9 + migrations
- `lib/data/repositories/contact_repository.dart` - Contact CRUD

### Providers (Riverpod)
- `lib/presentation/providers/ble_providers.dart` - BLE state
- `lib/presentation/providers/mesh_networking_provider.dart` - Mesh stats
- `lib/presentation/providers/contact_provider.dart` - Contact management

## Critical Invariants (MUST NEVER VIOLATE)

### Identity Model
**Every contact has THREE distinct IDs**:
```dart
class Contact {
  String publicKey;           // IMMUTABLE: DB primary key (never changes)
  String? persistentPublicKey; // Set after MEDIUM+ pairing
  String? currentEphemeralId;  // Session-specific (rotates per connection)
}
```

**Lookup Rules**:
- Chat ID: `persistentPublicKey ?? publicKey` (security-aware)
- Noise session: `currentEphemeralId ?? publicKey` (session-aware)

### Security
- Noise session MUST complete handshake before encryption (state == `established`)
- Nonces MUST be sequential (gaps trigger replay protection)
- Sessions MUST rekey after 10k messages or 1 hour

### Mesh Relay
- Message IDs MUST be deterministic (SHA-256 of `timestamp+senderKey+content`)
- Duplicate detection window = 5 minutes
- Relay MUST deliver locally before forwarding

### Database
- Schema version 9 (current)
- WAL mode enabled, foreign keys enforced
- SQLCipher v4 encryption

## 📚 Detailed Documentation (Read On-Demand)

**When working on specific areas, read these detailed guides**:

| Topic | File | When to Read |
|-------|------|--------------|
| **BLE handshake, dual-role, fragmentation** | `docs/claude/architecture-ble.md` | Debugging BLE issues, handshake failures |
| **Noise protocol, security levels, encryption** | `docs/claude/architecture-noise.md` | Security bugs, encryption errors, pairing |
| **Mesh relay, routing, message flow** | `docs/claude/architecture-mesh.md` | Relay issues, message delivery problems |
| **Riverpod migration, StreamController → Provider** | `docs/claude/architecture-riverpod.md` | State management refactoring |
| **Database schema, migrations, performance** | `docs/claude/architecture-database.md` | Schema changes, DB performance |
| **Testing, debugging, common tasks** | `docs/claude/development-guide.md` | Writing tests, debugging workflows |
| **Performance tips, limitations** | `docs/claude/performance.md` | Optimization, scaling issues |
| **Confidence protocol (MANDATORY)** | `docs/claude/confidence-protocol.md` | Before modifying critical areas |
| **Codex MCP integration** | `docs/claude/codex-integration.md` | Using Codex for second opinions |

## 🎯 Confidence Protocol (Quick Version)

**Before modifying critical areas** (BLE handshake, Noise, mesh routing, identity resolution, DB migrations):

1. **Run confidence assessment** (0-100%):
   - No duplicates? (20%)
   - Architecture compliance? (20%)
   - Official docs checked? (15%)
   - Working reference found? (15%)
   - Root cause understood? (15%)
   - Codex consulted? (15%)

2. **Action based on score**:
   - **≥90%**: ✅ Proceed immediately
   - **70-89%**: ⚠️ Present alternatives, consult Codex
   - **<70%**: ❌ STOP - Consult Codex, ask questions, research

📖 **Full confidence checklist**: See `docs/claude/confidence-protocol.md`

## Codex Integration (Quick Reference)

**Codex is available for deep analysis** - automatically triggered for:
- Confidence score <70%
- Critical areas (BLE, Noise, mesh, security)
- Multi-day debugging (stuck >2 hours)
- Architecture changes

**Manual trigger**: User says "Have Codex review this"

**MCP Tool**: `mcp__codex__codex` with `prompt` parameter (plain text response)

📖 **Full Codex guide**: See `docs/claude/codex-integration.md`

## Key Service Classes (Quick Ref)

| Service | Location | Purpose |
|---------|----------|---------|
| `AppCore` | `lib/core/app_core.dart` | Singleton coordinator, initializes all subsystems |
| `BLEService` | `lib/data/services/ble_service.dart` | BLE orchestrator (scan, advertise, connect, send) |
| `SecurityManager` | `lib/core/services/security_manager.dart` | Noise lifecycle, security upgrades |
| `MeshRelayEngine` | `lib/core/messaging/mesh_relay_engine.dart` | Relay decisions, duplicate detection |
| `OfflineMessageQueue` | `lib/core/messaging/offline_message_queue.dart` | Queue + retry for offline recipients |

## Test Harness Checklist

- Every test suite must call `TestSetup.initializeTestEnvironment(dbLabel: ...)`
- Use `configureTestDatabase` + `setupTestDI` in `setUp` (isolates SQLite files)
- BLE tests must use `IBLEPlatformHost` seam with `_FakeBlePlatformHost`
- Export logs: `set -o pipefail; flutter test --coverage | tee flutter_test_latest.log`

## Integration Checklist

When adding features:
- [ ] Update schema version if DB changes
- [ ] Add migration logic in `DatabaseHelper`
- [ ] Update relevant Riverpod providers
- [ ] Add emoji-prefixed logging (🎯🔐📡🔄💾)
- [ ] Write tests (target >85% coverage)
- [ ] Test on real BLE devices (emulator unreliable)
- [ ] Update docs if architecture changes
- [ ] Run `flutter analyze` (zero errors)

## Cursor Rules Applied

- **Be direct and terse**: Code first, explanation after
- **Anticipate needs**: Suggest solutions proactively
- **Treat as expert**: Technical depth expected, no hand-holding
- **SOLID Principles**: Applied throughout
- **Concise code**: Functions <20 lines where possible
- **Logging over print**: Use `logging` package exclusively
- **Immutability**: Widgets immutable, prefer `const` constructors

---

**📌 Remember**: This is the orchestrator. Read detailed docs from `docs/claude/` as needed based on your task context.

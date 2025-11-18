# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**PakConnect** is a secure, peer-to-peer BLE mesh messaging application built with Flutter/Dart. It features end-to-end encryption using the Noise Protocol Framework, decentralized mesh networking with smart relay, and advanced chat management capabilities.

**Key Technologies**: Flutter 3.9+, Dart 3.9+, Riverpod 3.0, Noise Protocol (XX/KK patterns), SQLite with SQLCipher, BLE mesh networking

## Development Commands

### Building and Running

```bash
# Get dependencies
flutter pub get

# Run the app
flutter run

# Build for production
flutter build apk --release

# Clean build artifacts
flutter clean
```

### Testing

```bash
# Run all tests
flutter test

# Run tests with coverage
flutter test --coverage

# Run specific test file
flutter test test/path/to/test_file.dart

# Run single test with timeout (for slow tests)
timeout 60 flutter test test/mesh_relay_flow_test.dart

# Run tests excluding specific tags
flutter test --exclude-tags=mesh_relay

# Run tests in compact mode (less verbose)
flutter test --reporter=compact
```

### Code Quality

```bash
# Run static analysis
flutter analyze

# Run tests and build in sequence
flutter test && flutter build apk
```

### Database Testing

```bash
# Test database migrations
flutter test test/database_migration_test.dart

# Test contact repository (SQLite-backed)
flutter test test/contact_repository_sqlite_test.dart
```

## Architecture Overview

### Layered Architecture Pattern

```
┌─────────────────────────────────────┐
│   PRESENTATION (UI + Providers)     │
│   - Screens, Widgets, Riverpod      │
└────────────┬────────────────────────┘
             ↓
┌─────────────────────────────────────┐
│   DOMAIN (Business Logic)           │
│   - Services, Entities, Use Cases   │
└────────────┬────────────────────────┘
             ↓
┌─────────────────────────────────────┐
│   CORE (Infrastructure)             │
│   - BLE, Security, Mesh, Power      │
└────────────┬────────────────────────┘
             ↓
┌─────────────────────────────────────┐
│   DATA (Storage & Persistence)      │
│   - Repositories, Database, Models  │
└─────────────────────────────────────┘
```

### Critical Design Patterns

- **Repository Pattern**: Data access abstraction (`ContactRepository`, `ChatRepository`)
- **Service Layer**: Business logic encapsulation (`SecurityManager`, `MeshNetworkingService`)
- **Provider Pattern**: State management via Riverpod 3.0
- **Observer Pattern**: Real-time updates through streams
- **Strategy Pattern**: Relay policies, power management strategies

## BLE Communication Architecture

### Dual-Role BLE Stack

PakConnect operates as **both central and peripheral** simultaneously:

- **Central Mode**: Scans and connects to other devices
- **Peripheral Mode**: Advertises and accepts connections

**Key Services**:
- `BLEService`: Main orchestrator (`lib/data/services/ble_service.dart`)
- `BLEConnectionManager`: Connection lifecycle management
- `BLEStateManager`: BLE adapter state tracking
- `PeripheralInitializer`: Advertising setup
- `BurstScanningController`: Adaptive scanning strategy

### Handshake Protocol (4 Phases)

The handshake is **sequential** - each response acts as an acknowledgment:

```
Phase 0: CONNECTION_READY
  → Device connects and establishes MTU

Phase 1: IDENTITY_EXCHANGE
  → Sender: ephemeralId, displayName, noisePublicKey
  → Receiver validates and responds with own identity

Phase 1.5: NOISE_HANDSHAKE (XX or KK pattern)
  → 2-3 messages to establish encrypted session
  → Uses X25519 DH + ChaCha20-Poly1305 AEAD

Phase 2: CONTACT_STATUS_SYNC
  → Exchange security levels, trust status
  → Complete handshake
```

**Critical Implementation Detail**: Handshake MUST complete Phase 1.5 (Noise) before any message encryption can occur.

**Files**:
- `lib/core/bluetooth/handshake_coordinator.dart`: Orchestrates handshake flow
- `lib/core/bluetooth/peripheral_initializer.dart`: Manages peripheral role
- `lib/data/services/ble_connection_manager.dart`: Connection state machine

## Noise Protocol Integration

### Three-Layer Security Architecture

```
NoiseEncryptionService (High-level API)
  ↓
NoiseSessionManager (Multi-peer session tracking)
  ↓
NoiseSession (Per-peer encryption/decryption)
  ↓
HandshakeState, SymmetricState, CipherState, DHState
```

**Crypto Stack**:
- **DH**: X25519 (pinenacl package)
- **AEAD**: ChaCha20-Poly1305 (cryptography package)
- **Hash**: SHA-256
- **Patterns**: XX (3-message, mutual auth) or KK (2-message, pre-shared keys)

### Security Levels

| Level | Description | Key Storage | Verification |
|-------|-------------|-------------|--------------|
| **LOW** | Ephemeral session only | RAM only | None (forward secrecy only) |
| **MEDIUM** | Persistent key + 4-digit PIN | Secure storage | PIN-based pairing |
| **HIGH** | Persistent key + ECDH + Triple DH | Secure storage | Cryptographic verification |

**Critical Files**:
- `lib/core/security/noise/noise_encryption_service.dart`: Main entry point
- `lib/core/security/noise/noise_session_manager.dart`: Session lifecycle
- `lib/core/security/noise/noise_session.dart`: Per-peer state machine
- `lib/core/services/security_manager.dart`: Security level management

### Contact Identity Model

**Three distinct IDs per contact** (critical for correctness):

```dart
class Contact {
  String publicKey;           // IMMUTABLE: First ephemeral ID (never changes)
  String? persistentPublicKey; // REAL identity after MEDIUM+ pairing
  String? currentEphemeralId;  // ACTIVE Noise session ID (updates per connection)
}
```

**Identity Resolution Rules**:
- **Chat ID**: `persistentPublicKey ?? publicKey` (security-level aware)
- **Noise Lookup**: `currentEphemeralId ?? publicKey` (session-aware)

**Why This Matters**: Ephemeral IDs rotate for privacy, but chat history persists via `persistentPublicKey`.

## Mesh Networking Architecture

### Relay Decision Flow

```
Message Received
  ↓
Relay Enabled? → NO → Deliver locally only
  ↓ YES
Duplicate? (via SeenMessageStore) → YES → Drop
  ↓ NO
Already Delivered to Self? → NO → Deliver locally
  ↓
Find Route (SmartMeshRouter)
  ↓
Send to Next Hop(s)
```

**Key Components**:
- `MeshRelayEngine`: Core relay logic (`lib/core/messaging/mesh_relay_engine.dart`)
- `SmartMeshRouter`: Route optimization based on topology
- `NetworkTopologyAnalyzer`: Network size estimation
- `SeenMessageStore`: Duplicate detection (Message ID → timestamp)
- `SpamPreventionManager`: Flood protection

### Message ID Generation

```dart
// Unique and deduplicatable across relay hops
String messageId = base64Encode(
  sha256.convert(
    utf8.encode('$timestamp$senderKey$content')
  ).bytes
);
```

**Why SHA-256**: Ensures consistent IDs across devices without coordination.

## State Management (Riverpod 3.0)

### Provider Types

- **`AsyncNotifier`**: Complex state with mutation methods (e.g., `ContactsNotifier`)
- **`StreamProvider`**: Real-time data streams (e.g., `meshNetworkStatusProvider`)
- **`FutureProvider`**: Async one-time values (e.g., `contactsProvider`)
- **`Provider`**: Computed derived values (e.g., `bleServiceProvider`)

**Key Provider Files**:
- `lib/presentation/providers/ble_providers.dart`: BLE state, scanning control
- `lib/presentation/providers/mesh_networking_provider.dart`: Mesh status, relay stats
- `lib/presentation/providers/contact_provider.dart`: Contact management

**Pattern**: Use `ref.watch()` in widgets, `ref.read()` in callbacks.

## Database Architecture (SQLite + SQLCipher)

### Schema Version 9 (Current)

**Critical Tables**:

```sql
-- CONTACTS: Three IDs per contact (see Identity Model above)
CREATE TABLE contacts (
  public_key TEXT PRIMARY KEY,
  persistent_public_key TEXT,
  current_ephemeral_id TEXT,
  display_name TEXT,
  security_level INTEGER,
  last_seen INTEGER
);

-- CHATS: Chat list with contact relationships
CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  contact_public_key TEXT,
  last_message TEXT,
  timestamp INTEGER,
  is_archived INTEGER DEFAULT 0,
  FOREIGN KEY(contact_public_key) REFERENCES contacts(public_key) ON DELETE CASCADE
);

-- MESSAGES: Message history with status tracking
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT,
  content TEXT,
  sender_key TEXT,
  timestamp INTEGER,
  is_read INTEGER DEFAULT 0,
  is_sent INTEGER DEFAULT 0,
  FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

-- OFFLINE_MESSAGE_QUEUE: Persistence for unreliable mesh
CREATE TABLE offline_message_queue (
  id TEXT PRIMARY KEY,
  recipient_key TEXT,
  encrypted_message BLOB,
  retry_count INTEGER DEFAULT 0,
  created_at INTEGER
);

-- ARCHIVES_FTS: Full-text search for archived messages
CREATE VIRTUAL TABLE archives_fts USING fts5(
  message_id UNINDEXED,
  content,
  sender_name,
  tokenize = 'unicode61'
);
```

**Database Configuration**:
- **WAL Mode**: Enabled for concurrency
- **Foreign Keys**: Enforced (ON DELETE CASCADE)
- **Encryption**: SQLCipher v4
- **Location**: `${appDocDir}/databases/pakconnect_v9.db`

**Critical Files**:
- `lib/data/database/database_helper.dart`: Schema and migrations
- `lib/data/database/database_encryption.dart`: Encryption key derivation
- `lib/data/repositories/contact_repository.dart`: Contact CRUD (SQLite-backed)

## Key Service Classes

### AppCore (Singleton Coordinator)

**Location**: `lib/core/app_core.dart`

**Responsibilities**: Initializes all subsystems in correct order, provides global access to services.

```dart
// Usage in app:
final appCore = await AppCore.initialize();
final bleService = appCore.bleService;
final securityManager = appCore.securityManager;
```

### BLEService (BLE Stack Orchestrator)

**Location**: `lib/data/services/ble_service.dart`

**Responsibilities**: Advertising, scanning, connection management, message sending/receiving.

**Key Methods**:
- `startAdvertising()`: Begin peripheral advertising
- `startScanning()`: Begin central scanning
- `sendMessage(recipient, content)`: Send encrypted message
- `connectToDevice(deviceId)`: Initiate connection

### SecurityManager (Noise Lifecycle)

**Location**: `lib/core/services/security_manager.dart`

**Responsibilities**: Noise session creation, security level upgrades, key management.

**Key Methods**:
- `initializeNoiseSession(contactKey)`: Create Noise session
- `upgradeContactSecurity(contactKey, level)`: Upgrade to MEDIUM/HIGH
- `verifyContact(contactKey, pin)`: PIN-based verification

### MeshRelayEngine (Relay Orchestrator)

**Location**: `lib/core/messaging/mesh_relay_engine.dart`

**Responsibilities**: Relay decision logic, duplicate detection, route finding.

**Key Methods**:
- `processIncomingMessage(message)`: Main relay decision entry point
- `shouldRelay(message)`: Relay policy check
- `findBestRoute(targetKey)`: Route optimization

### OfflineMessageQueue (Message Persistence)

**Location**: `lib/core/messaging/offline_message_queue.dart`

**Responsibilities**: Queue messages for offline recipients, retry logic.

**Key Methods**:
- `enqueue(recipient, message)`: Add to queue
- `processQueue()`: Retry sending queued messages
- `dequeue(messageId)`: Remove after successful send

## Message Flow Architecture

### Sending a Message

```
1. User types in ChatScreen
   ↓
2. ChatScreen calls BLEService.sendMessage(recipient, content)
   ↓
3. BLEService → SecurityManager.encryptMessage(content, recipientKey)
   ↓
4. SecurityManager → NoiseSessionManager.getSession(recipientKey)
   ↓
5. NoiseSession.encryptMessage(plaintext) → ciphertext
   ↓
6. BLEService → MessageFragmenter.fragment(ciphertext) → chunks
   ↓
7. Send each chunk via BLE characteristic write
   ↓
8. If recipient offline → OfflineMessageQueue.enqueue()
```

### Receiving a Message

```
1. BLE characteristic notification received
   ↓
2. BLEMessageHandler.handleIncomingMessage(chunk)
   ↓
3. MessageFragmenter.reassemble(chunks) → complete ciphertext
   ↓
4. SecurityManager.decryptMessage(ciphertext, senderKey)
   ↓
5. NoiseSession.decryptMessage(ciphertext) → plaintext
   ↓
6. MeshRelayEngine.processIncomingMessage(message)
   ↓
7. If for me → Deliver to UI (via Provider/Stream)
   ↓
8. If relay enabled → Find route and forward
```

## Message Fragmentation

**Why**: BLE MTU limits (typically 160-220 bytes), messages can be several KB.

**Strategy**: Split into chunks with sequence numbers, reassemble on receiver.

**Format**:
```
[1-byte: fragment index] [1-byte: total fragments] [N bytes: payload]
```

**Critical File**: `lib/core/utils/message_fragmenter.dart`

**Edge Cases Handled**:
- Out-of-order chunks
- Missing chunks (timeout after 30 seconds)
- Duplicate chunks
- Interleaved messages from different senders

## Power Management

### Adaptive Strategies

**Location**: `lib/core/power/adaptive_power_manager.dart`

Three power modes:
- **HIGH_POWER**: Continuous scanning, always advertising
- **BALANCED**: Burst scanning (10s on, 20s off), periodic advertising
- **LOW_POWER**: Minimal scanning (5s on, 60s off), advertising on demand

**Triggers**: Battery level, screen state, message send events.

**Integration**: `BurstScanningController` bridges power manager to `BLEService`.

## Logging Strategy

### Structured Logging with Emojis

The codebase uses emoji-prefixed logging for easy visual parsing:

```dart
import 'package:logging/logging.dart';

final _logger = Logger('ComponentName');

_logger.info('🎯 Critical decision point');
_logger.warning('⚠️ Potential issue detected');
_logger.severe('❌ Error occurred', error, stackTrace);
```

**Emoji Key**:
- 🎯 Decision points
- ✅ Success/completion
- ❌ Errors
- ⚠️ Warnings
- 🔐 Security operations
- 📡 BLE operations
- 🔄 Relay operations
- 💾 Database operations

## Testing Patterns

### Test Organization

```
test/
├── unit/                    # Pure logic tests (no Flutter deps)
├── widget/                  # Widget tests (Flutter TestWidgets)
├── integration/             # End-to-end flows
└── *.dart                   # Mixed test files
```

### Common Test Patterns

```dart
// Unit test with Arrange-Act-Assert
void main() {
  group('NoiseSession', () {
    test('encrypts and decrypts message correctly', () {
      // Arrange
      final session = NoiseSession(pattern: 'XX');
      final plaintext = 'Hello';

      // Act
      final ciphertext = session.encryptMessage(utf8.encode(plaintext));
      final decrypted = session.decryptMessage(ciphertext);

      // Assert
      expect(utf8.decode(decrypted), equals(plaintext));
    });
  });
}
```

### Testing with SQLite

Use `sqflite_common_ffi` for desktop testing:

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('database test', () {
    // Test code
  });
}
```

## Common Development Tasks

### Adding a New Noise Pattern

1. Define pattern in `lib/core/security/noise/noise_patterns.dart`
2. Update `NoiseSession` to support new handshake flow
3. Add pattern selection logic in `SecurityManager`
4. Test with integration tests
5. Update documentation

### Adding a New Relay Policy

1. Create policy class in `lib/core/messaging/relay_policy.dart`
2. Implement `RelayPolicy` interface
3. Register in `RelayConfigManager`
4. Add configuration UI in settings
5. Test relay behavior with `relay_phase*_test.dart`

### Debugging Handshake Issues

1. Enable verbose logging: Set `Logger.root.level = Level.ALL`
2. Check handshake phase progression in logs (look for 🎯 emojis)
3. Verify Noise session state: `NoiseSession.state` should be `established`
4. Check identity resolution: Ensure `currentEphemeralId` matches sender
5. Use `test/debug_handshake_test.dart` for isolated testing

### Debugging Relay Issues

1. Check `SeenMessageStore`: May contain stale entries (clear after 5 minutes)
2. Verify relay enabled: `MeshRelayEngine.isRelayEnabled`
3. Check topology: `NetworkTopologyAnalyzer.estimateNetworkSize()`
4. Inspect routes: `SmartMeshRouter.findRoute(targetKey)`
5. Use `test/relay_phase*_test.dart` for regression testing

## Performance Considerations

### BLE Performance

- **MTU Negotiation**: Always request max MTU (512 bytes) for fewer fragments
- **Characteristic Caching**: Cache characteristic references to avoid repeated discovery
- **Connection Pooling**: Limit concurrent connections (max 7 on Android)

### Database Performance

- **Batch Operations**: Use transactions for multiple inserts/updates
- **Indexed Queries**: Ensure foreign keys and frequently queried fields are indexed
- **FTS5 Search**: Use for text search, not for exact matches (use WHERE for exact)

### Mesh Performance

- **Relay Limits**: Cap relay hops (max 3-5) to prevent network flooding
- **Duplicate Detection**: Use bloom filters for memory-efficient seen message tracking
- **Topology Updates**: Cache topology for 5-10 seconds, don't recalculate on every message

## 🎯 Confidence Protocol (MANDATORY for Critical Areas)

**Purpose**: Prevent regressions and 7-day debugging rabbit holes by verifying approach BEFORE implementation.

Before modifying these systems, run confidence assessment (0.0-1.0):

### Critical Areas (≥90% confidence required):

- **BLE handshake phases** (CONNECTION_READY → IDENTITY_EXCHANGE → NOISE_HANDSHAKE → CONTACT_STATUS_SYNC)
- **Noise session state machine** (especially XX/KK pattern selection, nonce sequencing)
- **Identity resolution** (publicKey vs persistentPublicKey vs currentEphemeralId)
- **Mesh relay routing** (MeshRelayEngine, SmartMeshRouter, SeenMessageStore)
- **Message fragmentation/defragmentation** (MessageFragmenter with sequence numbers)
- **Database schema migrations** (MUST test backwards compatibility)

### Confidence Checklist:

- [ ] **No Duplicates (20%)**: Is this functionality already implemented elsewhere?
  - Example: Don't add new identity storage if Contact model already handles it
  - Check: BLEService, SecurityManager, MeshRelayEngine, ContactRepository

- [ ] **Architecture Compliance (20%)**: Does this follow existing patterns?
  - Layered architecture: Presentation → Domain → Core → Data
  - Repository pattern for data access
  - Provider pattern (Riverpod 3.0) for state
  - Service layer for business logic

- [ ] **Official Docs Verified (15%)**: Have I checked authoritative sources?
  - BLE GATT specification (for handshake timing)
  - Noise Protocol spec (for XX/KK patterns, rekeying)
  - Flutter BLE package docs (for MTU negotiation)
  - ChaCha20-Poly1305 AEAD spec (for encryption/decryption)

- [ ] **Working Reference (15%)**: Have I found proven implementation?
  - GitHub search: "BLE mesh relay Dart"
  - GitHub search: "Noise Protocol Flutter"
  - Stack Overflow: Specific error messages (e.g., "ChaCha20 PAD error")

- [ ] **Root Cause Identified (15%)**: Do I understand WHY, not just WHAT?
  - Self-connection: Is this MAC address filtering? Ephemeral ID collision? Peripheral advertising logic?
  - Notification failure: Is this Phase 0 vs Phase 1 timing? Characteristic caching? BLE state issue?
  - PAD errors: Is this Noise AEAD layer? Fragmentation reassembly? Nonce sequencing?

- [ ] **Codex Second Opinion (15%)**: Have I consulted GPT-5 for unbiased perspective?
  - **When to trigger**: Score <70% OR critical areas (security, concurrency, architecture)
  - **Reasoning effort**: Use `high` for security/critical, `medium` for standard review
  - **What to ask**: "Review this approach for [security vulnerabilities / edge cases / alternative solutions]"
  - **Value**: Fresh perspective without my implementation bias, catches blind spots

### Scoring:

- **≥90%**: ✅ Proceed immediately with implementation (optional: Codex review after completion)
- **70-89%**: ⚠️ Present 2-3 alternative approaches with trade-offs, **then consult Codex** for unbiased evaluation
- **<70%**: ❌ STOP - Ask clarifying questions, research more, **consult Codex for alternative approaches**, don't guess

### Codex Integration Workflow:

**Automatic Triggers** (I'll call Codex without asking):
1. **Confidence score <70%**: Get second opinion before asking user questions
2. **Critical areas** (BLE handshake, Noise, mesh routing, security): Review approach before implementation
3. **Multi-day debugging**: If stuck >2 hours, escalate to Codex for fresh perspective
4. **Architecture changes**: Consult on trade-offs before proposing to user

**Manual Triggers** (User requests):
- "Have Codex review this"
- "Ask Codex about [topic]"
- "Get a second opinion on [approach]"

**Reasoning Effort Selection**:
- **High**: Security audits, cryptography, race conditions, critical bugs
- **Medium**: Code reviews, refactoring, architecture discussions (default)
- **Low**: Simple questions, explanations, documentation lookups

### Usage Example:

**User**: "Fix Device A showing Device B on both central AND peripheral sides"

**Confidence Check**:
- [ ] No duplicates? ❌ (dual-role BLE issue, not simple self-connection) = 0%
- [ ] Architecture compliance? ⚠️ (need to check central/peripheral role separation) = 10%
- [ ] Official docs? ❌ (BLE GATT spec for dual-role connection tracking) = 0%
- [ ] Working reference? ❌ (no dual-role device appearance example found) = 0%
- [ ] Root cause? ❌ (could be discovered device list, MAC filtering, or connection tracking) = 0%
- [ ] Codex opinion? ⏳ (not consulted yet) = 0%

**Score: 0% + 10% + 0% + 0% + 0% + 0% = 10% < 70%**

**Action**: ❌ STOP - Consult Codex first, then ask user questions:

**Step 1 - Codex Consultation** (automatic):
```
Me → Codex (medium reasoning):
"BLE dual-role device issue: Device A initiates central connection to Device B.
Bug: Device A incorrectly shows Device B on BOTH central side (correct) AND peripheral side (wrong).
Symptoms: Dual-role UI badge appears, notifications not subscribed on connected device.
What causes a dual-role BLE device to incorrectly list centrally-connected peers as peripheral discoveries?"

Codex → Returns patterns from dual-role BLE implementations (connection tracking, deduplication logic)
```

**Step 2 - User Questions** (informed by Codex):
1. "Can you share logs showing Device A's connection to Device B and which side(s) it appears?"
2. "Does Device B also incorrectly show Device A twice, or only Device A is affected?"
3. "When you tap Device B in Device A's peripheral list, does the same chat open?"
4. "Are notification subscriptions set up for connections made by each device role?"

### ROI:

Spending 200 tokens on confidence check prevents 20,000 tokens debugging wrong layer (like spending 7 days on PAD errors that were actually Noise AEAD vs fragmentation layer confusion).

**Think of it like unit tests**: You wouldn't skip tests for PakConnect - don't skip confidence checks either.

## Codex MCP Configuration & Usage Guide

**Codex** is a Claude 3.7 Sonnet MCP (Model Context Protocol) server configured to provide deep analysis, code reviews, and architectural guidance.

### What is Codex?

Codex is an external reasoning service that I (Claude Haiku) can call for:
- **Fresh perspectives** on architectural decisions
- **Security audits** of cryptographic implementations
- **Code reviews** with specialized expertise
- **Debugging guidance** for complex multi-day issues
- **Alternative approaches** when confidence is low

Think of it as a "second opinion from a smarter Claude" - it has access to newer models and extended reasoning capabilities.

### How to Invoke Codex (For Users)

**You can explicitly request Codex in any message:**

```
"Have Codex review this approach for security vulnerabilities"
"Ask Codex about the best pattern for [problem]"
"Get a second opinion on [my proposal] from Codex"
"Use Codex to analyze why [this is failing]"
```

### How I Use Codex (Automatic Triggers)

I automatically invoke Codex in these situations:

1. **Low Confidence** (`<70%`): When my confidence assessment on critical work is below 70%, I call Codex BEFORE asking you for clarification
2. **Critical Areas**: BLE handshake, Noise Protocol, mesh relay routing, security operations
3. **Stuck Debugging** (>2 hours): If I've been investigating an issue without resolution, I escalate to Codex
4. **Architecture Changes**: Before proposing significant refactoring, I get Codex's unbiased perspective

### MCP Server Details

**Server Name**: `mcp__codex__codex` (or `mcp__codex__codex-reply` for follow-ups)

**Configuration Status**:
- ✅ Configured in your environment
- ✅ Accessible to me (Claude Haiku)
- ⚠️ Requires proper parameter formatting to work correctly

**Parameters I Must Provide**:

```
{
  "prompt": "The actual question/request for Codex",
  "model": "opus" or "sonnet" (optional, defaults to sonnet),
  "sandbox": "read-only" or "workspace-write" (optional),
  "base-instructions": "Custom system prompt" (optional),
  "cwd": "Working directory" (optional)
}
```

### Common Mistakes I Make (and how to fix them)

**❌ MISTAKE #1: Wrong Parameter Names**
```
WRONG: mcp__codex__codex with "question" field
WRONG: mcp__codex__codex with "query" field
WRONG: mcp__codex__codex with "text" field

✅ CORRECT: mcp__codex__codex with "prompt" field
```

**❌ MISTAKE #2: Calling the Wrong Tool**
```
WRONG: mcp__codex__codex for follow-up messages
✅ CORRECT: mcp__codex__codex-reply for follow-ups (requires conversationId)
```

**❌ MISTAKE #3: Vague Prompts**
```
WRONG: "Is this architecture good?"
WRONG: "Review this code"
WRONG: "Fix the bug"

✅ CORRECT: "Review this Noise Protocol implementation for:
  1. Correct nonce sequencing (should be strictly increasing per session)
  2. AEAD authentication tag verification (no silent failures)
  3. Forward secrecy guarantees (rekeying after message count)
  4. Thread safety (concurrent access to shared state)"
```

**❌ MISTAKE #4: Not Specifying Reasoning Effort**
The "reasoning" effort is controlled implicitly by prompt complexity. Let me be more explicit:

```
For HIGH reasoning (security-critical):
  - Use detailed prompts with context
  - Ask for multiple perspectives
  - Explicitly ask for edge case analysis

For MEDIUM reasoning (standard):
  - Ask for code review or architecture feedback
  - Include specific requirements/constraints

For LOW reasoning (lookups):
  - Don't use Codex for simple questions (I can handle these)
  - Use Codex only when you need deep analysis
```

**❌ MISTAKE #5: Not Including Enough Context**
```
WRONG: "Why is this failing?"
✅ CORRECT: "BLE handshake is failing at Phase 1.5 (Noise XX pattern).
  - Device A sends message 1 (e + s)
  - Device B should respond with (e + dhee + s + dhse + payload)
  - Actual: Device B logs NoiseException('Invalid nonce')
  - Database shows currentEphemeralId matches, so identity is correct
  - Error occurs 3/5 connection attempts (intermittent)

  What causes intermittent Noise handshake failures with valid identities?
  Is this nonce sequencing, timestamp synchronization, or session state?"
```

**❌ MISTAKE #6: Ignoring Codex Response Format**
Codex returns structured responses:
```
{
  "type": "text" or "error",
  "content": "The actual analysis or error message",
  "metadata": {...}
}
```

I need to extract and interpret the `content` field, not treat the whole response as the answer.

### When to Use Codex

✅ **USE CODEX FOR**:
- Security audits (Noise, ChaCha20, key derivation)
- Architecture reviews (dual-role BLE, state management)
- Complex debugging (multi-day stuck issues)
- Alternative approaches (when <70% confidence)
- Performance optimization decisions
- Edge case analysis

❌ **DON'T USE CODEX FOR**:
- Simple API lookups (check docs instead)
- Quick syntax questions (I can answer these)
- File reading/writing (I have tools for this)
- Test execution (I can run Flutter tests)
- Basic debugging (grep logs, read code first)
- Quick explanations (I can explain code)

### Response Patterns to Expect

**Pattern 1: Confirmatory Response**
```
Codex: "Your approach is sound. Here's why:
  1. [Confirms your understanding]
  2. [Identifies what you got right]
  3. [Suggests one improvement]"

→ I proceed with implementation immediately
```

**Pattern 2: Alternative Approaches**
```
Codex: "Your approach works, but consider these alternatives:
  Approach A: [Pros/cons] (Better for X)
  Approach B: [Pros/cons] (Better for Y)
  Recommended: Approach B because [reasoning]"

→ I present options to you with pros/cons
```

**Pattern 3: Critical Issue Found**
```
Codex: "Your approach has a flaw:
  [Description of the problem]
  Likely cause: [Root cause]
  Fix: [Recommended solution]"

→ I STOP implementation, ask clarifying questions, pivot approach
```

**Pattern 4: Needs More Context**
```
Codex: "Can you clarify:
  1. [Question A]
  2. [Question B]"

→ I ask YOU these clarifying questions
```

### Example: Proper Codex Usage

**User Says**: "Fix the Noise handshake intermittent failures"

**My Confidence Check**: ~45% (intermittent + cryptography = high complexity)

**My Action**: Call Codex BEFORE asking you questions

**Codex Prompt I Send**:
```
"BLE Noise XX handshake intermittently fails (3/5 attempts).
Logs show:
  - Phase 0: CONNECTION_READY ✅
  - Phase 1: IDENTITY_EXCHANGE ✅
  - Phase 1.5: NoiseException('Invalid nonce') ❌

Context:
  - Nonce is stored in CipherState._n (should be u64, strictly increasing)
  - Session created fresh per connection (no reuse)
  - Same two devices, random failure pattern
  - No clock skew visible in logs

What causes intermittent nonce errors in Noise XX handshake?
Options to investigate:
  A) Nonce not incrementing (threading issue)?
  B) AEAD authentication failure (key derivation)?
  C) State machine race condition (Phase 1 not complete before Phase 1.5)?
  D) Device role confusion (central vs peripheral)?

Which is most likely and how do I verify?"
```

**Codex Response** (hypothetical):
```
"Most likely: Option C - race condition in state machine.

Why:
  1. Intermittent = timing-dependent
  2. Nonce error during Phase 1.5 = state not ready
  3. Same devices = rule out key derivation
  4. Random 3/5 = connection timing variance

Verification:
  1. Add mutex lock to Phase 1→1.5 transition
  2. Log state transitions with timestamps
  3. Check for concurrent noiseSessionManager.getSession() calls
  4. Verify Phase 1 callback fires before Phase 1.5 starts

Secondary check:
  - Ensure ephemeralId rotation doesn't race with nonce initialization
  - Verify MTU negotiation completes before Phase 1 message"
```

**Then I Ask You**:
1. "Can you share logs from 3 failed handshake attempts?"
2. "Are multiple threads calling getSession() simultaneously?"
3. "Does adding a 100ms delay between Phase 1→1.5 help?"

---

### Troubleshooting Codex Integration

**If Codex doesn't respond**:
1. Check MCP server status: Is Codex running?
2. Check my prompt: Did I include "prompt" field?
3. Check token budget: Is Codex request too long?
4. Check conversationId: For replies, is it valid?

**If Codex gives wrong answer**:
1. Ask me to call Codex again with better prompt
2. Provide more context directly in message
3. Request specific analysis (security, performance, etc.)

**If I'm not calling Codex when you expect it**:
1. Explicitly request: "Have Codex review this"
2. This overrides my confidence threshold

---

## Critical Invariants

### Identity Invariants

1. **publicKey NEVER changes** (used as primary key in DB)
2. **persistentPublicKey only set after MEDIUM+ pairing** (nullable until then)
3. **currentEphemeralId updates on every connection** (session-specific)
4. **Chat lookup uses persistentPublicKey if available**, else publicKey

### Session Invariants

1. **Noise session MUST complete handshake before encryption** (state == established)
2. **Nonces MUST be sequential** (gaps trigger replay protection)
3. **Sessions MUST rekey after 10k messages or 1 hour** (forward secrecy)
4. **Thread safety**: Noise operations MUST be serialized per session

### Relay Invariants

1. **Message IDs MUST be deterministic** (same content → same ID across devices)
2. **Duplicate detection window = 5 minutes** (older messages re-relayed)
3. **Relay MUST deliver locally before forwarding** (prevent message loss)

## Integration Checklist

When integrating new features:

- [ ] Update schema version if database changes
- [ ] Add migration logic in `DatabaseHelper`
- [ ] Update relevant providers in `lib/presentation/providers/`
- [ ] Add logging with appropriate emoji prefixes
- [ ] Write unit tests (target >85% coverage)
- [ ] Test with BLE on real devices (emulator BLE is unreliable)
- [ ] Update this CLAUDE.md if architecture changes
- [ ] Run `flutter analyze` (should have zero errors)

## Known Limitations

- **BLE Range**: ~10-30m line-of-sight (hardware dependent)
- **Mesh Hops**: Max 3-5 hops before latency becomes noticeable
- **Concurrent Connections**: Android limits to ~7 simultaneous connections
- **Battery Life**: Continuous BLE scanning drains battery (use BALANCED mode)
- **iOS Background**: iOS heavily restricts background BLE (foreground recommended)

## Quick File Reference

### Critical Files by Function

**BLE Stack**:
- `lib/data/services/ble_service.dart` - Main BLE orchestrator
- `lib/core/bluetooth/handshake_coordinator.dart` - Handshake protocol
- `lib/core/bluetooth/peripheral_initializer.dart` - Advertising setup

**Security**:
- `lib/core/security/noise/noise_encryption_service.dart` - Noise API
- `lib/core/services/security_manager.dart` - Security levels
- `lib/core/security/ephemeral_key_manager.dart` - Key rotation

**Mesh**:
- `lib/core/messaging/mesh_relay_engine.dart` - Relay logic
- `lib/core/messaging/message_router.dart` - Routing decisions
- `lib/core/routing/network_topology_analyzer.dart` - Topology analysis

**Database**:
- `lib/data/database/database_helper.dart` - Schema and migrations
- `lib/data/repositories/contact_repository.dart` - Contact CRUD

**UI**:
- `lib/presentation/screens/chat_screen.dart` - Chat interface
- `lib/presentation/providers/ble_providers.dart` - BLE state

## Cursor Rules Applied

Based on `.cursor/rules/global.mdc`:

- **Be direct and terse**: Code first, explanation after
- **Anticipate needs**: Suggest solutions proactively
- **Treat as expert**: No hand-holding, technical depth expected
- **Answer immediately**: Give the solution upfront

Based on `.cursor/rules/flutter.mdc`:

- **SOLID Principles**: Applied throughout codebase
- **Concise code**: Functions <20 lines where possible
- **Logging over print**: Use `logging` package exclusively
- **Testing**: Arrange-Act-Assert pattern, high coverage targets
- **Immutability**: Widgets are immutable, prefer const constructors
- **Separation of concerns**: Clear boundaries between layers

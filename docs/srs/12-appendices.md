# Appendices

## Overview

This document provides supplementary information to support the PakConnect System Requirements Specification (SRS), including glossary of terms, acronyms, development environment setup, and additional technical details.

---

# Appendix A: Glossary of Terms

### AEAD (Authenticated Encryption with Associated Data)
Encryption mode that provides both confidentiality and authenticity. ChaCha20-Poly1305 is an AEAD cipher used in PakConnect.

### Archive
Long-term storage for old messages. Archived chats are moved from active database to compressed archive storage with full-text search capability.

### BLE (Bluetooth Low Energy)
Low-power wireless communication protocol for short-range data transfer. PakConnect uses BLE for peer-to-peer messaging without internet.

### Central Mode
BLE role where device scans for and connects to peripheral devices. PakConnect operates in both central and peripheral modes simultaneously.

### ChaCha20-Poly1305
Modern AEAD cipher combining ChaCha20 stream cipher with Poly1305 MAC. Faster than AES on devices without hardware AES acceleration.

### Cipher State
Component of Noise Protocol that manages encryption/decryption with a symmetric key and nonce counter. Used after handshake completion.

### Contact
Peer user with whom encryption session has been established. Identified by public key, optional persistent key, and ephemeral ID.

### DH (Diffie-Hellman)
Key exchange algorithm allowing two parties to establish shared secret over insecure channel. PakConnect uses X25519 DH.

### Dual-Role BLE
Operating as both BLE central (scanner/connector) and peripheral (advertiser/acceptor) simultaneously. Required for mesh networking.

### Ephemeral ID
Temporary identifier rotated periodically for privacy. Used for BLE advertising without revealing permanent identity.

### Ephemeral Key
Temporary cryptographic key used for single session. Provides forward secrecy when discarded after use.

### FTS5 (Full-Text Search version 5)
SQLite extension for efficient full-text search. Used for searching archived messages by content.

### GATT (Generic Attribute Profile)
BLE protocol defining how data is organized and exchanged. PakConnect implements custom GATT services for messaging.

### Broadcast Dispatch (legacy model name: Group Message)
Sender-local record for content submitted to several contacts. The app creates
one ordinary direct-message queue entry per recipient; recipients do not share
a group ID, membership state, transcript, or reply channel.

### Handshake
Protocol exchange to establish encrypted session. PakConnect uses Noise XX (3-message) or KK (2-message) patterns.

### Handshake State
Temporary cryptographic state during Noise handshake. Tracks messages exchanged, ephemeral keys, and remote static key.

### HKDF (HMAC-based Key Derivation Function)
Key derivation function specified in RFC 5869. Used in Noise Protocol to derive encryption keys from shared secret.

### Hop Count
Number of relay forwards a message has undergone. Limited to prevent infinite loops in mesh network.

### KK Pattern
2-message Noise handshake for peers with pre-shared static public keys. Faster than XX, used for reconnecting known contacts.

### MAC (Message Authentication Code)
Cryptographic checksum proving message authenticity and integrity. Poly1305 is the MAC in ChaCha20-Poly1305.

### Mesh Network
Decentralized network where nodes relay messages for each other. Extends communication range beyond direct BLE.

### Message ID
Opaque stable identifier created once by the originating path and preserved
through queue/relay handling; its concrete format is not an invariant. The inbound
receive helper derives SHA-256 only as a fallback when legacy/incomplete data
has no protocol message ID.

### MTU (Maximum Transmission Unit)
Maximum size of single BLE packet. Typically 23-512 bytes. Messages larger than MTU are fragmented.

### Multi-Unicast
Submitting individual direct messages to multiple recipients. PakConnect uses
this for local broadcast lists, not as a complete group-conversation protocol.

### Noise Protocol Framework
Cryptographic framework for building secure protocols. Defines patterns for handshakes and transport encryption.

### Nonce
Number used once. Counter incremented for each encrypted message to ensure unique ciphertext even for identical plaintext.

### Offline Queue
Persistent storage for messages to offline recipients. Messages retried with exponential backoff until delivered or expired.

### PBKDF2 (Password-Based Key Derivation Function 2)
Password-based key derivation function using an iterative hash. PakConnect uses
it for export/import passphrases; the mobile SQLCipher credential is generated
randomly and stored in platform secure storage.

### Peripheral Mode
BLE role where device advertises and accepts connections. PakConnect advertises ephemeral ID in peripheral mode.

### Persistent Key
Long-term static public key (X25519) for MEDIUM/HIGH security contacts. Stored after successful verification.

### Public Key
Cryptographic key shared publicly. X25519 public key (32 bytes) identifies contacts in PakConnect.

### QR Code
2D barcode for sharing contact information. Encodes ephemeral ID, display name, and static public key.

### Relay
Forwarding message to next hop toward final destination. Core function of mesh networking.

### Rekey
Generating new encryption keys after threshold (10,000 messages or 1 hour). Maintains forward secrecy.

### Riverpod
Reactive state management library for Flutter. Successor to Provider package, used throughout PakConnect UI.

### Security Level
Trust tier for contact: LOW (ephemeral), MEDIUM (verified PIN), HIGH (cryptographic verification). Determines key persistence.

### Session
Established encrypted communication channel between two peers. Contains cipher states for send/receive.

### SHA-256
Cryptographic hash function producing a 256-bit digest. Used for key
derivation, integrity operations, and the missing-ID inbound fallback; normal
originating paths use opaque IDs.

### SQLCipher
SQLite extension providing transparent AES-256 database encryption. Used to protect local data at rest.

### Static Key
Long-term X25519 keypair. Identity key for user, persistent key for MEDIUM+ contacts.

### Symmetric Key
Single key used for both encryption and decryption. Derived from DH exchange in Noise Protocol.

### TTL (Time To Live)
Maximum lifespan for queued message before considered expired. Prevents indefinite queue growth.

### WAL (Write-Ahead Logging)
SQLite journaling mode allowing concurrent reads during writes. Improves database performance.

### X25519
Elliptic curve Diffie-Hellman key exchange using Curve25519. Standard DH algorithm in Noise Protocol.

### XX Pattern
3-message Noise handshake for peers without pre-shared keys. Provides mutual authentication and forward secrecy.

---

# Appendix B: Acronyms and Abbreviations

| Acronym | Full Form | Context |
|---------|-----------|---------|
| **AEAD** | Authenticated Encryption with Associated Data | Encryption mode (ChaCha20-Poly1305) |
| **AES** | Advanced Encryption Standard | Database encryption (SQLCipher) |
| **API** | Application Programming Interface | Software interfaces |
| **BLE** | Bluetooth Low Energy | Wireless communication |
| **CBC** | Cipher Block Chaining | AES mode for SQLCipher |
| **CPU** | Central Processing Unit | Hardware |
| **CRUD** | Create, Read, Update, Delete | Database operations |
| **DH** | Diffie-Hellman | Key exchange algorithm |
| **ECDH** | Elliptic Curve Diffie-Hellman | X25519 variant |
| **FTS** | Full-Text Search | SQLite extension |
| **GATT** | Generic Attribute Profile | BLE protocol layer |
| **GDPR** | General Data Protection Regulation | EU privacy law |
| **HKDF** | HMAC-based Key Derivation Function | Key derivation (RFC 5869) |
| **HMAC** | Hash-based Message Authentication Code | Keyed hash function |
| **ID** | Identifier | Unique reference |
| **IEEE** | Institute of Electrical and Electronics Engineers | Standards body |
| **IETF** | Internet Engineering Task Force | Standards body |
| **ISO** | International Organization for Standardization | Standards body |
| **JSON** | JavaScript Object Notation | Data format |
| **KB** | Kilobyte | 1,024 bytes |
| **KDF** | Key Derivation Function | HKDF, PBKDF2 |
| **MAC** | Message Authentication Code | Poly1305 |
| **MB** | Megabyte | 1,024 KB |
| **MTU** | Maximum Transmission Unit | BLE packet size |
| **NIST** | National Institute of Standards and Technology | US standards body |
| **OOP** | Object-Oriented Programming | Programming paradigm |
| **OS** | Operating System | Android, iOS, Windows |
| **P2P** | Peer-to-Peer | Decentralized architecture |
| **PBKDF2** | Password-Based Key Derivation Function 2 | Key derivation (RFC 2898) |
| **PIN** | Personal Identification Number | 4-digit verification code |
| **QA** | Quality Assurance | Testing |
| **QR** | Quick Response (Code) | 2D barcode |
| **RAM** | Random Access Memory | Hardware memory |
| **RFC** | Request for Comments | IETF standards |
| **RNG** | Random Number Generator | Entropy source |
| **SDK** | Software Development Kit | Flutter, Android |
| **SHA** | Secure Hash Algorithm | SHA-256 |
| **SIG** | Special Interest Group | Bluetooth organization |
| **SQL** | Structured Query Language | Database query language |
| **SRP** | Single Responsibility Principle | SOLID design |
| **SRS** | Software Requirements Specification | This document |
| **TLS** | Transport Layer Security | HTTPS protocol |
| **TTL** | Time To Live | Message expiration |
| **UI** | User Interface | Screens, widgets |
| **UUID** | Universally Unique Identifier | Device/service ID |
| **WAL** | Write-Ahead Logging | SQLite mode |

---

# Appendix C: Development Environment Setup

## Prerequisites

### Required Software
- **Flutter SDK**: 3.38.4 or higher (CI pinned to 3.44.4)
- **Dart SDK**: 3.10.3 or higher (bundled with Flutter)
- **Git**: Version control

### Platform-Specific Tools

#### Android Development
- **Android Studio**: 2023.1+ (Hedgehog or later)
- **Android SDK**: API 36 compile/target with the locally verified Flutter
  3.41.5 SDK; recheck against the CI Flutter 3.44.4 pin
- **Minimum Android SDK**: API 24 (`flutter.minSdkVersion`)
- **Android NDK**: 28.2.13676358
- **Java Development Kit (JDK)**: Version 17 (pinned in CI)
- **Gradle**: 8.11.1 wrapper

#### iOS Development (macOS only)
- **Deployment target**: iOS 12.0
- **Toolchain**: A compatible Xcode/CocoaPods installation; exact versions are
  not pinned or verified by the current Windows-only evidence

#### Windows Development
- **Visual Studio 2022**: Desktop development with C++
- **Windows 10 SDK**: 10.0.17763.0 or higher

## Setup Steps

### 1. Clone Repository
```bash
git clone https://github.com/AbubakarMahmood/pak_connect.git
cd pak_connect
```

### 2. Install Dependencies
```bash
flutter pub get
```

### 3. Verify Installation
```bash
flutter doctor -v
```

Ensure all required components show checkmarks.

### 4. Configure Android (if applicable)
```bash
# Accept Android licenses
flutter doctor --android-licenses

# Verify NDK installation
ls $ANDROID_HOME/ndk/28.2.13676358
```

### 5. Run Application
```bash
# Debug build (development)
flutter run

# Release run (requires configured Android/iOS signing)
flutter run --release
```

### 6. Run Tests
```bash
# All tests
flutter test

# Specific test file
flutter test test/core/security/noise/noise_end_to_end_test.dart

# With coverage
flutter test --coverage
```

## Troubleshooting

### Common Issues

**Issue**: `sqflite_sqlcipher` native compilation fails
**Solution**: Ensure Android NDK `28.2.13676358` is installed

**Issue**: BLE not working in emulator
**Solution**: Use real physical device (emulators lack BLE hardware)

**Issue**: iOS build fails with CocoaPods error
**Solution**:
```bash
cd ios
pod deintegrate
pod install
cd ..
flutter clean
flutter run
```

**Issue**: Windows build fails with C++ errors
**Solution**: Ensure Visual Studio 2022 with "Desktop development with C++" workload is installed

---

# Appendix D: Security Architecture Details

## Three-ID Model Detailed Explanation

Every contact in PakConnect has **three distinct identifiers**:

### 1. Public Key (Immutable)
- **Type**: First ephemeral ID encountered
- **Persistence**: NEVER changes, used as database primary key
- **Purpose**: Permanent stable identifier for contact
- **Example**: `"ephem_a3f2c8b9..."`

### 2. Persistent Public Key (Optional)
- **Type**: X25519 static public key (32 bytes)
- **Persistence**: Set after MEDIUM or HIGH security upgrade
- **Purpose**: Real cryptographic identity after verification
- **Example**: `"AkNOTE9VUCB..."`

### 3. Current Ephemeral ID (Rotating)
- **Type**: Active Noise session ID
- **Persistence**: Changes with each new connection
- **Purpose**: Privacy through rotation
- **Example**: `"ephem_d7e9f1a2..."`

### Identity Resolution Algorithm

```dart
// For chat lookup (security-aware)
String getChatId(Contact contact) {
  return contact.persistentPublicKey ?? contact.publicKey;
}

// For Noise session lookup (session-aware)
String getNoiseSessionId(Contact contact) {
  return contact.currentEphemeralId ?? contact.publicKey;
}
```

## Security Level Details

| Level | Static Key | Session Type | Verification | Forward Secrecy | Use Case |
|-------|-----------|--------------|--------------|-----------------|----------|
| **LOW** | No (ephemeral only) | XX handshake each connection | None | Yes | Anonymous messaging |
| **MEDIUM** | Yes (stored) | KK handshake after first | 4-digit PIN | Yes | Trusted contacts |
| **HIGH** | Yes (stored) | KK handshake | Cryptographic fingerprint | Yes | Critical contacts |

## Noise Handshake Message Breakdown

### XX Pattern (New Contact)

**Message 1** (Initiator → Responder):
```
e                    [32 bytes: ephemeral public key]
```

**Message 2** (Responder → Initiator):
```
e                    [32 bytes: ephemeral public key]
ee                   [DH(e, re): compute shared secret]
s                    [48 bytes: encrypted static public key]
es                   [DH(e, rs): compute shared secret]
```

**Message 3** (Initiator → Responder):
```
s                    [48 bytes: encrypted static public key]
se                   [DH(s, re): compute shared secret]
```

**Result**: Both parties have `CipherState` for send/receive

### KK Pattern (Known Contact)

**Message 1** (Initiator → Responder):
```
e                    [32 bytes: ephemeral public key]
es                   [DH(e, rs): using pre-shared static]
ss                   [DH(s, rs): using both static keys]
```

**Message 2** (Responder → Initiator):
```
e                    [32 bytes: ephemeral public key]
ee                   [DH(e, re): compute shared secret]
se                   [DH(s, re): compute shared secret]
```

**Result**: Faster (2 messages vs 3), requires pre-shared keys

---

# Appendix E: Message Format Specifications

## Encrypted Message Structure

```
┌─────────────────────────────────────────────┐
│           Encrypted Message Packet          │
├─────────────────────────────────────────────┤
│ Sender Ephemeral ID        [Variable]       │
│ Message Type               [1 byte]         │
│ Encrypted Payload          [Variable]       │
│ Poly1305 MAC               [16 bytes]       │
└─────────────────────────────────────────────┘
```

## Fragmented Message Structure

When message exceeds MTU:

```
┌─────────────────────────────────────────────┐
│              Fragment Packet                │
├─────────────────────────────────────────────┤
│ Fragment Index             [1 byte]         │
│ Total Fragments            [1 byte]         │
│ Opaque transport ID        [variable]       │
│ Fragment Payload           [MTU - 34 bytes] │
└─────────────────────────────────────────────┘
```

**Reassembly Algorithm**:
1. Buffer fragments by Message ID
2. Wait for all fragments (timeout: 30 seconds)
3. Sort by Fragment Index
4. Concatenate payloads
5. Decrypt complete message

## Relay Message Metadata

```json
{
  "originalSender": "AkNOTE9VUCB...",
  "finalRecipient": "BmFLKMNOPQR...",
  "hopCount": 2,
  "maxHops": 3,
  "messageId": "opaque-message-id",
  "timestamp": 1705678901234,
  "ttl": 3600
}
```

---

# Appendix F: Database Migration Guide

## Migration History Summary

| Version | Date | Changes | Breaking |
|---------|------|---------|----------|
| v1 → v2 | 2024-08 | Added `chat_id` to archived_messages | No |
| v2 → v3 | 2024-09 | Removed `user_preferences`, enabled SQLCipher | No |
| v3 → v4 | 2024-09 | Added `app_preferences` table | No |
| v4 → v5 | 2024-10 | Added Noise Protocol fields to contacts | No |
| v5 → v6 | 2024-11 | Added `is_favorite` to contacts | No |
| v6 → v7 | 2024-11 | Added `ephemeral_id` to contacts | No |
| v7 → v8 | 2024-12 | Added three-ID model (persistent + current ephemeral) | No |
| v8 → v9 | 2025-01 | Added four legacy Group*-named tables now used for sender-local broadcast lists | No |
| v9 → v10 | 2025 | Added `seen_messages` mesh deduplication table | No |
| v10 → v11 | 2025 | Added `change_log` table and 9 triggers | No |
| v11 → v12 | 2025 | Added per-peer change-log cursor to `queue_sync_state` | No |

## Migration Code Example (v8 → v9)

```dart
Future<void> _migrateV8toV9(Database db) async {
  await db.execute('''
    CREATE TABLE contact_groups (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      created_at INTEGER NOT NULL,
      last_modified_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE group_members (
      group_id TEXT NOT NULL,
      member_key TEXT NOT NULL,
      added_at INTEGER NOT NULL,
      PRIMARY KEY (group_id, member_key),
      FOREIGN KEY (group_id) REFERENCES contact_groups(id) ON DELETE CASCADE
    )
  ''');

  // ... group_messages and group_message_delivery tables
}
```

## Rollback Procedure

SQLite migrations are **one-way** (no automatic rollback). For rollback:

1. Export user data via app settings
2. Uninstall application
3. Install older version
4. Restore from export (limited compatibility)

**Recommendation**: Always create database backup before upgrading app version.

---

# Appendix G: Performance Benchmarks

## Cryptographic Operations (Target Performance)

| Operation | Target Latency | Implementation |
|-----------|----------------|----------------|
| X25519 Key Generation | < 10 ms | pinenacl (pure Dart) |
| X25519 DH Computation | < 10 ms | pinenacl |
| ChaCha20-Poly1305 Encrypt (1 KB) | < 5 ms | cryptography package |
| ChaCha20-Poly1305 Decrypt (1 KB) | < 5 ms | cryptography package |
| SHA-256 Hash (1 KB) | < 2 ms | crypto package |
| PBKDF2-HMAC-SHA256 (600k iterations) | Device-measured target required | Export/import passphrase |
| Noise XX Handshake (full) | < 100 ms | 3-message exchange |
| Noise KK Handshake (full) | < 50 ms | 2-message exchange |

**Evidence status**: These are target values from the historical SRS, not a
current benchmark result. Record device, OS, build, sample count, and raw output
before claiming them as measured performance.

## BLE Performance

These are historical target/example values, not current measured evidence.

| Metric | Historical target | Example range |
|--------|---------------|-------|
| Connection Establishment | 2-5 seconds | 1-10s |
| MTU Negotiation | 200-300 ms | 100-500ms |
| Characteristic Write (1 packet) | 50-100 ms | 20-200ms |
| Message Send (< MTU) | 200-500 ms | 100ms-2s |
| Message Send (fragmented, 10 KB) | 2-5 seconds | 1-10s |
| Scanning Battery Drain | ~5-10% per hour | Device-dependent |

## Database Operations

These are targets until a cited benchmark artifact proves them on the stated
device/build.

| Operation | Target Latency | Query Type |
|-----------|----------------|------------|
| Insert Message | < 10 ms | Single INSERT |
| Query Chat History (50 messages) | < 20 ms | SELECT with LIMIT |
| Full-Text Search (FTS5) | < 50 ms | FTS5 MATCH query |
| Mobile database open | Device-measured target required | SQLCipher with secure-storage credential |
| VACUUM Operation | 1-5 seconds | Maintenance |

---

# Appendix H: Testing Checklist

## Manual Testing Scenarios

### Core Messaging
- [ ] Send message to online contact (direct delivery)
- [ ] Send message to offline contact (queued delivery)
- [ ] Receive message while app in foreground
- [ ] Receive message while app in background (notification)
- [ ] Send large message (> MTU, fragmentation)
- [ ] Send message with special characters (emoji, Unicode)

### Contact Management
- [ ] Add contact via QR code (XX handshake)
- [ ] Reconnect to existing contact (KK handshake)
- [ ] Upgrade security LOW → MEDIUM (PIN verification)
- [ ] Mark contact as favorite
- [ ] Delete contact (verify cascade delete)
- [ ] Search contacts by name

### Broadcast Lists
- [ ] Create a local list with 3+ recipients
- [ ] Send a broadcast and verify one ordinary direct message per recipient
- [ ] Verify sender-local pending/queued/failed status
- [ ] Verify recipients see only their individual direct chat
- [ ] Add and remove recipients from the local list
- [ ] Delete the local list

### Mesh Networking
- [ ] Relay message through intermediate node (A → B → C)
- [ ] Verify duplicate detection (same message not relayed twice)
- [ ] Test hop limit (max 5 hops)
- [ ] Offline queue sync between devices

### Security
- [ ] Verify message encryption (inspect BLE packets)
- [ ] Test session rekey after 1 hour
- [ ] Verify database encryption (attempt direct SQLite open)
- [ ] Test ephemeral ID rotation

### Edge Cases
- [ ] Connection interrupted during message send
- [ ] App killed while message in queue
- [ ] Database migration after app update
- [ ] Low battery mode (reduced scanning)
- [ ] Multiple simultaneous BLE connections

---

# Appendix I: Known Limitations

### Platform Limitations

1. **Android BLE Connection Target**: The configuration permits up to 7, but
the current user-payload policy is single-link and no device matrix proves a
seven-link maximum.

2. **iOS Background BLE**: Severely restricted by iOS. App must be in foreground for reliable operation.

3. **BLE Range**: A historical 10-30 meter line-of-sight figure is a test
target only; actual range depends on the device and environment.

4. **MTU Variability**: MTU negotiation not guaranteed. Some devices limited to 23-byte MTU (default GATT).

### Security Limitations

5. **No Group Protocol**: Broadcast lists use independent direct messages.
There is no shared group key, authenticated membership state, recipient-side
group history, or shared reply path.

6. **Ephemeral Session Vulnerability**: LOW security contacts have no authentication beyond first ephemeral exchange.

7. **QR Code Trust**: QR scanning assumes physical proximity. No protection against QR code replay if intercepted.

### Operational Limitations

8. **No Cloud Sync**: Messages not synced across user's multiple devices. Each device is independent identity.

9. **Noise Session Not Backed Up**: Session state ephemeral. After restore from backup, all contacts must re-handshake.

10. **Message Size Limits**: Relay spam policy limits an individual relayed
payload to about 10 KiB. Direct fragmented text and binary/media paths have
different limits; physical MTU, timeout, memory, and byte-equality evidence is
still required.

11. **Relay Hop Limit**: The configured limit defaults to 3 and is capped at
5. This bounds loops but limits range.

12. **Archive Compression Not Implemented**: Archive system designed for compression but not yet implemented (v1.0).

---

# Appendix J: Future Enhancements (Out of Scope for v1.0)

The following features are **not implemented** in the current version but documented for potential future development:

### 1. Voice Messages
**Description**: Record and send encrypted voice messages
**Complexity**: Medium (requires audio encoding, larger message handling)

### 2. General File Attachments
**Description**: Arbitrary encrypted document/file attachments. Image/binary
media transport exists, but a general document picker/MIME contract is not a
shipped capability.
**Complexity**: High (requires broader type handling and device validation)

### 3. Multi-Device Sync
**Description**: Sync messages across user's multiple devices
**Complexity**: Very High (requires device pairing, message deduplication, conflict resolution)

### 4. Mesh Routing Optimization
**Description**: Machine learning-based route selection
**Complexity**: High (requires network topology history, performance metrics)

### 5. Archive Compression
**Description**: Compress archived messages to save storage
**Complexity**: Low (database schema ready, needs implementation)

### 6. Read Receipts
**Description**: Sender notified when recipient reads message
**Complexity**: Medium (requires ACK protocol extension)

### 7. Typing Indicators
**Description**: Real-time "is typing..." status
**Complexity**: Low (requires frequent BLE messages, battery impact)

### 8. Message Expiration (Self-Destruct)
**Description**: Messages auto-delete after time period
**Complexity**: Medium (requires background job, timer persistence)

### 9. Contact Nicknames
**Description**: User-defined nicknames for contacts
**Complexity**: Low (database field + UI)

### 10. Custom Notification Sounds
**Description**: Per-contact notification customization
**Complexity**: Low (settings + notification plugin integration)

---

# Appendix K: Compliance and Legal Notices

## Project License

**Project License**: Proprietary and confidential

**Summary**: Public source visibility does not grant permission to use, modify,
or redistribute PakConnect. The rights and restrictions in the root `LICENSE`
control.

**Full License**: See `LICENSE` file in project root.

## Third-Party Licenses

Third-party dependencies retain their own licenses and notices. The repository
does not currently provide a completed release-distribution license audit, so
do not infer that every dependency is permissive or that every distribution
scenario is cleared from package names alone.

## Cryptographic Export Notice

This software includes cryptographic functionality:
- X25519 (Curve25519) key exchange
- ChaCha20-Poly1305 authenticated encryption
- SHA-256 cryptographic hash
- PBKDF2 key derivation

**Export Classification**: Cryptographic export/import obligations vary by
jurisdiction. No Wassenaar or other legal exemption is claimed here; obtain an
appropriate review before distribution.

**Disclaimer**: Users responsible for compliance with local export/import regulations.

## Privacy and Data Protection

**Data Collection**: The default app has no project-operated account,
messaging, analytics, or advertising server. User payloads, public/ephemeral
identity data, acknowledgements, and routing metadata still leave the device
when the user communicates over BLE; OS services may process permission,
notification, file, or Bluetooth metadata.

**Privacy design notes (not an independent GDPR compliance audit)**:
- Data minimization: Only essential data stored
- User control: Users can export and delete all data
- No project-server telemetry in the current default composition

**Privacy Policy**: See `assets/privacy_policy.md` (accessible in-app)

## Disclaimer

**AS-IS Warranty**: Software provided "as is" without warranty of any kind, express or implied.

**Liability**: Authors not liable for damages arising from use of this software.

**Security Disclaimer**: While cryptographic best practices are followed, independent security audit not performed. Use for sensitive communications at your own risk.

---

# Appendix L: Contribution Guidelines

## Code Style

- **Language**: Dart 3.10.3+ with null safety
- **Formatting**: `dart format` (official formatter)
- **Linting**: `flutter analyze` must pass with zero errors
- **Style authority**: `dart format lib test` and `analysis_options.yaml`

## Documentation

- **Code Comments**: Use `///` for public API documentation
- **File Headers**: Include brief description and author
- **Logging**: Use `logging` package, never `print()`
- **Emoji Prefixes**: 🔐 (security), 📡 (BLE), 🔄 (relay), 💾 (database)

## Testing Requirements

- **Coverage Target**: >85% for core logic (policy target; not yet enforced by CI)
- **Test Organization**: Mirror `lib/` structure in `test/`
- **Naming**: `test_file_test.dart` for `lib/test_file.dart`
- **Real Device Testing**: BLE features must be tested on physical devices

## Pull Request Process

1. Create an authorized feature branch (`feature/your-feature-name`)
3. Write tests first (TDD encouraged)
4. Implement feature
5. Run `flutter analyze` and `flutter test`
6. Update `AGENTS.md` or the owning subsystem documentation if architecture or
   an invariant changes; tool projections should remain thin
7. Submit PR with clear description

## Issue Reporting

**Bug Reports**: Include device model, OS version, app version, logs
**Feature Requests**: Explain use case and expected behavior
**Security Issues**: Email privately to maintainer (do not open public issue)

---

## Document Version

**Appendices Version**: 1.0
**Last Updated**: 2026-07-11
**Maintained By**: PakConnect Development Team

---

**End of Appendices**

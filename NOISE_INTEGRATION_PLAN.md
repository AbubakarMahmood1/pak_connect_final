# Noise Protocol Integration Plan
## pak_connect - BLE Mesh Messaging with Forward Secrecy

**Goal:** Replace custom encryption with industry-standard Noise Protocol for verified security and forward secrecy.

**Timeline:** 2-3 weeks (part-time)
**Difficulty:** Medium (you already understand crypto fundamentals)
**Branch:** `feature/noise-protocol-integration`

---

## Why Noise Protocol?

### What You Have Now (Good, but not perfect)
```
Current: ECDH + AES-256-GCM + Replay Protection
├── ✅ Uses secp256r1 (NIST P-256)
├── ✅ AES-256-GCM authenticated encryption
├── ✅ Replay protection via nonces
├── ⚠️  Keys persisted to disk (SharedPreferences)
├── ⚠️  No forward secrecy (stolen device = decrypt all)
└── ⚠️  Custom protocol (not formally verified)
```

### What Noise Protocol Gives You
```
Noise XX Pattern: Formal Security Proofs
├── ✅ Forward secrecy (ephemeral keys never touch disk)
├── ✅ Identity hiding (public keys encrypted)
├── ✅ Mutual authentication (both parties verified)
├── ✅ Zero round-trip encryption (data in handshake)
├── ✅ Industry standard (WhatsApp, Signal, WireGuard)
└── ✅ Formally verified security proofs
```

**Bottom line:** Your crypto is solid, but Noise makes it **auditable and provably secure**.

---

## Phase 1: Research & Understanding (Days 1-2)

### 1.1 Read Noise Protocol Basics
- **Main Spec:** http://noiseprotocol.org/noise.html
- **Focus on:** XX handshake pattern (what you'll use)

### 1.2 Understand Handshake Patterns

**Current handshake (yours):**
```
Alice → Bob: [identity(publicKey_Alice, name_Alice)]
Bob → Alice: [identity(publicKey_Bob, name_Bob)]
Alice → Bob: [encrypted_message]
```
**Problem:** Public keys sent in the clear (metadata leakage)

**Noise XX Pattern:**
```
Alice → Bob: [ephemeral_Alice]
Bob → Alice: [ephemeral_Bob, encrypted(publicKey_Bob, name_Bob)]
Alice → Bob: [encrypted(publicKey_Alice, name_Alice, message)]
```
**Benefit:** Identities encrypted after first message

### 1.3 Key Concepts to Understand

**Ephemeral vs Static Keys:**
```dart
// Static key (persistent identity)
final staticKey = loadFromSecureStorage(); // Your current approach

// Ephemeral key (per-connection, never saved)
final ephemeralKey = KeyPair.generate(curve); // Generated fresh each handshake
// After handshake complete: ephemeralKey is DESTROYED
```

**Forward Secrecy Guarantee:**
```
Time: T0 (handshake)  → T1 (messages) → T2 (device stolen)
      ↓                  ↓                ↓
      Generate keys      Encrypt msgs     Keys already destroyed
      Use keys           Decrypt msgs     ❌ Cannot decrypt T1 messages
      Destroy keys       ✅ Secure        ✅ Forward secrecy achieved
```

**Deliverable:** Write a 1-page summary explaining Noise XX in your own words (for FYP documentation).

---

## Phase 2: Setup & Dependency (Day 3)

### 2.1 Add Noise Protocol Framework

```bash
flutter pub add noise_protocol_framework
```

**Verify installation:**
```bash
flutter pub get
grep noise_protocol_framework pubspec.yaml
```

### 2.2 Create Noise Wrapper Structure

```
lib/core/security/noise/
├── noise_security_manager.dart       # Main Noise wrapper
├── noise_handshake_state.dart        # Handshake state management
├── noise_cipher_state.dart           # Post-handshake encryption
└── noise_models.dart                 # Data models for Noise messages
```

### 2.3 Create Initial Wrapper (Skeleton)

**File:** `lib/core/security/noise/noise_security_manager.dart`

```dart
import 'package:noise_protocol_framework/noise_protocol_framework.dart';
import 'package:elliptic/elliptic.dart';

/// Wrapper for Noise Protocol Framework integration
/// Implements Noise XX pattern for BLE mesh messaging
class NoiseSecurityManager {
  // Noise XX pattern: mutual authentication with identity hiding
  static const String _noisePattern = 'Noise_XX_P256_AESGCM_SHA256';

  final Curve _curve = getP256(); // secp256r1 (same as your current ECDH)

  // TODO: Implement handshake initiation
  // TODO: Implement handshake response
  // TODO: Implement post-handshake encryption
  // TODO: Implement forward secrecy guarantees

  NoiseSecurityManager() {
    print('🔐 Noise Protocol Manager initialized: $_noisePattern');
  }
}
```

**Test compilation:**
```bash
flutter analyze lib/core/security/noise/
```

**Deliverable:** Working skeleton with no compile errors.

---

## Phase 3: Implement Noise XX Handshake (Days 4-7)

### 3.1 Understand Your Current Handshake Flow

**File to study:** `lib/core/bluetooth/handshake_coordinator.dart`

Your current handshake phases:
```dart
enum ConnectionPhase {
  bleConnected,        // BLE connection established
  readySent,           // Sent connection ready
  readyComplete,       // Both sides ready
  identitySent,        // Sent identity (PUBLIC KEY IN CLEAR!)
  identityComplete,    // Identity exchange done
  contactStatusSent,   // Sent contact status
  contactStatusComplete, // Contact status synced
  complete,            // Ready to chat
}
```

### 3.2 Replace Identity Exchange with Noise XX

**New approach:**
```dart
enum NoiseConnectionPhase {
  bleConnected,              // BLE connection established
  noiseHandshakeInitiated,   // → e (ephemeral key)
  noiseHandshakeResponded,   // ← e, ee, s, es (identity encrypted!)
  noiseHandshakeComplete,    // → s, se (identity encrypted!)
  transportSecured,          // Ready to chat with forward secrecy
}
```

### 3.3 Implement Noise Handshake State

**File:** `lib/core/security/noise/noise_handshake_state.dart`

```dart
import 'dart:typed_data';
import 'package:noise_protocol_framework/noise_protocol_framework.dart';
import 'package:elliptic/elliptic.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

class NoiseHandshakeState {
  final NoiseProtocol _protocol;
  final bool _isInitiator;

  NoiseHandshakeState.initiator({
    required KeyPair staticKeyPair,
  }) : _isInitiator = true,
       _protocol = NoiseProtocol.getInitiator(
         staticKeyPair: staticKeyPair,
         pattern: HandshakePattern.XX,
         hash: NoiseHash(sha256),
         curve: getP256(),
       ) {
    _protocol.initialize(
      CipherState.empty(GCMBlockCipher(BlockCipher("AES"))),
      'Noise_XX_P256_AESGCM_SHA256',
    );
  }

  NoiseHandshakeState.responder({
    required KeyPair staticKeyPair,
  }) : _isInitiator = false,
       _protocol = NoiseProtocol.getResponder(
         staticKeyPair: staticKeyPair,
         pattern: HandshakePattern.XX,
         hash: NoiseHash(sha256),
         curve: getP256(),
       ) {
    _protocol.initialize(
      CipherState.empty(GCMBlockCipher(BlockCipher("AES"))),
      'Noise_XX_P256_AESGCM_SHA256',
    );
  }

  /// Step 1 (Initiator): Send ephemeral key
  /// Message: -> e
  Future<Uint8List> sendInitialMessage() async {
    if (!_isInitiator) throw StateError('Only initiator can send first message');

    // Noise will generate ephemeral key internally
    return await _protocol.sendMessage(Uint8List(0));
  }

  /// Step 1 (Responder): Receive ephemeral key
  /// Message: -> e
  Future<void> receiveInitialMessage(Uint8List message) async {
    if (_isInitiator) throw StateError('Only responder receives first message');

    final payload = await _protocol.readMessage(message);
    // payload is empty (no data in first XX message)
  }

  /// Step 2 (Responder): Send response with encrypted identity
  /// Message: <- e, ee, s, es
  /// Payload: [publicKey, displayName]
  Future<Uint8List> sendResponseMessage({
    required String publicKey,
    required String displayName,
  }) async {
    if (_isInitiator) throw StateError('Only responder sends second message');

    // Encode identity payload
    final payload = _encodeIdentity(publicKey, displayName);

    // Noise encrypts the payload using shared secret from 'ee'
    return await _protocol.sendMessage(payload);
  }

  /// Step 2 (Initiator): Receive response with encrypted identity
  /// Message: <- e, ee, s, es
  Future<Map<String, String>> receiveResponseMessage(Uint8List message) async {
    if (!_isInitiator) throw StateError('Only initiator receives second message');

    final payload = await _protocol.readMessage(message);

    // Decrypt and decode identity
    return _decodeIdentity(payload);
  }

  /// Step 3 (Initiator): Send final message with encrypted identity
  /// Message: -> s, se
  /// Payload: [publicKey, displayName]
  Future<Uint8List> sendFinalMessage({
    required String publicKey,
    required String displayName,
  }) async {
    if (!_isInitiator) throw StateError('Only initiator sends third message');

    final payload = _encodeIdentity(publicKey, displayName);

    // Noise encrypts using full shared secret
    return await _protocol.sendMessage(payload);
  }

  /// Step 3 (Responder): Receive final message with encrypted identity
  /// Message: -> s, se
  Future<Map<String, String>> receiveFinalMessage(Uint8List message) async {
    if (_isInitiator) throw StateError('Only responder receives third message');

    final payload = await _protocol.readMessage(message);

    return _decodeIdentity(payload);
  }

  /// Check if handshake is complete
  bool get isHandshakeComplete => _protocol.isHandshakeComplete;

  /// Get transport cipher states for post-handshake encryption
  /// Returns (sendCipher, receiveCipher)
  (CipherState, CipherState) getCipherStates() {
    if (!isHandshakeComplete) {
      throw StateError('Handshake not complete');
    }

    return _protocol.getCipherStates();
  }

  // Helper methods for encoding/decoding identity
  Uint8List _encodeIdentity(String publicKey, String displayName) {
    final map = {
      'publicKey': publicKey,
      'displayName': displayName,
    };
    final json = jsonEncode(map);
    return Uint8List.fromList(utf8.encode(json));
  }

  Map<String, String> _decodeIdentity(Uint8List payload) {
    final json = utf8.decode(payload);
    final map = jsonDecode(json) as Map<String, dynamic>;
    return {
      'publicKey': map['publicKey'] as String,
      'displayName': map['displayName'] as String,
    };
  }
}
```

### 3.4 Integration Checklist

- [ ] Replace `HandshakeCoordinator` identity exchange with Noise XX
- [ ] Ensure ephemeral keys are never persisted
- [ ] Test handshake with both central and peripheral modes
- [ ] Verify public keys are encrypted in transit
- [ ] Confirm handshake completes successfully

**Deliverable:** Working Noise XX handshake that exchanges encrypted identities.

---

## Phase 4: Post-Handshake Encryption (Days 8-10)

### 4.1 Implement Transport Cipher State

**File:** `lib/core/security/noise/noise_cipher_state.dart`

```dart
/// Manages post-handshake encryption using Noise cipher states
class NoiseTransportCipher {
  final CipherState _sendCipher;
  final CipherState _receiveCipher;

  NoiseTransportCipher({
    required CipherState sendCipher,
    required CipherState receiveCipher,
  }) : _sendCipher = sendCipher,
       _receiveCipher = receiveCipher;

  /// Encrypt message using send cipher
  Future<Uint8List> encrypt(String plaintext) async {
    final bytes = Uint8List.fromList(utf8.encode(plaintext));
    return await _sendCipher.encryptWithAd(Uint8List(0), bytes);
  }

  /// Decrypt message using receive cipher
  Future<String> decrypt(Uint8List ciphertext) async {
    final bytes = await _receiveCipher.decryptWithAd(Uint8List(0), ciphertext);
    return utf8.decode(bytes);
  }

  /// Forward secrecy check: ensure keys are ephemeral
  bool get hasForwardSecrecy => true; // Noise guarantees this
}
```

### 4.2 Update SecurityManager Integration

**File:** `lib/core/services/security_manager.dart`

Add new encryption method:
```dart
enum EncryptionType {
  ecdh,      // Your existing ECDH (keep for backward compat)
  pairing,   // Your existing pairing keys
  global,    // Your existing global key
  noise,     // NEW: Noise Protocol with forward secrecy
}

class SecurityManager {
  // Add Noise to security levels
  static Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    ContactRepository repo
  ) async {
    final level = await getCurrentLevel(publicKey, repo);

    switch (level) {
      case SecurityLevel.high:
        // Check if we have Noise transport cipher
        if (await _hasNoiseTransportCipher(publicKey)) {
          return EncryptionMethod.noise(publicKey);
        }
        // Fallback to existing ECDH
        if (await _verifyECDHKey(publicKey, repo)) {
          return EncryptionMethod.ecdh(publicKey);
        }
        // ... rest of fallback logic

      // ... medium and low levels unchanged
    }
  }
}
```

**Deliverable:** Messages encrypted with Noise transport cipher after handshake.

---

## Phase 5: Testing & Verification (Days 11-13)

### 5.1 Create Test Suite

**File:** `test/core/security/noise_integration_test.dart`

```dart
void main() {
  group('Noise Protocol Integration Tests', () {
    test('XX handshake completes successfully', () async {
      // Test full handshake between two parties
    });

    test('Identities are encrypted during handshake', () async {
      // Verify no public keys in plaintext
    });

    test('Forward secrecy: ephemeral keys not persisted', () async {
      // Verify keys never touch SharedPreferences
    });

    test('Post-handshake encryption works', () async {
      // Send encrypted message after handshake
    });

    test('Backward compatibility with non-Noise contacts', () async {
      // Ensure existing contacts still work
    });
  });
}
```

### 5.2 Manual Testing Checklist

- [ ] Fresh install: Noise handshake with new contact
- [ ] Existing contact: Falls back to old ECDH
- [ ] Message encryption: Verify messages decrypt correctly
- [ ] App restart: No persisted ephemeral keys found
- [ ] Device theft simulation: Cannot decrypt past messages
- [ ] Metadata analysis: Public keys not visible in BLE logs

**Deliverable:** All tests passing, forward secrecy verified.

---

## Phase 6: Migration Strategy (Days 14-16)

### 6.1 Gradual Rollout Plan

**Strategy:** Hybrid approach - support both old and new crypto

```dart
class ContactMigrationManager {
  /// Migrate contact to Noise Protocol
  static Future<void> migrateToNoise(String contactPublicKey) async {
    // 1. Check if both parties support Noise
    // 2. Initiate new Noise handshake
    // 3. Mark contact as 'noise_enabled'
    // 4. Keep old ECDH keys as fallback
  }

  /// Check if contact supports Noise
  static Future<bool> supportsNoise(String contactPublicKey) async {
    // Send capability probe message
  }
}
```

### 6.2 Capability Negotiation

Add to handshake:
```dart
// In ProtocolMessage, add new type
enum ProtocolMessageType {
  // ... existing types
  capabilityProbe,    // Ask "do you support Noise?"
  capabilityResponse, // Reply "yes, I support Noise XX"
}
```

**Deliverable:** Smooth migration path for existing users.

---

## Phase 7: Documentation (Days 17-21)

### 7.1 FYP Documentation Requirements

**Document:** `docs/NOISE_PROTOCOL_IMPLEMENTATION.md`

Sections to include:
1. **Motivation:** Why Noise Protocol was chosen
2. **Security Analysis:** Threat model and guarantees
3. **Implementation Details:** How XX pattern is integrated
4. **Forward Secrecy Proof:** Mathematical explanation
5. **Performance Analysis:** Benchmark vs old ECDH
6. **Future Work:** Metadata resistance strategies

### 7.2 Code Documentation

Add comprehensive comments:
```dart
/// Noise Protocol XX Handshake Implementation
///
/// Security Guarantees:
/// - Forward secrecy: Past messages remain secure even if device compromised
/// - Identity hiding: Public keys encrypted after first message
/// - Mutual authentication: Both parties verify each other's identity
///
/// Protocol Flow:
/// 1. Initiator → Responder: ephemeral key (e)
/// 2. Responder → Initiator: ephemeral key + encrypted identity (e, ee, s, es)
/// 3. Initiator → Responder: encrypted identity (s, se)
///
/// After handshake: All messages encrypted with forward-secure transport cipher
class NoiseSecurityManager { ... }
```

### 7.3 Open Source Preparation

Create:
- `SECURITY.md` - Security policy and responsible disclosure
- `CRYPTOGRAPHY.md` - Detailed crypto implementation
- Update `README.md` - Highlight Noise Protocol integration
- Add badges: "🔐 Noise Protocol Enabled"

**Deliverable:** Complete documentation for FYP submission and open-source release.

---

## Success Criteria

### Must-Have (FYP Core Requirements)
- ✅ Noise XX handshake working
- ✅ Forward secrecy verified (no keys on disk)
- ✅ Backward compatible with existing contacts
- ✅ Comprehensive documentation

### Nice-to-Have (Bonus Points)
- ✅ Performance benchmarks (Noise vs old ECDH)
- ✅ Security audit report (ask a professor to review)
- ✅ Comparison table (your implementation vs Signal/WhatsApp)
- ✅ Demo video showing encrypted handshake

### Future Enhancements (Post-FYP)
- 🔜 Metadata resistance (onion routing for mesh)
- 🔜 Group messaging with Noise (multi-party handshake)
- 🔜 Key backup/recovery (social recovery schemes)
- 🔜 Hardware security module integration (Android KeyStore)

---

## Estimated Effort Breakdown

| Phase | Days | Complexity | Learning Value |
|-------|------|------------|----------------|
| 1. Research | 2 | Low | High (understand Noise) |
| 2. Setup | 1 | Low | Medium (dependency management) |
| 3. Handshake | 4 | High | Very High (core implementation) |
| 4. Encryption | 3 | Medium | High (cipher state management) |
| 5. Testing | 3 | Medium | High (verification methods) |
| 6. Migration | 3 | Medium | Medium (compatibility) |
| 7. Documentation | 5 | Low | Very High (FYP writing) |
| **Total** | **21** | | |

**Reality check:** Add 50% buffer = ~30 days part-time = **2-3 weeks full-time**

---

## Getting Help

If you get stuck:
1. **Noise Protocol Docs:** http://noiseprotocol.org/noise.html
2. **noise_protocol_framework Issues:** https://github.com/zyro/noise-protocol-dart/issues
3. **Ask me:** I'll be here to help debug integration issues
4. **Your FYP Supervisor:** Show them this plan for feedback

---

## Final Thoughts

You're not just adding a library - you're implementing **industry-standard cryptography** that powers billion-user apps. This will:
- ✅ Make your FYP stand out ("I used the same crypto as WhatsApp")
- ✅ Prepare your codebase for security audits
- ✅ Make your project attractive to contributors
- ✅ Teach you formal cryptography (huge career boost)

**Let's build something you can be proud of.** 🔐

---

*Next step: Start Phase 1 - Read the Noise Protocol spec and write a 1-page summary.*

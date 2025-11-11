# Identity & Encryption Architecture Investigation Report

**Date**: 2025-01-09
**Purpose**: Document actual implementation vs intended design
**Status**: INVESTIGATION ONLY - No changes made

---

## Executive Summary

This document traces the complete identity and encryption system as implemented in the codebase. It provides evidence-based findings without recommendations, allowing informed architectural decisions.

**Key Question**: Does the implementation match the intended "masquerade party" design with LOW/MEDIUM/HIGH security levels?

---

## Part 1: Identity Model - What's Actually Stored

### Contact Model Definition

**File**: `lib/data/repositories/contact_repository.dart:20-50`

```dart
class Contact {
  final String publicKey;           // Line 21-22
  final String? persistentPublicKey; // Line 23-24
  final String? currentEphemeralId;  // Line 25-26
  final String? noisePublicKey;      // Line 36-37
  // ... other fields
}
```

**Database Schema** (`lib/data/database/database_helper.dart`):
```sql
CREATE TABLE contacts (
  public_key TEXT PRIMARY KEY,
  persistent_public_key TEXT,
  current_ephemeral_id TEXT,
  noise_public_key TEXT,
  -- other fields
);
```

### How Fields Get Populated

#### 1. Initial Handshake (Phase 1 - Identity Exchange)

**File**: `lib/core/bluetooth/handshake_coordinator.dart:300-303`
```dart
final message = ProtocolMessage.identity(
  publicKey: _myEphemeralId, // ← Ephemeral ID sent
  displayName: _myDisplayName,
);
```

**Comment at line 298-299:**
```dart
// SECURITY: Send ephemeral ID, NOT persistent public key
// Persistent keys are only exchanged AFTER pairing succeeds
```

**Evidence**: Only ephemeral IDs are exchanged during initial handshake.

#### 2. After Handshake Complete

**File**: `lib/data/services/ble_service.dart:2631-2668`
```dart
Future<void> _onHandshakeComplete(
  String ephemeralId,
  String displayName,
  String? noisePublicKey,  // ← From Noise protocol
) async {
  // Line 2668: Save contact
  await _stateManager.saveContact(ephemeralId, displayName);
```

**What gets called**: `lib/data/repositories/contact_repository.dart:187-217`
```dart
Future<void> saveContact(String publicKey, String displayName) async {
  // Line 192-199
  final contact = Contact(
    publicKey: publicKey,  // ← ephemeralId stored here!
    displayName: displayName,
    trustStatus: TrustStatus.newContact,
    securityLevel: SecurityLevel.low,
    // persistentPublicKey: null (not set)
  );
}
```

**Evidence**: `Contact.publicKey` is populated with ephemeral ID at LOW security.

#### 3. Noise Protocol Integration

**File**: `lib/data/services/ble_service.dart:2648-2656`
```dart
// 🔧 FIX: Store Noise session public key as persistent key
if (noisePublicKey != null) {
  _logger.info('🔐 Storing peer Noise public key as persistent key');
  await _stateManager.handlePersistentKeyExchange(noisePublicKey);
}
```

**File**: `lib/data/services/ble_state_manager.dart:888-910`
```dart
Future<void> handlePersistentKeyExchange(String theirPersistentKey) async {
  // Line 905-910
  await _contactRepository.saveContactWithSecurity(
    _theirEphemeralId!,  // publicKey = ephemeral ID
    _otherUserName ?? 'User',
    SecurityLevel.low,
    currentEphemeralId: _theirEphemeralId,
    persistentPublicKey: null,  // ← Still NULL at LOW!
  );
```

**Log output at line 918-925:**
```dart
_logger.info('🔑📊 My Keys:    Ephemeral=$myEphId | Persistent=${myPersistentKey}');
_logger.info('🔑📊 Their Keys: Ephemeral=$_theirEphemeralId | Persistent=${theirPersistentKey}');
_logger.info('🔑📊 Security:   LOW (Noise session only - not paired yet)');
```

**Evidence**: At LOW security, Noise public key is received but `Contact.persistentPublicKey` remains NULL.

---

## Part 2: Security Levels - What Actually Happens

### LOW Security (Strangers)

**File**: `lib/core/services/security_manager.dart:244-255`
```dart
low:
case SecurityLevel.low:
  // 🔧 FIX: Check for active Noise session
  if (_noiseService != null &&
      _noiseService!.hasEstablishedSession(sessionLookupKey)) {
    return EncryptionMethod.noise(sessionLookupKey);
  }
  // Only use global if NO Noise session
  _logger.warning('🔒 FALLBACK: No Noise session at LOW level, using global');
  return EncryptionMethod.global();
```

**Evidence**: LOW security uses Noise encryption if session exists, else global AES.

### MEDIUM Security (PIN Pairing)

**File**: `lib/data/services/ble_state_manager.dart:516-568`

**Step 1 - Compute Shared Secret (Line 516-523):**
```dart
// Now compute shared secret (both devices will get same result)
final sortedCodes = [_currentPairing!.myCode, _receivedPairingCode!]..sort();
final sortedKeys = [myPublicKey, theirPublicKey]..sort();

final combinedData = '${sortedCodes[0]}:${sortedCodes[1]}:${sortedKeys[0]}:${sortedKeys[1]}';
final sharedSecret = sha256.convert(utf8.encode(combinedData)).toString();
```

**Step 2 - Initialize Crypto (Line 551):**
```dart
SimpleCrypto.initializeConversation(theirPublicKey, sharedSecret);
```

**Step 3 - Upgrade Contact (Line 562-568):**
```dart
await _contactRepository.saveContactWithSecurity(
  contact.publicKey,  // Same immutable publicKey (ephemeral ID)
  contact.displayName,
  SecurityLevel.medium,  // Upgraded!
  currentEphemeralId: contact.currentEphemeralId,
  persistentPublicKey: _theirPersistentKey!,  // NOW set
);
```

**What `_theirPersistentKey` contains**: The Noise static public key from handshake (stored at line 898 in `handlePersistentKeyExchange`).

**Evidence**: MEDIUM security stores Noise public key in `persistentPublicKey` field and uses PIN-derived shared secret for encryption.

**Encryption Method** (`lib/core/services/security_manager.dart:227-242`):
```dart
medium:
case SecurityLevel.medium:
  // ✅ CORRECT ORDER: Pairing first (persistent trust)
  if (_verifyPairingKey(publicKey)) {
    return EncryptionMethod.pairing(publicKey);
  }
  // Noise is fallback (for spy mode or when pairing not available)
  if (_noiseService != null &&
      _noiseService!.hasEstablishedSession(sessionLookupKey)) {
    return EncryptionMethod.noise(sessionLookupKey);
  }
```

**Evidence**: MEDIUM security prefers pairing encryption (PIN-based), falls back to Noise.

### HIGH Security (Mutual Contacts)

**File**: `lib/data/services/ble_state_manager.dart:1272-1276`
```dart
} else if (weHaveThem && theyHaveUs) {
  _logger.info('📱 MUTUAL: Both have each other - perfect!');

  // Ensure both sides have ECDH keys
  await _ensureMutualECDH(theirPublicKey);
```

**File**: `lib/data/services/ble_state_manager.dart:1288-1320`
```dart
Future<void> _ensureMutualECDH(String theirPublicKey) async {
  try {
    // Check if we have ECDH secret
    final existingSecret = await _contactRepository.getCachedSharedSecret(theirPublicKey);

    if (existingSecret == null) {
      // Compute and cache ECDH
      final sharedSecret = SimpleCrypto.computeSharedSecret(theirPublicKey);
      if (sharedSecret != null) {
        await _contactRepository.cacheSharedSecret(theirPublicKey, sharedSecret);
        await SimpleCrypto.restoreConversationKey(theirPublicKey, sharedSecret);
        _logger.info('📱 ECDH secret computed for mutual contact');
      }
    }

    // Upgrade security level if needed
    final currentLevel = await _contactRepository.getContactSecurityLevel(theirPublicKey);
    if (currentLevel != SecurityLevel.high) {
      await _contactRepository.updateContactSecurityLevel(
        theirPublicKey,
        SecurityLevel.high,
      );
      _logger.info('📱 Upgraded to high security for mutual contact');
    }
  }
}
```

**ECDH Computation** (`lib/core/services/simple_crypto.dart:262-284`):
```dart
static String? computeSharedSecret(String theirPublicKeyHex) {
  if (_privateKey == null) {
    print('Cannot compute shared secret - no private key');
    return null;
  }

  try {
    // Parse their public key
    final theirPublicKeyBytes = _hexToBytes(theirPublicKeyHex);
    final curve = ECCurve_secp256r1();
    final theirPoint = curve.curve.decodePoint(theirPublicKeyBytes);
    final theirPublicKey = ECPublicKey(theirPoint, curve);

    // ECDH computation: myPrivateKey * theirPublicKey
    final sharedPoint = theirPublicKey.Q! * _privateKey!.d!;
    final sharedSecret = sharedPoint!.x!.toBigInteger()!.toRadixString(16);

    return sharedSecret;
  } catch (e) {
    print('🔴 ECDH computation failed: $e');
    return null;
  }
}
```

**Evidence**: TRUE Elliptic Curve Diffie-Hellman math is performed.

**Encryption Method** (`lib/core/services/security_manager.dart:219-225`):
```dart
case SecurityLevel.high:
  if (await _verifyECDHKey(publicKey, repo)) {
    return EncryptionMethod.ecdh(publicKey);
  }
  _logger.warning('🔒 FALLBACK: ECDH failed, falling back to noise');
  await _downgrade(publicKey, SecurityLevel.medium, repo);
  continue medium;
```

**Evidence**: HIGH security uses ECDH encryption if available, else downgrades to MEDIUM.

---

## Part 3: Encryption Paths - What Actually Executes

### Path 1: Global AES (Fallback)

**File**: `lib/core/services/simple_crypto.dart:28-46`
```dart
static void initialize() {
  const String globalPassphrase = "PakConnect2024_SecureBase_v1";
  // ... derives key from hardcoded passphrase
  _encrypter = Encrypter(AES(key));
}
```

**Used when**: No Noise session, no pairing, no ECDH (shouldn't happen post-handshake).

### Path 2: Noise Protocol (LOW Security)

**File**: `lib/core/services/security_manager.dart:281-295`
```dart
case EncryptionType.noise:
  if (_noiseService == null) {
    throw Exception('Noise service not initialized');
  }
  final messageBytes = utf8.encode(message);
  final encrypted = await _noiseService!.encrypt(
    Uint8List.fromList(messageBytes),
    publicKey,
  );
```

**Used when**: SecurityLevel.low OR fallback from higher levels.

### Path 3: Pairing (MEDIUM Security)

**File**: `lib/core/services/security_manager.dart:297-303`
```dart
case EncryptionType.pairing:
  final encrypted = SimpleCrypto.encryptForConversation(
    message,
    publicKey,
  );
  _logger.info('🔒 ENCRYPT: PAIRING → ${message.length} chars');
  return encrypted;
```

**What `encryptForConversation` uses** (`lib/core/services/simple_crypto.dart:102-112`):
```dart
static String encryptForConversation(String plaintext, String publicKey) {
  final encrypter = _conversationEncrypters[publicKey];
  final iv = _conversationIVs[publicKey];
  // ... uses AES with key derived from PIN-based sharedSecret
}
```

**Key derivation** (`lib/core/services/simple_crypto.dart:78-92`):
```dart
static void initializeConversation(String publicKey, String sharedSecret) {
  final keyBytes = sha256.convert(utf8.encode('${sharedSecret}CONVERSATION_KEY')).bytes;
  final key = Key(Uint8List.fromList(keyBytes));
  // ... sharedSecret = SHA256(PIN1:PIN2:ECDHPubKey1:ECDHPubKey2)
}
```

**Evidence**: Pairing uses AES with key derived from sorted PINs + public keys.

### Path 4: ECDH (HIGH Security)

**File**: `lib/core/services/security_manager.dart:269-279`
```dart
case EncryptionType.ecdh:
  final encrypted = await SimpleCrypto.encryptForContact(
    message,
    publicKey,
    repo,
  );
  if (encrypted != null) {
    _logger.info('🔒 ENCRYPT: ECDH → ${message.length} chars');
    return encrypted;
  }
```

**What `encryptForContact` does** (`lib/core/services/simple_crypto.dart:286-357`):
```dart
static Future<String?> encryptForContact(
  String plaintext,
  String contactPublicKey,
  ContactRepository contactRepo,
) async {
  // Get cached or compute shared secret
  final sharedSecret = await getCachedOrComputeSharedSecret(contactPublicKey, contactRepo);

  // Enhanced key derivation
  final enhancedSecret = _deriveEnhancedContactKey(sharedSecret, contactPublicKey);

  // AES encryption with ECDH-derived key
  final keyBytes = sha256.convert(utf8.encode(enhancedSecret)).bytes;
  final key = Key(Uint8List.fromList(keyBytes));
  // ... encrypt with AES
}
```

**Evidence**: ECDH encryption uses AES with key derived from true ECDH shared secret.

---

## Part 4: Key Storage Locations

### My Keys (Self)

**File**: `lib/data/repositories/user_preferences.dart:96-116`
```dart
Future<String> getPublicKey() async {
  final storage = FlutterSecureStorage();
  final publicKey = await storage.read(key: _publicKeyKey);
  return publicKey ?? '';
}

Future<String> getPrivateKey() async {
  final storage = FlutterSecureStorage();
  final privateKey = await storage.read(key: _privateKeyKey);
  return privateKey ?? '';
}
```

**Key generation** (`lib/data/repositories/user_preferences.dart:124-171`):
```dart
Future<Map<String, String>> _generateNewKeyPair() async {
  // ... ECDH key pair generation using EC_secp256r1
  final keyPair = keyGen.generateKeyPair();
  final privateKey = keyPair.privateKey as ECPrivateKey;
  final publicKey = keyPair.publicKey as ECPublicKey;
  // ... stored in FlutterSecureStorage
}
```

**Evidence**: User's ECDH key pair is generated once and stored in FlutterSecureStorage.

### Their Keys (Contacts)

| Key Type | Storage Location | Access Pattern |
|----------|------------------|----------------|
| Ephemeral ID (current) | `Contact.currentEphemeralId` | O(1) SQLite query |
| Ephemeral ID (first) | `Contact.publicKey` | O(1) SQLite query (primary key) |
| Noise Static Key | `Contact.persistentPublicKey` | O(1) SQLite query |
| ECDH Public Key | **FlutterSecureStorage** (cached shared secret) | O(n) storage lookup |

**Evidence**: ECDH public keys are NOT stored in Contact model, only the computed shared secret is cached.

---

## Part 5: What "Triple DH" Might Mean

### Searching for Triple DH References

**Command**: `grep -rn "triple\|Triple\|3DH\|XXfallback" lib/`

**No explicit "Triple DH" implementation found.**

### Possible Interpretations

#### Interpretation 1: "Triple" = Three Key Derivation Inputs
In pairing encryption, the key uses:
1. PIN codes (user input)
2. Public keys (ECDH keys as entropy)
3. Global salt (hardcoded)

**File**: `lib/data/services/ble_state_manager.dart:517-523`
```dart
final sortedCodes = [_currentPairing!.myCode, _receivedPairingCode!]..sort();
final sortedKeys = [myPublicKey, theirPublicKey]..sort();
final combinedData = '${sortedCodes[0]}:${sortedCodes[1]}:${sortedKeys[0]}:${sortedKeys[1]}';
final sharedSecret = sha256.convert(utf8.encode(combinedData)).toString();
```

**Evidence**: Three types of entropy, but not cryptographic Triple DH.

#### Interpretation 2: "Triple" = Noise Protocol Triple DH
Noise XX pattern performs three DH operations during handshake:
1. `e, e` - ephemeral to ephemeral
2. `s, e` - static to ephemeral
3. `e, s` - ephemeral to static

**File**: `lib/core/security/noise/noise_patterns.dart` (if exists)

**Search result**: Need to check Noise implementation details.

#### Interpretation 3: "Triple" = Three Encryption Layers
Enhanced ECDH derivation combines:
1. ECDH shared secret
2. Pairing key (if available)
3. Global passphrase

**File**: `lib/core/services/simple_crypto.dart:418-458`
```dart
static String _deriveEnhancedContactKey(
  String baseSecret,
  String contactPublicKey,
) {
  final pairingKey = _getPairingKeyForContact(contactPublicKey);

  if (pairingKey != null) {
    // Layer 1: ECDH shared secret
    // Layer 2: Pairing-based secret
    // Layer 3: Global passphrase
    return sha256.convert(
      utf8.encode('$baseSecret:$pairingKey:ENHANCED_V2'),
    ).toString();
  } else {
    // Just ECDH + global
    return sha256.convert(
      utf8.encode('$baseSecret:STANDARD_V2'),
    ).toString();
  }
}
```

**Evidence**: Enhanced mode uses multiple key derivation layers.

---

## Part 6: Naming Confusion Matrix

### What Fields Are Called vs. What They Contain

| Field Name | Implies | Actually Contains | Set When |
|------------|---------|-------------------|----------|
| `Contact.publicKey` | Cryptographic public key | First ephemeral ID | Initial handshake |
| `Contact.persistentPublicKey` | Persistent identity key | Noise static public key | After handshake (LOW→MEDIUM) |
| `Contact.currentEphemeralId` | Current session ID | Current ephemeral ID | Every reconnection |
| `Contact.noisePublicKey` | Noise protocol key | Base64 Noise static key | After Noise handshake |

### My ECDH Keys

**File**: `lib/data/services/ble_state_manager.dart:237-239`
```dart
Future<String> getMyPersistentId() async {
  return await _userPreferences.getPublicKey();
}
```

**Evidence**: "PersistentId" actually returns ECDH public key from UserPreferences.

### Their ECDH Keys

**NOT stored in Contact model.**

**Stored as**: Computed shared secret in FlutterSecureStorage via `ContactRepository.cacheSharedSecret()`.

**File**: `lib/data/repositories/contact_repository.dart` (need to check cacheSharedSecret implementation).

---

## Part 7: Unanswered Questions

### Question 1: Where is "MEDIUM+" defined?

**Search result**: No explicit `SecurityLevel.mediumPlus` enum value exists.

**Possible meaning**: MEDIUM security with enhanced features?

### Question 2: What exactly is "Triple DH"?

**Possibilities**:
1. Noise Protocol XX pattern (3 DH operations)
2. Three-layer key derivation (ECDH + Pairing + Global)
3. Not implemented yet (planned feature)

**Evidence needed**: Design documents or comments explaining "Triple DH".

### Question 3: Why are ECDH public keys not stored in Contact?

**Current pattern**: Only shared secrets are cached.

**Possible reasons**:
1. Security (avoid storing public keys in DB)
2. Performance (caching shared secret is more useful)
3. Legacy design
4. Intended to be added later

### Question 4: What should `Contact.persistentPublicKey` actually store?

**Current**: Noise static public key
**Intended**: ECDH public key? Noise key? Both?

**Evidence needed**: Original design intent.

---

## Part 8: Code Evidence Summary

### Security Level Transitions

```
LOW (Strangers):
  Contact.publicKey = ephemeralId
  Contact.persistentPublicKey = NULL
  Contact.currentEphemeralId = ephemeralId
  Encryption: Noise Protocol

↓ (PIN Pairing)

MEDIUM (Paired):
  Contact.publicKey = ephemeralId (unchanged)
  Contact.persistentPublicKey = noiseStaticKey (NOW SET)
  Contact.currentEphemeralId = ephemeralId
  Encryption: PIN-based AES → Noise fallback

↓ (Mutual Contact)

HIGH (Friends):
  Contact.publicKey = ephemeralId (unchanged)
  Contact.persistentPublicKey = noiseStaticKey (unchanged)
  Contact.currentEphemeralId = ephemeralId
  Encryption: ECDH AES → Pairing fallback → Noise fallback
  Note: ECDH public key NOT in Contact, only cached shared secret
```

### Encryption Priority Order

**File**: `lib/core/services/security_manager.dart:208-257`

```
SecurityLevel.high:
  1. Try ECDH (if shared secret exists)
  2. Downgrade to MEDIUM

SecurityLevel.medium:
  1. Try Pairing (if conversation key exists)
  2. Try Noise (if session exists)
  3. Downgrade to LOW

SecurityLevel.low:
  1. Try Noise (if session exists)
  2. Use Global AES
```

---

## Part 9: Database Schema

**File**: `lib/data/database/database_helper.dart` (version 9)

```sql
CREATE TABLE contacts (
  public_key TEXT PRIMARY KEY,              -- Actually: first ephemeral ID
  persistent_public_key TEXT,               -- Actually: Noise static key (NULL at LOW)
  current_ephemeral_id TEXT,                -- Correct: current session ephemeral
  display_name TEXT NOT NULL,
  trust_status INTEGER NOT NULL,
  security_level INTEGER NOT NULL,          -- 0=LOW, 1=MEDIUM, 2=HIGH
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  last_security_sync INTEGER,
  noise_public_key TEXT,                    -- Base64 Noise static key
  noise_session_state TEXT,
  last_handshake_time INTEGER,
  is_favorite INTEGER DEFAULT 0,
  created_at INTEGER,
  updated_at INTEGER
);

CREATE INDEX idx_persistent_public_key ON contacts(persistent_public_key);
CREATE INDEX idx_current_ephemeral_id ON contacts(current_ephemeral_id);
```

**Evidence**: Two fields for "public keys" (public_key, persistent_public_key) plus noise_public_key.

---

## Part 10: What Needs Clarification

### From User

1. **MEDIUM+ Definition**: What is this security level? Not found in code.
2. **Triple DH Meaning**: Noise XX, Enhanced derivation, or something else?
3. **Intended Design**:
   - Should `Contact.persistentPublicKey` store ECDH or Noise key?
   - Should ECDH public keys be in Contact model?
   - Is enhanced derivation the "triple" layer?

### Design Intent vs Implementation

| Aspect | User Says | Code Shows |
|--------|-----------|------------|
| LOW | Noise only | ✅ Matches (Noise or Global fallback) |
| MEDIUM | Pairing + shared ECDH key | ⚠️ Partial (Pairing uses ECDH keys as entropy, not true ECDH crypto) |
| MEDIUM+ | Triple DH | ❓ Not found as explicit level |
| HIGH | ? | ECDH encryption (true EC math) |

---

## Part 11: Questions for Architectural Decision

1. **What is MEDIUM+ security?** Is it:
   - Enhanced MEDIUM (pairing + Noise + enhanced derivation)?
   - Same as HIGH?
   - A fourth security level?

2. **What is "Triple DH"?** Is it:
   - Noise Protocol's triple DH (XX pattern)?
   - Three-layer key derivation (ECDH + Pairing + Global)?
   - Three separate DH operations?

3. **Should ECDH public keys be stored in Contact?**
   - Pro: O(1) access, matches field name
   - Con: Security concern, current caching works

4. **What should field names be?**
   - `publicKey` → ? (currently stores ephemeral)
   - `persistentPublicKey` → ? (currently stores Noise key)
   - Add `ecdhPublicKey` field?

5. **Is the current implementation correct?**
   - Or does it deviate from original design?
   - Should we align naming or align implementation?

---

## Appendix A: File References

### Identity Management
- `lib/data/repositories/contact_repository.dart:20-50` - Contact model
- `lib/data/services/ble_state_manager.dart:888-943` - Persistent key exchange
- `lib/core/bluetooth/handshake_coordinator.dart:289-347` - Identity exchange

### Encryption Paths
- `lib/core/services/security_manager.dart:208-319` - Encryption method selection
- `lib/core/services/simple_crypto.dart:262-357` - ECDH encryption
- `lib/core/services/simple_crypto.dart:78-92` - Pairing encryption
- `lib/core/security/noise/` - Noise protocol implementation

### Security Level Upgrades
- `lib/data/services/ble_state_manager.dart:516-584` - MEDIUM pairing
- `lib/data/services/ble_state_manager.dart:1272-1328` - HIGH mutual ECDH

### Key Storage
- `lib/data/repositories/user_preferences.dart:96-171` - ECDH key pair
- `lib/data/repositories/contact_repository.dart` - Shared secret caching

---

## Appendix B: Security Level Truth Table

| Level | Noise Session | Pairing Key | ECDH Shared Secret | Encryption Used |
|-------|---------------|-------------|-------------------|-----------------|
| LOW | ✅ | ❌ | ❌ | Noise |
| MEDIUM | ✅ | ✅ | ⚠️ (as entropy only) | Pairing (PIN-based AES) |
| HIGH | ✅ | ✅ | ✅ (as crypto) | ECDH (true EC math) |

**Note**: All levels maintain Noise session. Higher levels add encryption layers.

---

## Conclusion

This investigation documents the implemented system without making architectural recommendations. The evidence shows:

1. ✅ **LOW = Noise encryption** - Confirmed
2. ⚠️ **MEDIUM = Pairing** - Confirmed, but ECDH keys used as entropy (not crypto)
3. ❓ **MEDIUM+ = Triple DH** - Not found in code
4. ✅ **HIGH = ECDH encryption** - Confirmed (true EC math)

**Next Steps**: Clarify intended design for MEDIUM+ and Triple DH before making any changes.

---

**Generated**: 2025-01-09
**By**: Claude Code Investigation
**Status**: Evidence-based, no changes made

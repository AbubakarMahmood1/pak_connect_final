# Noise Protocol Integration

## Three-Layer Security Architecture

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

## Security Levels

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

## Contact Identity Model

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

## Key Service Classes

### SecurityManager (Noise Lifecycle)

**Location**: `lib/core/services/security_manager.dart`

**Responsibilities**: Noise session creation, security level upgrades, key management.

**Key Methods**:
- `initializeNoiseSession(contactKey)`: Create Noise session
- `upgradeContactSecurity(contactKey, level)`: Upgrade to MEDIUM/HIGH
- `verifyContact(contactKey, pin)`: PIN-based verification

## Session Invariants

1. **Noise session MUST complete handshake before encryption** (state == established)
2. **Nonces MUST be sequential** (gaps trigger replay protection)
3. **Sessions MUST rekey after 10k messages or 1 hour** (forward secrecy)
4. **Thread safety**: Noise operations MUST be serialized per session

## 1. Overview
PakConnect is a Flutter/Dart application for off-grid peer-to-peer messaging over BLE mesh networks. It has no centralized server; every device is a node that can advertise, connect, relay, and store messages. Messages can be delivered directly or via store-and-forward hops. Key security assets include:

- Message confidentiality and integrity for text and binary payloads.
- Static identity keys, Noise session keys, and ephemeral identifiers.
- Contact trust state (paired/verified) and verification artifacts.
- Local message history, archives, and contact metadata stored on-device.
- Export/import bundles that contain encrypted database snapshots and keys.
- Mesh metadata (TTL, hop counts, relay decisions) that can reveal network topology.

Security-sensitive components are concentrated in `lib/core/security/` (Noise, sealed encryption, SecureKey), `lib/core/services/security_manager.dart`, `lib/domain/services/` (ephemeral IDs, signing, encryption utilities), and `lib/data/services/` (handshake, protocol parsing, fragmentation, relay handling). The app uses Noise XX/KK with X25519 + ChaCha20-Poly1305 (`lib/core/security/noise/*`), SQLCipher for on-device encryption (`lib/data/database/*`), export/import encryption with PBKDF2 + AES-256-GCM and HMAC (`lib/domain/services/encryption_utils.dart`), and spam/DoS controls for relay traffic (`lib/domain/services/spam_prevention_manager.dart`, `lib/core/services/queue_policy_manager.dart`).

## 2. Threat model, Trust boundaries and assumptions
### Trust boundaries
- **BLE transport & mesh peers**: All advertisements, GATT writes, handshake frames, protocol messages, relay metadata, and fragments are attacker-controlled.
- **Local filesystem**: Export bundles and backups are user-selected files; imports must be treated as untrusted input.
- **OS secure storage**: `FlutterSecureStorage` is trusted to protect static identity keys and SQLCipher keys; compromise of the device or keychain breaks confidentiality.
- **Local database**: SQLCipher is used on Android/iOS; desktop/test builds may be plaintext and should not be treated as secure.
- **Build-time configuration**: `PAKCONNECT_REQUIRE_V2_SIGNATURE=false` can relax v2 signature enforcement, and `PAKCONNECT_ENFORCE_V2_DOWNGRADE_GUARD=false` can disable the per-peer protocol floor. There is no active legacy-decryption build flag.

### Attacker-controlled inputs
- BLE handshake messages, Noise frames, protocol envelopes, relay metadata, and message fragments.
- Sender-supplied display names, message content, and binary payloads.
- Export bundle contents and file paths chosen for import.
- Connection churn, timing, and RSSI patterns used for tracking or DoS.

### Operator-controlled inputs
- Passphrases for export/import and local privacy settings (spy mode, hint broadcast).
- Device security settings that gate secure storage (lock screen, biometrics).
- Local user preferences that influence relay queue behavior or power modes.

### Developer-controlled inputs
- Build-time flags for signature enforcement and the protocol downgrade guard.
- Test fixtures, mocks, and debug logging overrides.
- Desktop/test configuration that disables SQLCipher encryption.

### Assumptions
- Cryptographic libraries (Noise, SQLCipher, pinenacl, cryptography, pointycastle) are correct.
- Users can perform out-of-band verification when higher trust is required (pairing/verification).
- Secure storage is available and uncompromised on mobile platforms.
- Desktop/test builds are not used for sensitive production data.

## 3. Attack surface, mitigations and attacker stories
### 3.1 BLE handshake, identity establishment, and key management
**Surface**: `lib/data/services/ble_handshake_service.dart`, `lib/core/security/noise/*`, `lib/core/services/security_manager.dart`, `lib/domain/services/ephemeral_key_manager.dart`.

**Threats**: MITM/identity confusion during an unverified first contact, identity spoofing with ephemeral IDs, replay of handshake frames, protocol downgrade attempts, or abusive handshake flooding.

**Mitigations**:
- Noise XX/KK handshake with static identity keys stored in secure storage (`NoiseEncryptionService`).
- Session mapping from persistent ↔ ephemeral IDs (`NoiseSessionManager`, `SecurityManager.registerIdentityMapping`).
- Secure key zeroing to reduce in-memory leakage (`SecureKey`).
- Pairing/PIN flow upgrades trust for verified contacts (`pairing_service.dart`).
- Protocol downgrade guard to reject legacy messages after observing v2+ (`peer_protocol_version_guard.dart`).

**Attacker stories**:
- A nearby attacker proxies BLE traffic to perform MITM before pairing completes. Without user verification, the first session is vulnerable to identity confusion; pairing is required to harden trust.
- An attacker replays old handshake frames or floods handshakes to exhaust resources. The handshake coordinator and connection limits reduce, but do not eliminate, DoS risk.

### 3.2 Protocol parsing, encryption metadata, and signatures
**Surface**: `lib/domain/models/protocol_message.dart`, `lib/domain/models/crypto_header.dart`, `lib/data/services/protocol_message_handler.dart`, `lib/data/services/inbound_text_processor.dart`, and the signing/conversation crypto services. `simple_crypto.dart` is a compatibility alias, not a separate legacy decrypt lane.

**Threats**: Crafted payloads that bypass signature checks, malformed compressed frames causing memory spikes, or downgrade to legacy formats to avoid encryption.

**Mitigations**:
- Canonical signing of v2+ messages and explicit signature verification (`SigningManager`).
- Default requirement for v2 signatures; a build can explicitly relax it only with `PAKCONNECT_REQUIRE_V2_SIGNATURE=false` (`ProtocolMessageHandler`, `InboundTextProcessor`).
- A per-peer protocol floor rejects v1 frames after that peer has been observed using v2+, unless the downgrade guard is explicitly disabled (`PeerProtocolVersionGuard`).
- The `SimpleCrypto` name remains only as a compatibility facade over the active signing, contact, and conversation crypto services; its old legacy wrapper/decrypt lane is removed.
- Crypto metadata embedded in message envelopes (`CryptoHeader`) and fail-closed encryption on send (`SecurityManager`).

**Attacker stories**:
- A new or not-yet-upgraded peer can still send migration-compatible v1 frames. After a stable peer identity is observed at v2+, later v1 frames for that identity are rejected by default. A build with signature enforcement or the downgrade guard disabled weakens this boundary.
- A crafted compressed payload attempts to trigger decompression overhead. The protocol parser handles errors gracefully, but compression ratio limits are not globally enforced, so large payloads remain a DoS vector.

### 3.3 Mesh relay, fragmentation, and DoS resistance
**Surface**: `lib/domain/services/spam_prevention_manager.dart`, `lib/data/services/message_fragmentation_handler.dart`, `lib/domain/services/mesh/mesh_relay_coordinator.dart`, `lib/data/services/mesh_relay_handler.dart`, `lib/core/services/queue_policy_manager.dart`, `lib/data/services/connection_limit_enforcer.dart`.

**Threats**: Relay flooding, fragment bombs, TTL loops, queue exhaustion, and battery drain. Since every node can relay, untrusted peers can generate high traffic.

**Mitigations**:
- Multi-layer spam prevention with rate limits, hop-count validation, size caps, duplicate detection, and optional proof-of-work (`SpamPreventionManager`).
- Fragment reassembly timeouts and deduplication to drop stale/duplicate chunks (`MessageFragmentationHandler`).
- Per-peer queue limits and priority policy (`QueuePolicyManager`).
- Connection limit enforcement and RSSI gating (`ConnectionLimitEnforcer`).

**Attacker stories**:
- A hostile relay injects thousands of fragments with unique IDs to consume memory. Timeouts and cleanup reduce persistence, but a nearby attacker can still cause temporary disruption.
- Attackers craft high TTL or looping relay metadata to amplify traffic; hop count validation and duplicate detection mitigate but cannot prevent all traffic analysis or battery drain.

### 3.4 Data at rest and secret storage
**Surface**: `lib/data/database/database_helper.dart`, `lib/data/database/database_encryption.dart`, `lib/core/security/secure_key.dart`, `lib/core/security/noise/noise_encryption_service.dart`.

**Threats**: Extraction of SQLCipher keys, static identity keys, or session material from a compromised device; plaintext storage on non-mobile platforms; sensitive data in logs.

**Mitigations**:
- SQLCipher encryption with keys stored in OS keychain; fail-closed if secure storage is unavailable (`DatabaseEncryption`).
- SecureKey zeroing of key material in memory (`SecureKey`, `NoiseSessionManager`).
- Ephemeral signing keys remain in memory only; old persisted private keys are scrubbed (`EphemeralKeyManager`).
- Explicit logging redaction and truncated identifiers in many logs.

**Attacker stories**:
- If a device is rooted or keychain access is compromised, encrypted databases and keys can be extracted; this is a high-impact but device-compromise-dependent threat.
- Desktop/test builds store plaintext databases and should not be used for sensitive communications.

### 3.5 Export/import and backup bundles
**Surface**: `lib/data/services/export_import/export_service.dart`, `lib/data/services/export_import/import_service.dart`, `lib/domain/services/encryption_utils.dart`.

**Threats**: Tampered bundles, weak passphrase brute force, malicious import files leading to corrupted state, or social engineering to import attacker-crafted data.

**Mitigations**:
- PBKDF2 (600k iterations) + AES-256-GCM encryption and HMAC integrity checks (`EncryptionUtils`).
- Passphrase strength validation and warnings; rate-limited import attempts (`ImportService`).
- Explicit version checks and integrity validation before destructive restore.

**Attacker stories**:
- An attacker sends a crafted `.pakconnect` file. HMAC verification and passphrase checks should reject tampering; however, weak or reused passphrases can still expose full history.

### 3.6 Privacy, metadata, and hint advertising
**Surface**: `lib/domain/services/ephemeral_key_manager.dart`, hint advertisement services, spy mode settings.

**Threats**: Tracking via repeated ephemeral IDs, correlating mesh metadata, and inference of social graph or presence.

**Mitigations**:
- Session-scoped ephemeral IDs and signing keys; rotation on app restart.
- Spy mode disables hint broadcasting and reduces metadata exposure.

**Residual risk**: BLE metadata (timing, signal strength, device presence) remains observable by nearby attackers; store-and-forward reveals traffic patterns even when payloads are encrypted.

### 3.7 UI input and local environment
**Surface**: User display names, message content, binary payloads, file pickers.

**Threats**: UI crashes from oversized inputs, log injection, or local file mishandling. Typical web threats (CSRF, SSRF, XSS) are largely out of scope because the app is not a web server and Flutter widgets do not execute HTML/JS by default.

**Mitigations**:
- Message size limits enforced in relay controls; binary payloads are fragmented and validated.
- Avoids embedded web views for untrusted content.

### 3.8 Build, CI, and debug configuration
**Surface**: Build-time flags, test overrides, and debug logging (`ProtocolMessageHandler`, `InboundTextProcessor`, `PeerProtocolVersionGuard`, `DatabaseEncryption`).

**Threats**: Insecure builds that disable signature/downgrade enforcement, or test overrides that replace secure storage.

**Mitigations**:
- Secure defaults: v2 signatures are required and the per-peer v2 downgrade guard is enabled. No active legacy-decryption flag exists.
- Test-only overrides are gated by `@visibleForTesting` or build flags.

**Attacker story**: A production build shipped with `PAKCONNECT_REQUIRE_V2_SIGNATURE=false` or `PAKCONNECT_ENFORCE_V2_DOWNGRADE_GUARD=false` would weaken message authentication/downgrade resistance even without an attacker controlling runtime inputs.

## 4. Criticality calibration (critical, high, medium, low)
**Critical**
- Compromise of Noise static identity keys or SQLCipher keys from production builds, enabling decryption of stored history or future sessions.
- Ability to impersonate a verified contact or decrypt/modify messages without user detection (e.g., a successful MITM during pairing or signature bypass).
- Remote code execution via crafted BLE payloads (if ever possible) or arbitrary file overwrite during import.

**High**
- Downgrade that allows unsigned/legacy messages to be accepted as trusted (e.g., disabling v2 signature enforcement).
- Acceptance of tampered export/import bundles that bypass integrity checks.
- Persistent DoS that prevents messaging across the mesh for extended periods (resource exhaustion beyond normal rate limits).

**Medium**
- Metadata leakage that enables tracking or social-graph inference without revealing message content.
- Local crashes or partial data corruption triggered by malformed protocol messages or fragments.
- Weak passphrase acceptance for export/import that significantly lowers brute-force cost.

**Low**
- Minor UI issues, log verbosity leaks of truncated identifiers, or non-sensitive preference corruption.
- Issues that only affect test/desktop builds or require developer-controlled build flags.

Vulnerabilities that require attacker control not present in real-world usage (e.g., server-side injection, CSRF, SSRF, multi-tenant bypass) are generally out of scope unless the app is compiled and deployed as a web application.

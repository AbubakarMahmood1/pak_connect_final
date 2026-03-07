Overview

PakConnect is a Flutter mobile application for decentralized off‑grid messaging. It uses BLE mesh networking, a Noise Protocol based end‑to‑end channel (XX/KK), and SQLCipher for local storage. There are no centralized servers; devices act as both clients and relays. Data flows through BLEMessageHandler, ProtocolMessageHandler, and MeshRelayEngine. Security goals are confidentiality and integrity of messages, authentication of peers, privacy of identities/metadata, resilience to spam/flooding, and safe storage/backup of PII. The codebase includes legacy crypto compatibility paths (e.g., SimpleCrypto), plus sealed encryption for offline/store‑and‑forward use.



Threat model, Trust boundaries and assumptions

Assets

Message contents, attachments, and metadata.

Long‑term identity keys (Noise static keys in NoiseEncryptionService, ECDH keys in UserPreferences).

Session keys and replay/nonce state (NoiseSessionManager, MessageSecurity).

Contact list, trust levels, pairing state, and shared secrets (ContactRepository).

Local SQLCipher database and export/import bundles.

Device identifiers and ephemeral IDs (EphemeralKeyManager, IdentityManager).

Trust boundaries \& attacker-controlled inputs

BLE radio boundary: any nearby device can advertise, connect, and send packets. Inputs include handshake data, protocol messages, message fragments, relay metadata, queue sync, and pairing requests (BLEMessageHandler, ProtocolMessageHandler, MessageFragmentationHandler).

Mesh relay boundary: relay nodes are untrusted; they see transport metadata, message sizes, timing, hop counts (MeshRelayEngine, SpamPreventionManager).

Local file/import boundary: user-imported .pakconnect bundles and backups can be attacker-supplied (ImportService/ExportService).

User-generated content: chat messages, display names, search queries, archive filters; these are generally local but can be echoed in UI/DB.

Platform/OS boundary: secure storage and Bluetooth stack are trusted but not hardened against a rooted/jailbroken device.

Operator-controlled inputs

Build-time flags such as PAKCONNECT\_ALLOW\_LEGACY\_V2\_SEND, PAKCONNECT\_ALLOW\_LEGACY\_V2\_DECRYPT, PAKCONNECT\_REQUIRE\_V2\_SIGNATURE, PAKCONNECT\_ENABLE\_SEALED\_V1\_SEND, and PAKCONNECT\_LEGACY\_PASSPHRASE influence crypto policy (SecurityManager, ProtocolMessageHandler, OutboundMessageSender).

Deployment target: SQLCipher encryption is enforced on Android/iOS but not on desktop/test builds (DatabaseHelper).

Platform permissions and signing keys (AndroidManifest.xml, iOS/Info.plist, release signing config).

Developer-controlled inputs

Test fixtures, mock BLE payloads, and CI scripts (test/, integration\_test/, scripts/), not part of production runtime.

Assumptions

Users can verify pairing PINs out-of-band (in-person or trusted channel); pairing is not meant for fully remote trust establishment.

Devices are not rooted/jailbroken; OS secure storage is trusted. If compromised, key exfiltration is possible.

BLE traffic is observable; confidentiality relies on application-layer encryption rather than BLE link security.

Relays are untrusted and may drop or delay messages; confidentiality relies on Noise/Sealed encryption rather than relay trust.

Web/desktop builds are optional and may not provide at-rest encryption; mobile is the intended secure deployment.

Attack surface, mitigations and attacker stories

BLE transport, protocol parsing, and handshake

Attack surface: BLE advertisements, GATT traffic, message fragments, handshake packets, and protocol messages are attacker-controlled. Potential threats include injection, replay, downgrade, malformed payloads, and DoS.



Mitigations \& controls:



Noise Protocol implementation (lib/core/security/noise/, NoiseEncryptionService, NoiseSessionManager) provides authenticated key exchange and per-session AEAD encryption.

Sealed encryption for offline/store‑and‑forward (lib/core/security/sealed/sealed\_encryption\_service.dart) uses X25519 + HKDF + ChaCha20-Poly1305.

Protocol envelope includes explicit crypto mode (CryptoHeader), with deterministic decrypt routing and downgrade guard (PeerProtocolVersionGuard).

Replay protection and nonce tracking (MessageSecurity) plus session rekeying policy in Noise sessions.

Message signing (SigningManager) with ephemeral or persistent keys, plus strict signature enforcement flags.

Handshake coordination logic in lib/core/bluetooth/ and NoiseHandshakeDriver limits protocol ambiguity and supports XX/KK patterns.

Pairing and identity management

Attack surface: pairing requests, PIN codes, and identity mapping.



Mitigations \& controls:



PIN-based pairing (PairingService) requires user confirmation and includes timeouts.

Identity mapping between ephemeral IDs and persistent keys (SecurityManager.registerIdentityMapping, ContactRepository) reduces spoofing after verification.

Ephemeral IDs rotate per session (EphemeralKeyManager), limiting long-term tracking.

Residual risk: 4‑digit PINs are low entropy; brute-force or social engineering could allow MITM if users approve mismatched codes. This is mitigated by user verification and short pairing windows but remains a medium-risk area.



Mesh relay and offline queue

Attack surface: relay metadata, hop counts, TTL, queue sync, and offline store‑and‑forward.



Mitigations \& controls:



Relay policy enforcement and duplicate detection (MeshRelayEngine, SeenMessageStore) avoid loops and redundant traffic.

Spam/rate limiting (SpamPreventionManager) caps relay rates, size, and hop counts.

Offline queue separates direct vs relay traffic and enforces retry limits (OfflineMessageQueue).

Residual risk: A malicious node can still cause local resource exhaustion (storage growth, CPU) or degrade availability by flooding with valid but high-volume traffic.



Local storage, keys, and backups

Attack surface: SQLCipher database, secure storage, export/import bundles.



Mitigations \& controls:



SQLCipher encryption with per-device key stored in OS keystore/keychain (DatabaseEncryption, DatabaseHelper) and fail-closed on key retrieval.

Secure key handling (SecureKey) zeroes key material and limits in-memory exposure.

Export/import uses PBKDF2 (100k iterations) and AES-GCM (EncryptionUtils), with checksum and passphrase validation.

Legacy crypto uses explicit compatibility flags; no hardcoded passphrases in runtime (SimpleCrypto, ArchiveCrypto).

Residual risk: Weak export passphrases enable offline brute-force; desktop/test builds may store plaintext databases. Compromised devices can leak keys and data.



UI, search, and archive features

Attack surface: user input for messages and search; archive operations; FTS queries.



Mitigations \& controls:



SQLite parameterized queries for most DB access (MessageRepository, ArchiveRepository).

Archive data stored within SQLCipher (field-level encryption removed in favor of at-rest encryption).

Search uses FTS queries but is initiated by local user input; no remote attacker control in normal use.

Residual risk: If the web build is deployed, HTML/JS injection could become relevant, but this is out-of-scope for mobile deployments.



Logging, diagnostics, and build tooling

Attack surface: logs and debug flags could leak sensitive information.



Mitigations \& controls:



Security-focused logging policies (no print in runtime code; debug flags gate verbose logs).

CI/security docs highlight crypto policy and regression tests (see docs/security/crypto\_redesign\_roadmap.md).

Residual risk: Misconfigured debug logging or verbose BLE logs could expose metadata or identifiers.



Attacker stories

Nearby adversary injects BLE packets to trigger parser crashes or force downgrade. Mitigated by version guard, explicit crypto modes, and fail‑closed decrypt; remaining risk is availability (DoS).

Malicious relay tries to read messages while forwarding. Noise and sealed encryption keep payloads confidential; relays still see metadata (sender/recipient IDs, timing).

MITM during pairing by imitating a nearby device. User PIN verification is the primary defense; low‑entropy PINs and social engineering remain a concern.

Compromised device or rooted OS extracts secure storage keys and SQLCipher passwords, leading to full compromise; this is outside the assumed threat boundary.

Tampered backup file delivered to a user: import fails without passphrase; AES‑GCM integrity checks prevent silent corruption. Weak passphrases enable offline guessing.

Downgrade attack using legacy crypto modes if compatibility flags remain enabled. PeerProtocolVersionGuard and strict flags mitigate, but operator misconfiguration could re‑enable weaker paths.

Mesh flooding with valid messages to exhaust storage or battery. SpamPreventionManager limits but cannot fully prevent availability attacks.

Criticality calibration (critical, high, medium, low)

Critical



Remote attacker can decrypt or forge messages without device compromise (e.g., Noise session key extraction, signature bypass in ProtocolMessageHandler).

Arbitrary code execution from BLE payload parsing or database import.

Exposure of SQLCipher or Noise private keys through logging or insecure storage in production.

High



MITM pairing that results in persistent identity compromise (e.g., PIN verification bypass in PairingService).

Downgrade to legacy/unencrypted modes for v2 peers despite policy flags.

Unauthorized read/write of encrypted database on mobile (e.g., SQLCipher key retrieval bypass).

Medium



Denial-of-service via mesh flooding, large fragments, or replay to exhaust queue/storage.

Offline brute-force of export bundles due to weak passphrases.

Metadata/privacy leakage through persistent identifiers or unrotated ephemeral IDs.

Low



Information leaks in debug logs or analytics without direct key exposure.

Issues limited to desktop/test builds where plaintext storage is expected.

Minor UI-level issues (search query parsing quirks) that do not affect confidentiality or integrity.


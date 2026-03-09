Overview

PakConnect is a Flutter application that provides offline, peer-to-peer messaging over BLE mesh networks. It relies on the Noise Protocol (XX/KK) with X25519 and ChaCha20-Poly1305, per-session ephemeral identifiers, message signing, and store-and-forward relaying. Local data is encrypted on mobile via SQLCipher, with keys stored in the OS keychain through FlutterSecureStorage. The system also supports export/import of encrypted bundles and selective backups. There is no centralized server; every nearby peer is potentially untrusted.



Key assets include message confidentiality and integrity, Noise static keys and session keys, contact trust state, message history, export bundles, and metadata about mesh topology. Security controls are primarily implemented in lib/core/security/\*, lib/data/services/\*, and lib/data/database/\*, with supporting documentation in docs/security/security\_guarantees.md and tests (for example integration\_test/security/database\_encryption\_device\_test.dart).



Threat model, Trust boundaries and assumptions

Trust boundaries

Untrusted BLE transport and mesh peers: all incoming advertisements, GATT writes, fragments, queue syncs, and relay traffic are attacker-controlled.

Local filesystem: export bundles and backups are user-selected files and must be treated as untrusted on import.

OS secure storage: trusted to protect static identity and database keys; compromise of the device or keychain breaks confidentiality.

Local database: encrypted on mobile platforms; plaintext on desktop/test builds.

Build-time configuration: compile-time flags can enable legacy crypto or relax enforcement (for example PAKCONNECT\_ALLOW\_LEGACY\_V2\_DECRYPT).

Attacker-controlled inputs

BLE handshake messages, protocol frames, relayed packets, and message fragments.

Ephemeral IDs, hint advertisements, and mesh relay metadata (TTL, hops, hashes).

Pairing requests and verification payloads from untrusted peers.

Export bundle contents and file paths selected for import.

Sender-supplied display names and chat content.

Operator-controlled inputs

Passphrases for export/import and local settings (spy mode, hint broadcast, queue limits).

Device lock screen and OS keychain availability.

Optional runtime feature toggles and debug flags.

Backup/export file locations.

Developer-controlled inputs

Test fixtures, mocks, and integration tests in test/ and integration\_test/.

Build flags (legacy passphrase, signature requirement, downgrade guard).

Debug logging and CI tooling.

Assumptions

Users can perform out-of-band verification for pairing when higher trust is required.

OS secure storage behaves as a trusted boundary on Android/iOS.

Crypto dependencies (Noise, SQLCipher, pinenacl, cryptography, pointycastle) are correct.

There is no trusted server; all peers and relays may be malicious.

Desktop/test builds are not used for sensitive production data because database encryption may be unavailable.

Attack surface, mitigations and attacker stories

1\) BLE handshake and identity establishment

Surface: BLE discovery and handshake (lib/data/services/ble\_handshake\_service.dart, lib/core/bluetooth/\*, lib/core/security/noise/\*, lib/core/services/security\_manager.dart).



Threats: MITM during Noise XX handshake, identity spoofing with ephemeral IDs, downgrade to legacy modes, replay of handshake packets.



Mitigations:



Noise XX/KK handshakes with static keys in secure storage (NoiseEncryptionService).

Secure key zeroing via SecureKey to reduce in-memory leakage.

Persistent-to-ephemeral mapping for session resolution (NoiseSessionManager, SecurityManager.registerIdentityMapping).

Pairing with PIN verification (lib/data/services/pairing\_service.dart) to elevate trust.

Protocol downgrade guard (PeerProtocolVersionGuard).

Residual risks: XX is unauthenticated until pairing completes; PIN codes are short and should be validated out-of-band. BLE metadata (timing, proximity) remains observable.



2\) Message serialization, integrity, and replay protection

Surface: Protocol parsing, compression, and signature validation (lib/domain/models/protocol\_message.dart, lib/data/services/protocol\_message\_handler.dart, lib/data/services/inbound\_text\_processor.dart, lib/domain/services/signing\_manager.dart).



Threats: Crafted payloads that bypass signature or encryption checks, downgrade to legacy crypto, or cause parser crashes.



Mitigations:



Versioned crypto metadata (CryptoHeader) and canonicalized signing (SigningManager.signaturePayloadForMessage).

Fail-closed encryption in SecurityManager (no plaintext fallback on send).

Replay protection and nonce tracking (MessageSecurity).

Legacy global decrypt requires explicit build-time passphrase; plaintext markers avoid silent insecurity (SimpleCrypto).

Residual risks: Compression lacks explicit global size ceilings, allowing potential CPU/memory spikes. Build flags can weaken enforcement if misconfigured.



3\) Mesh relay, store-and-forward, and DoS

Surface: Mesh relay engine, queue sync, fragmentation, and offline queues (lib/core/messaging/mesh\_relay\_engine.dart, lib/data/services/mesh\_relay\_handler.dart, lib/domain/services/spam\_prevention\_manager.dart, lib/data/services/message\_fragmentation\_handler.dart, lib/core/messaging/offline\_message\_queue.dart).



Threats: Flooding relay traffic, fragment bombs, battery drain, TTL loops, and memory exhaustion.



Mitigations:



Rate limiting, size caps, hop count validation, and loop checks (SpamPreventionManager).

Deduplication via seen message store and replay cache (MessageSecurity).

Fragment reassembly timeouts and cleanup (MessageFragmentationHandler).

Bandwidth allocation between direct and relay queues (OfflineMessageQueue).

Residual risks: A persistent nearby attacker can still generate high traffic to drain battery or storage; relay metadata is visible to observers.



4\) Data at rest, backup, and export/import

Surface: SQLCipher database, secure storage, backups, and export bundles (lib/data/database/\*, lib/data/services/export\_import/\*, lib/data/repositories/contact\_repository.dart, lib/data/repositories/user\_preferences.dart).



Threats: Extraction of encryption keys, tampered import bundles, weak passphrases, and plaintext storage on desktop builds.



Mitigations:



SQLCipher with key stored in secure storage; fail-closed on key retrieval failure (DatabaseEncryption, DatabaseHelper).

Export bundles encrypted with PBKDF2 + AES-256-GCM and checksum validation (EncryptionUtils, ImportService).

Passphrase strength validation and warnings (EncryptionUtils.validatePassphrase).

Residual risks: Export bundles include all keys; weak or reused passphrases expose full history. Desktop/test builds can store plaintext DBs and should be treated as non-production.



5\) Privacy, metadata, and hint advertising

Surface: Ephemeral IDs and BLE hint advertisements (EphemeralKeyManager, HintAdvertisementService, ContactRecognizer).



Threats: Tracking via repeated ephemeral IDs or hint collisions; correlating traffic across relay hops.



Mitigations:



Session-scoped ephemeral IDs; rotation on app restart (EphemeralKeyManager).

Spy mode disables hint broadcasting (UserPreferences, BLEHandshakeService).

Blinded hints reduce direct disclosure (HintAdvertisementService).

Residual risks: Hints are short and can collide; adversaries can observe traffic patterns and timing.



6\) Logging and diagnostics

Surface: Application logs in core/data layers.



Threats: Sensitive data leakage via logs or debug builds.



Mitigations: Logging often truncates identifiers and discourages print(). Security guarantees explicitly avoid hardcoded passphrases.



Residual risks: Debug logs can still leak metadata if collected from devices.



Attacker stories (calibrated to real usage)

Nearby malicious peer injects crafted BLE protocol messages to impersonate a contact. Noise sessions and signatures mitigate this, but without pairing, spoofing of ephemeral identities is still possible.

Mesh spammer floods the relay network with large fragments to drain battery. Rate limiting and hop checks reduce impact, but close-proximity DoS is still plausible.

Stolen export bundle is brute-forced due to a weak passphrase, yielding database contents and keys. Passphrase validation helps but cannot prevent weak user choices.

Device theft or OS compromise exposes secure storage keys, enabling full decryption of stored data. This is outside the application’s control and is a critical environmental risk.

Malicious import replaces keys and history using a tampered bundle. Checksums reduce accidental corruption, but trust in the bundle file is required.

Out-of-scope or low relevance: CSRF/SSRF/XSS are generally not applicable to the BLE-centric mobile runtime unless a web build introduces HTML surfaces.



Criticality calibration (critical, high, medium, low)

Critical



Remote or local extraction of Noise static private keys or SQLCipher keys (full history and future sessions compromised).

Successful MITM that bypasses pairing/signature checks to impersonate a verified contact.

Configuration or code paths that silently disable encryption for outbound traffic.

High



Downgrading encrypted messaging to legacy or unauthenticated modes across sessions.

Compromise of export bundle passphrase or import flows that overwrite keys with attacker-controlled values.

Persistent relay manipulation causing message censorship or selective message loss.

Medium



Resource exhaustion via fragmentation or compression leading to crashes or battery drain.

Metadata leakage via BLE hints or relay statistics enabling session-level tracking.

Exposure of plaintext databases in desktop/test deployments.

Low



Minor privacy leaks through debug logs or UI display name spoofing without cryptographic impact.

Temporary replay of already-processed messages that are later deduplicated.

Non-production testing misconfigurations without end-user exposure.







\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_





I reviewed ThreatModel.md against the implementation and tests in the archive. My take: the model is mostly sound for the core messaging, session, and mobile-at-rest story, but it is too optimistic on backup/import and a bit inaccurate in a few smaller places. This was a static verification from code and tests; I could not execute Flutter tests in this container because the Flutter/Dart toolchain is not available here.



I also wrote up a reusable review note here: pakconnect\_threatmodel\_review.md



Overall verdict



For the live system, you have done most of the important realistic things already. The remaining risks around BLE metadata leakage, nearby DoS, unauthenticated XX before user verification, weak user passphrases, and device compromise are normal tradeoffs for a serverless BLE mesh messenger.



The one area I would not file under “acceptable tradeoff” yet is export/import. That part still has fixable design gaps.



What checks out



Your threat model’s stronger claims are actually backed by code:



Mobile DB encryption really is fail-closed. On Android/iOS the DB key comes from secure storage, and startup rethrows if that fails, rather than silently falling back to plaintext. See lib/data/database/database\_encryption.dart:33-79 and lib/data/database/database\_helper.dart:68-86,123-142. That matches ThreatModel.md:163-169.



Outbound encryption really is fail-closed. Text and binary send both throw if only the legacy/global path remains, instead of transmitting unencrypted. See lib/core/services/security\_manager.dart:387-395,741-747, with tests in test/core/security/encryption\_fail\_open\_test.dart:96-160. That supports ThreatModel.md:111-118.



Legacy decrypt is not silently enabled by a hardcoded secret. It requires PAKCONNECT\_LEGACY\_PASSPHRASE at build time; otherwise decrypt fails. See lib/domain/services/simple\_crypto.dart:39-60,134-164.



Noise static keys, secure-key zeroing, identity mapping, and downgrade tracking are real. See lib/core/security/noise/noise\_encryption\_service.dart:81-112, lib/core/security/secure\_key.dart:36-54,77-95, lib/core/services/security\_manager.dart:83-102, lib/core/security/noise/noise\_session\_manager.dart:99-145, and lib/core/security/peer\_protocol\_version\_guard.dart:1-65, plus test coverage in test/core/security/peer\_protocol\_version\_guard\_phase13\_test.dart:11-80. That lines up well with ThreatModel.md:83-93.



Relay/DoS controls are present. There are concrete limits for relay rate, sender rate, message size, hop count, duplicate detection, trust score, and loop checks in lib/domain/services/spam\_prevention\_manager.dart:16-21,68-106,306-428, plus 30-second fragment cleanup in lib/data/services/message\_fragmentation\_handler.dart:25-27. That supports ThreatModel.md:137-145.



Privacy toggles for hints are real. Hint broadcasting can be disabled, and the hint format is very small and blinded. See lib/data/repositories/user\_preferences.dart:180-199, lib/domain/services/advertising\_manager.dart:273-283, and lib/domain/utils/hint\_advertisement\_service.dart:7-16,29-58. That supports ThreatModel.md:187-193.



Where the threat model is too optimistic



The biggest issue is the export/import section.



ThreatModel.md says bundles are encrypted with PBKDF2 + AES-256-GCM and checksum validation, which is partly true for the metadata blobs (lib/domain/services/encryption\_utils.dart:29-43,87-150; ThreatModel.md:163-169). But the bundle does not contain the database contents. It contains a database path string: lib/domain/models/export\_bundle.dart:22-30,46-59.



The checksum is just an unkeyed SHA-256 over the encrypted blobs plus that path string: lib/data/services/export\_import/export\_service.dart:132-154 and lib/domain/services/encryption\_utils.dart:163-168. Import recomputes the same checksum and then trusts bundle.databasePath: lib/data/services/export\_import/import\_service.dart:87-101,147-165,266-279.



That means:



the .pakconnect file is not self-contained



the referenced DB file is not cryptographically bound to the bundle



database\_path can be changed and the checksum recomputed without knowing the passphrase



DB checksum validation only happens if a separate .meta.json sidecar happens to exist next to the referenced backup file: lib/data/database/database\_backup\_service.dart:160-163,204-223



So the attacker story in ThreatModel.md:225 understates the issue. This is not just “trust in the bundle file is required.” The bundle format itself leaves a real integrity/portability gap.



There is a second serious problem: import is destructively ordered. It clears existing data and wipes secure storage before confirming that the DB file exists or that restore will succeed: lib/data/services/export\_import/import\_service.dart:135-165,301-325. That is an availability/integrity risk, not an acceptable tradeoff. A failed import can erase working state.



There is also an operational hint that this area is not just theoretically weak but likely awkward in practice: the UI lets the user select only a .pakconnect file, not a companion DB backup or metadata file: lib/presentation/widgets/import\_dialog.dart:36-46,137-142. Since the actual DB bytes live outside the bundle, cross-device restore looks fragile.



Where the threat model is a bit inaccurate



A few statements should be tightened:



ThreatModel.md:169 says export bundles include all keys. They do not. Export only gathers db\_encryption\_key\_v1, ecdh\_public\_key\_v2, and ecdh\_private\_key\_v2 in lib/data/services/export\_import/export\_service.dart:191-208. It does not export Noise static keys (lib/core/security/noise/noise\_encryption\_service.dart:25-27,81-112) or cached shared secrets/seeds (lib/data/repositories/contact\_repository.dart:240-279).



ThreatModel.md:115,139 credits replay protection to MessageSecurity. That class exists (lib/domain/services/message\_security.dart:61-149), but the live dedup story is more clearly in SeenMessageStore, relay suppression, and spam checks: lib/data/services/seen\_message\_store.dart:15-27,74-157, lib/data/services/relay\_coordinator.dart:319-327, lib/domain/services/spam\_prevention\_manager.dart:377-394.



ThreatModel.md:119 says compression lacks explicit size ceilings. That is slightly too pessimistic. The main protocol framing includes a 16-bit original-size field and validates decompressed length: lib/domain/models/protocol\_message.dart:35-37,63-72,107-126 and lib/domain/utils/compression\_util.dart:149-189. Resource exhaustion is still possible in principle, but the document overstates this particular gap.



ThreatModel.md:119 frames legacy weakening mainly as a build-misconfiguration risk. In reality, some migration defaults are permissive today: PAKCONNECT\_ALLOW\_LEGACY\_V2\_DECRYPT=true in lib/data/services/inbound\_text\_processor.dart:27-34 and lib/data/services/protocol\_message\_handler.dart:30-37, and PAKCONNECT\_ALLOW\_LEGACY\_V2\_SEND=true in lib/data/services/outbound\_message\_sender.dart:28-31. There are meaningful controls layered on top, but this is an active migration tradeoff, not just a hypothetical operator mistake.



Residual risks that look like acceptable tradeoffs



These look reasonable to accept, as long as the document says them plainly:



BLE timing/proximity/traffic metadata remains observable.



A nearby attacker can still cause battery drain or noisy mesh traffic despite rate limits.



Noise XX is unauthenticated until pairing or another verification step completes.



Device compromise or OS keychain compromise defeats local secrecy.



Weak export passphrases remain a user risk.



Hint correlation/collision risk remains when discoverability is enabled.



Debug/collected logs can leak metadata.



Desktop/test builds without mobile SQLCipher guarantees should stay non-production.



Residual risks I would still mitigate



The realistic next moves are:



Redesign export/import into a self-contained authenticated archive. Put DB bytes inside the package, or package bundle + DB + metadata together with a manifest authenticated as one unit.



Make import atomic. Preflight everything first, restore to a temp location, swap only on success, and keep rollback state until the new DB opens cleanly.



Tighten migration defaults when rollout allows. Flip legacy v2 send/decrypt defaults off and require v2 signatures by default.



Slightly harden pairing. Attempt limits or lockout, plus a better short-auth/fingerprint confirmation path for higher assurance.



Bottom line



So my answer is:



Yes, most of your threat model reflects real controls you have actually implemented.



Yes, many of the remaining risks are normal, acceptable tradeoffs for this kind of product.



No, backup/import should not yet be treated as “we’ve done what can realistically be done.” That part still needs concrete improvement.



Once export/import is fixed and the wording is corrected around replay, exported keys, compression, and legacy defaults, the remainder looks like a pretty reasonable security posture rather than a model that is hand-waving away real issues.



---

## Mitigations Applied (Security Hardening Session)

The following concrete mitigations were implemented to address the gaps identified above.

### Phase 0: Export/Import Security Overhaul (commit 6fb2f28)

**Problem**: Unkeyed SHA-256 checksum, destructive import ordering, bundle not self-contained.

**Fixes**:
- Replaced SHA-256 checksum with **HMAC-SHA256** keyed to the derived encryption key. Attacker can no longer modify data and recompute the checksum without knowing the passphrase.
- Rewrote import ordering: all preflight validation (decrypt, verify HMAC, validate keys, check DB integrity) completes **before** any destructive operation (`_clearExistingData`).
- Bundle format bumped to **v2.0.0**: database bytes are now **embedded** inside the `.pakconnect` file (AES-256-GCM encrypted, base64 encoded). No external DB file dependency.
- Backward-compatible v1.0.0 import preserved with deprecation warning.
- 15 new adversarial tests including tamper-then-recompute, missing-DB-preserves-data, and cross-device round-trip.

### Phase 1: Password Hardening (commit c6a13f2)

**Fixes**:
- **PBKDF2 iterations increased from 100,000 → 600,000** (~500ms per guess vs ~80ms). Each brute-force attempt is 6× more expensive.
- **Exponential backoff on failed import attempts**: 0s → 2s → 5s → 15s → 30s → 60s cap. Tracked in SharedPreferences, survives app restart. Resets on success.
- **Resumable import checkpoint**: Before destructive `_clearExistingData`, a JSON checkpoint (keys, preferences, dbRestorePath) is saved to temp. On crash/kill, `resumePendingImport()` picks up from the point of no return. Import no longer loses data on interruption.

### Phase 2: Incremental Backup (commit cd998db)

**Fixes**:
- Added `baseTimestamp` and `isIncremental` to ExportBundle (format v2.1.0).
- `SelectiveBackupService.createSelectiveBackup()` accepts `since` parameter — filters with `WHERE updated_at > ?`.
- Incremental imports use `INSERT OR REPLACE` (merge) instead of clearing existing data.
- `last_export_timestamp` persisted in preferences for automatic incremental detection.

### Phase 3: User-Facing Rate Limits (commit 317f837)

**Problem**: SpamPreventionManager had hardcoded rate limits; users couldn't tune DoS thresholds.

**Fixes**:
- Trust-tiered rate limits: unknown (trust < 0.4) = 5/hr, known (0.4-0.7) = 25/hr, friend (> 0.7) = 100/hr.
- User-configurable via Settings → Privacy slider controls for each trust tier (clamped ranges: 1-200, 1-500, 1-1000).
- `reloadUserRateLimits()` enables live updates without app restart.

### Phase 4: Stealth Addressing (commit 5058ac3)

**Problem**: `finalRecipient` in relay metadata exposed recipient identity to all relay nodes.

**Fixes**:
- ECDH-based stealth addressing (EIP-5564 simplified for BLE mesh):
  - Sender generates ephemeral R, computes `sharedSecret = X25519(r, recipientScanKey)`.
  - Derives 1-byte `viewTag` (fast reject, filters 99.6% non-matches) and 32-byte `stealthAddress`.
  - Relay metadata carries `(R, viewTag, stealthAddr)` instead of plaintext recipient.
- `RelayDecisionEngine.isMessageForCurrentNodeFromMetadata()` performs stealth scan first, falls back to plaintext.
- Constant-time comparison prevents timing attacks on stealth address matching.

### Phase 5: Sealed Sender (commit 75f33d7)

**Problem**: `originalSender` in relay metadata exposed sender identity to all relay nodes.

**Fixes**:
- When `sealedSender: true`, `originalSender` is replaced with sentinel `"sealed"` in wire format.
- Real sender identity packed into encrypted payload via `SealedSenderPayload.pack()`.
- Receiving side: after Noise decrypt, `SealedSenderPayload.unpack()` extracts real sender.
- Relay nodes see only `"sealed"` — no sender identity leaked.
- Backward compatible: non-sealed messages work unchanged.

### Phase 6: Broadcast Mode for Small Networks (commit cc6f0fc)

**Problem**: Routing metadata (next-hop selection) leaked information in small networks where flooding is practical.

**Fixes**:
- Networks ≤30 peers use 100% flood relay (no probabilistic skip).
- When combined with sealed sender, `finalRecipient` is replaced with broadcast sentinel `FFFFFFFFFFFFFFFF`.
- Result: in small networks with stealth + sealed sender, relay nodes see **zero routing metadata** — only broadcast marker, sealed sender placeholder, and stealth envelope.
- Recipients self-identify via view tag (1 ECDH per message that passes fast filter).

### Updated Residual Risk Assessment

| Risk | Status | Notes |
|------|--------|-------|
| Weak export passphrase | **Mitigated** | 600k PBKDF2 iterations, exponential backoff on fails |
| Destructive import | **Fixed** | Preflight-before-clear, resumable checkpoint |
| Bundle not self-contained | **Fixed** | v2.0.0+ embeds encrypted DB bytes |
| Unkeyed checksum | **Fixed** | HMAC-SHA256 with derived key |
| Relay metadata leaks recipient | **Mitigated** | Stealth addressing (Phase 4) |
| Relay metadata leaks sender | **Mitigated** | Sealed sender (Phase 5) |
| Small network routing metadata | **Mitigated** | Broadcast + view tag (Phase 6) |
| DoS via relay flooding | **Mitigated** | User-configurable trust-tiered rate limits |
| Timing analysis | **Unfixable** | Fundamental to any real-time system |
| Device compromise | **Unfixable** | Outside application control |
| BLE proximity metadata | **Unfixable** | Physical layer limitation |


# PakConnect Security Overview

PakConnect operates without a project-operated messaging server. Every peer is
treated as untrusted until the relevant cryptographic handshake completes.
Outbound user-message encryption is fail-closed: if key material is unavailable
or a cipher operation fails, the user payload is not sent. Discovery, control,
acknowledgement and routing metadata have separate exposure and must not be
described as end-to-end encrypted content.

---

## Security Layers

### Transport Security
Direct connected user-message payloads use the Noise Protocol Framework. New
contacts complete a Noise XX handshake (mutual authentication, forward
secrecy). Established contacts use Noise KK when both static keys are known in
advance. The symmetric cipher is ChaCha20-Poly1305 with X25519 Diffie-Hellman
for key agreement. Sessions rekey after the configured message/time limits.
For an offline recipient with known static key material, the relay lane builds
a signed encrypted v2 `sealed_v1` inner `ProtocolMessage` instead of requiring
a live direct Noise session. BLE discovery, handshake/control frames,
acknowledgements and routing metadata are assessed separately and are not
covered by this payload-confidentiality statement.

### Data at Rest
On Android and iOS, the local database is opened through SQLCipher using a
random 256-bit key held in platform secure storage. Key retrieval is
fail-closed: if secure storage returns an error or an empty key, the mobile
database does not open. Desktop and test factories may deliberately use
plaintext SQLite when the SQLCipher native library is unavailable; those
builds are not production encryption evidence. Direct physical-device proof of
the encrypted bytes at rest remains a release-validation gate.

### Relay Privacy
Relay payloads must be encrypted before entering the mesh, and relays enforce
hop/dedup policy without decrypting that inner payload. The codebase also
contains tested sealed-sender and stealth-address primitives. They are not the
default outgoing path today: the live mesh coordinator creates relays with
`sealedSender` left false, so intermediate nodes can still observe
sender/recipient routing aliases. Treat metadata anonymity as an available
design lane, not a current product guarantee. The `sealed_v1` inner content
lane and sealed-sender metadata privacy are distinct mechanisms.

### Spam Prevention
The relay engine applies rate, size, hop, duplicate, loop and trust checks. A Hashcash-style proof-of-work service and adaptive cost policy are implemented and tested, but the production relay factory currently constructs the engine without a cost policy, so proof of work is not enforced by default. Rate/queue/connection limits are the live controls; PoW remains an integration decision.

### Export/Import
Export v2.1 derives a key from the user passphrase with PBKDF2, then separately
AES-256-GCM encrypts metadata, keys, preferences, and the base64-encoded database
bytes. HMAC-SHA256 covers those encrypted fields and the restore metadata. The
embedded database bytes are themselves SQLCipher-encrypted only when the source
database came from the Android/iOS SQLCipher path; desktop/test source bytes may
be plaintext before the export layer encrypts them. The importer validates the
bundle version and MAC before writing data, and resumable imports checkpoint
progress.

### Identity
Each node maintains a persistent static key pair alongside a rotating ephemeral
identity. Ephemeral IDs change periodically to reduce straightforward long-term
correlation by passive observers. During contact discovery, hint values are
blinded before transmission, which reduces direct disclosure but does not prove
unlinkability against an observing relay. Pairing uses explicit verification to
upgrade trust. BLE connection attempts have retry/backoff controls, but the
current code does not implement a separate failed-PIN/handshake lockout; do not
claim brute-force lockout protection until that control and its tests exist.

---

## Detailed Documentation

- [Threat Model](../../ThreatModel.md) — comprehensive threat analysis with mitigations
- [Security Boundaries](security_guarantees.md) — implemented code boundaries
  separated from device-gated proof

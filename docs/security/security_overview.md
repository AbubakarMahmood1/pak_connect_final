# PakConnect Security Overview

PakConnect operates without any central server. Every peer is treated as untrusted until a cryptographic handshake completes. Encryption is fail-closed: if key material is unavailable or a cipher operation fails, the message is not sent. Privacy is a default constraint, not an opt-in feature.

---

## Security Layers

### Transport Security
All peer-to-peer communication uses the Noise Protocol Framework. New contacts complete a Noise XX handshake (mutual authentication, forward secrecy). Established contacts use Noise KK, which provides stronger guarantees because both static keys are known in advance. The symmetric cipher is ChaCha20-Poly1305 with X25519 Diffie-Hellman for key agreement. Sessions rekey after a configurable message count to bound the impact of any single session compromise.

### Data at Rest
On Android and iOS, the local database is opened through SQLCipher using a random 256-bit key held in platform secure storage. Key retrieval is fail-closed: if secure storage returns an error or an empty key, the mobile database does not open. Desktop and test factories may deliberately use plaintext SQLite when the SQLCipher native library is unavailable; those builds are not production encryption evidence.

### Relay Privacy
Relay payloads must be encrypted before entering the mesh, and relays enforce hop/dedup policy without decrypting that payload. The codebase also contains tested sealed-sender, stealth-address and small-network broadcast primitives. They are not the default outgoing path today: the live mesh coordinator creates relays with `sealedSender` left false, so intermediate nodes can still observe sender/recipient routing aliases. Treat metadata anonymity as an available design lane, not a current product guarantee.

### Spam Prevention
The relay engine applies rate, size, hop, duplicate, loop and trust checks. A Hashcash-style proof-of-work service and adaptive cost policy are implemented and tested, but the production relay factory currently constructs the engine without a cost policy, so proof of work is not enforced by default. Rate/queue/connection limits are the live controls; PoW remains an integration decision.

### Export/Import
Data export bundles embed the encrypted SQLCipher database directly, wrapped with an HMAC-SHA256 integrity tag derived from user-supplied credentials. The importer performs preflight validation — checking the MAC and bundle version — before writing any data. Large imports are resumable; progress state is checkpointed so an interrupted import can continue without data loss or partial corruption.

### Identity
Each node maintains a persistent static key pair alongside a rotating ephemeral identity. Ephemeral IDs change periodically to limit long-term tracking by passive observers. During contact discovery, hint values are blinded before transmission so a relay cannot correlate hints to specific users. Pairing uses explicit verification to upgrade trust. BLE connection attempts have retry/backoff controls, but the current code does not implement a separate failed-PIN/handshake lockout; do not claim brute-force lockout protection until that control and its tests exist.

---

## Detailed Documentation

- [Threat Model](../../ThreatModel.md) — comprehensive threat analysis with mitigations
- [Security Guarantees](security_guarantees.md) — implemented cryptographic guarantees

# PakConnect Security Overview

PakConnect operates without any central server. Every peer is treated as untrusted until a cryptographic handshake completes. Encryption is fail-closed: if key material is unavailable or a cipher operation fails, the message is not sent. Privacy is a default constraint, not an opt-in feature.

---

## Security Layers

### Transport Security
All peer-to-peer communication uses the Noise Protocol Framework. New contacts complete a Noise XX handshake (mutual authentication, forward secrecy). Established contacts use Noise KK, which provides stronger guarantees because both static keys are known in advance. The symmetric cipher is ChaCha20-Poly1305 with X25519 Diffie-Hellman for key agreement. Sessions rekey after a configurable message count to bound the impact of any single session compromise.

### Data at Rest
The local database is encrypted with SQLCipher (AES-256 in WAL mode). Key retrieval is fail-closed: if the platform secure storage returns an error or an empty key, the database does not open. There is no plaintext fallback. All message content, contact metadata, and group state are stored exclusively within the encrypted database.

### Relay Privacy
Relayed messages use stealth addressing so intermediate nodes cannot link a message to a specific recipient from the packet header alone. The sealed sender pattern conceals the originator identity from relay peers. When a node relays to multiple recipients simultaneously, broadcast mode is used to prevent traffic analysis from correlating individual deliveries back to a single source.

### Spam Prevention
The relay engine applies trust-tiered rate limits: contacts at higher trust levels receive more generous quotas. For untrusted or anonymous traffic, a Hashcash-style proof-of-work challenge is required before a message is accepted for relay. This raises the cost of flooding attacks without requiring any central authority or account system.

### Export/Import
Data export bundles embed the encrypted SQLCipher database directly, wrapped with an HMAC-SHA256 integrity tag derived from user-supplied credentials. The importer performs preflight validation — checking the MAC and bundle version — before writing any data. Large imports are resumable; progress state is checkpointed so an interrupted import can continue without data loss or partial corruption.

### Identity
Each node maintains a persistent static key pair alongside a rotating ephemeral identity. Ephemeral IDs change periodically to limit long-term tracking by passive observers. During contact discovery, hint values are blinded before transmission so a relay cannot correlate hints to specific users. Pairing requires PIN verification to prevent relay-assisted impersonation. The handshake subsystem tracks attempt counts and applies backoff to resist brute-force pairing attacks.

---

## Detailed Documentation

- [Threat Model](../../ThreatModel.md) — comprehensive threat analysis with mitigations
- [Security Guarantees](security_guarantees.md) — implemented cryptographic guarantees

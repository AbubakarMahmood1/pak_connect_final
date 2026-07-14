# Abstract

**PakConnect** is a secure, decentralized peer-to-peer messaging application built on Bluetooth Low Energy (BLE) mesh networking technology. The system enables device-to-device communication without requiring internet connectivity or centralized infrastructure.

## Core Capabilities

- **Peer-to-Peer Messaging**: Direct encrypted messaging between devices via BLE
- **Mesh Networking**: Intermediate-node relay implementation; extended-range
  three-device evidence remains pending
- **Payload Encryption**: Direct sessions use Noise XX/KK with
  ChaCha20-Poly1305; offline relay uses a signed recipient-key encrypted
  `sealed_v1` inner payload
- **Dual-Role BLE**: Central/peripheral architecture; simultaneous hardware
  behavior remains device-gated
- **Offline Message Queue**: Persistent storage for unreachable recipients with retry logic
- **Contact Management**: Three-tier security model (LOW/MEDIUM/HIGH) with identity verification
- **Broadcast Lists**: Sender-local lists that queue one encrypted direct
  message per recipient; no shared recipient-side group conversation
- **Archive System**: Full-text search (FTS5) for archived conversations
- **Adaptive Power Management**: Battery-aware scanning and advertising strategies

## Technology Stack

- **Platform**: Flutter 3.44.4+; Dart 3.10.3+ language floor (canonical SDK: 3.12.2)
- **State Management**: Riverpod 3.0
- **Cryptography**:
  - X25519 (Elliptic Curve Diffie-Hellman)
  - ChaCha20-Poly1305 (Authenticated Encryption)
  - SHA-256 (Hashing)
- **Storage**: SQLCipher-backed SQLite on Android/iOS; desktop/test SQLite may
  be plaintext, and mobile at-rest proof remains device-gated
- **Networking**: BLE GATT (Generic Attribute Profile)
- **Protocol**: Noise direct/session transport plus PakConnect's signed
  `sealed_v1` offline-relay envelope

## Key Design Principles

1. **Privacy-First**: No project-operated account, analytics, or message server;
   BLE and user-invoked platform flows still transmit documented data
2. **Censorship-Resistant**: No central authority or infrastructure dependency
3. **Forward Secrecy**: Ephemeral key rotation and session rekeying
4. **Mesh Resilience**: Duplicate detection, flood prevention, adaptive routing
5. **Battery Efficiency**: Burst scanning, duty cycling, power mode adaptation

## Primary Use Cases

- Emergency communication in disaster scenarios
- Secure messaging in network-restricted environments
- Privacy-focused peer-to-peer communication
- Mesh networking research and education
- Decentralized communication infrastructure

---

**Document Version**: 1.0
**Last Updated**: 2026-07-11
**Based on**: PakConnect Database Schema v12

# Vision Document

## 2.1 Problem Statement

Modern communication systems rely heavily on centralized infrastructure (cellular networks, internet servers, cloud services), creating several critical vulnerabilities:

1. **Infrastructure Dependency**: Communication fails when networks are unavailable (natural disasters, remote locations, network outages)
2. **Centralized Control**: Third parties can monitor, censor, or terminate communication
3. **Privacy Concerns**: Messages traverse multiple servers, creating metadata trails and surveillance opportunities
4. **Geographic Limitations**: Traditional messaging requires both parties to have network access simultaneously

### The Gap

Existing peer-to-peer solutions (Bluetooth chat apps) typically:
- Lack end-to-end encryption standards
- Don't support mesh networking for range extension
- Fail to handle offline message delivery
- Use weak or proprietary security schemes
- Don't scale beyond direct connections

## 2.2 Project Motivation

PakConnect addresses these gaps by combining:

1. **Proven Cryptography**: Noise Protocol Framework (used by WhatsApp, WireGuard)
2. **Mesh Networking**: Multi-hop relay code and automated regressions;
   extended-range behavior still requires controlled three-device evidence
3. **Offline Resilience**: Persistent message queue for deferred delivery
4. **Inspectable Implementation**: Public source supports review, while the
   repository's proprietary `LICENSE` reserves reuse rights
5. **No Infrastructure**: Zero dependency on internet or cellular networks

### Why This Matters

- **Emergency Communication**: Natural disasters, network blackouts
- **Privacy**: Journalists, activists in oppressive regimes
- **Remote Areas**: Hiking, rural regions with no coverage
- **Research**: Mesh networking algorithm development
- **Education**: Practical cryptography and networking concepts

## 2.3 Objectives

### Primary Objectives

1. **Secure Communication**
   - Implement Noise Protocol XX/KK patterns
   - Provide forward secrecy through ephemeral key rotation
   - Ensure message authenticity and integrity

2. **Decentralized Mesh Networking**
   - Enable multi-hop message relay (implementation present; physical
     `A -> B -> C` proof pending)
   - Implement duplicate detection and flood prevention
   - Optimize routing through network topology analysis

3. **Offline Capability**
   - Queue messages for offline recipients
   - Retry delivery with exponential backoff
   - Persist queue across app restarts

4. **User-Friendly Security**
   - Three-tier security model (LOW/MEDIUM/HIGH)
   - QR code pairing for key exchange
   - Visual security state indicators

5. **Battery Efficiency**
   - Adaptive scanning based on battery level
   - Burst mode for active periods
   - In-process duty cycling while the app runtime remains active; not a
     suspended/killed-process delivery guarantee

### Secondary Objectives

- Full-text search for archived messages
- Sender-local broadcast lists with per-recipient queue-submission status
- Contact favorites and organization
- Message export/import for backup
- Network topology visualization

## 2.4 Scope

### In Scope

**Core Messaging**
- One-to-one encrypted messaging
- Broadcast lists (multi-unicast into ordinary one-to-one chats; no shared
  membership or group transcript)
- Message status tracking (sent, delivered, read)
- Threading and replies
- Message editing and deletion

**Security**
- Noise Protocol handshake (XX/KK patterns)
- Contact verification (PIN, cryptographic)
- Security level management
- Key rotation and session management

**Mesh Networking**
- Multi-hop relay (up to 5 hops)
- Persistent completed-message deduplication (oldest-first cap per seen type)
- Network topology tracking
- Route optimization

**Data Management**
- SQLCipher-backed SQLite on Android/iOS; desktop/test plaintext fallback and
  device-proof boundary are tracked separately
- Archive system with FTS5 search
- Offline message queue
- Data export/import

**Power Management**
- Burst scanning controller
- Battery optimizer
- Adaptive power modes

### Out of Scope

- Voice/video calls (BLE bandwidth limitations)
- File transfers >1MB (MTU constraints)
- Internet gateway/bridge functionality
- Cloud synchronization
- Multi-device account sync
- End-to-end encrypted backups to cloud services

### Future Considerations

- Bluetooth Classic fallback for higher bandwidth
- Wi-Fi Direct integration
- Store-and-forward nodes (dedicated relay devices)
- Advanced routing protocols (AODV, DSR)

## 2.5 Constraints

### Technical Constraints

1. **BLE Range target**: 10-30 meters line-of-sight; no current device matrix
   establishes that range
2. **MTU Limitations**: Device-negotiated and not assumed above the default
   without evidence; larger payloads require fragmentation
3. **Connection configuration targets**: Android 7 and iOS 10, while current
   user-payload policy remains single-link and multi-link evidence is pending
4. **Background Restrictions**: iOS severely limits background BLE operations
5. **Battery Drain**: Continuous BLE scanning/advertising consumes significant power
6. **Latency**: Multi-hop relay adds device- and topology-dependent delay; no
   current physical benchmark establishes a range

### Cryptographic Constraints

1. **Key Storage**: Limited by platform secure storage (FlutterSecureStorage)
2. **Computation**: Mobile CPUs slower than desktop for crypto operations
3. **Handshake Time**: Noise handshake latency requires physical-device
   measurement; historical 200-500ms figures are targets, not results

### Platform Constraints

1. **Flutter BLE Plugins**: Dependent on `bluetooth_low_energy` plugin capabilities
2. **Android Permissions**: Location permission required for BLE scanning (Android 10+)
3. **iOS Background**: Requires app in foreground for reliable operation
4. **Windows/Linux/macOS**: Desktop BLE support varies by adapter

### Regulatory Constraints

1. **No Project-Operated Collection**: The app has no project-operated account,
   analytics, or message server; device and peer data flows still require
   platform-specific privacy review
2. **Proprietary License**: Use and redistribution are governed by `LICENSE`
3. **Export Control**: Cryptography obligations require jurisdiction-specific
   review; no open-source exemption is claimed

## 2.6 Stakeholder and User Description

### Primary Stakeholders

1. **End Users**
   - Need: Secure, private communication without infrastructure
   - Concerns: Ease of use, battery life, reliability
   - Technical Skill: Varies (basic smartphone users to technical experts)

2. **Developers and Security Reviewers**
   - Need: Clean codebase, documentation, test coverage
   - Concerns: Code quality, architecture, maintainability
   - Technical Skill: Software developers, cryptographers, researchers

3. **Privacy Advocates**
   - Need: Auditable security, no telemetry, local-only data
   - Concerns: Cryptographic correctness, metadata leakage
   - Technical Skill: Security researchers, auditors

4. **Emergency Response Organizations**
   - Need: Reliable communication in disaster scenarios
   - Concerns: Range, offline capability, ease of deployment
   - Technical Skill: First responders, coordinators

### User Personas

**Persona 1: Privacy-Conscious User**
- Age: 25-45
- Tech Savvy: Moderate to High
- Use Case: Daily secure communication
- Key Requirement: Strong encryption, no cloud storage

**Persona 2: Emergency Responder**
- Age: 30-55
- Tech Savvy: Low to Moderate
- Use Case: Disaster/emergency communication
- Key Requirement: Reliability, offline capability, simple UI

**Persona 3: Researcher/Developer**
- Age: 22-40
- Tech Savvy: High
- Use Case: Mesh networking research, algorithm testing
- Key Requirement: Open architecture, extensibility, logging

**Persona 4: Remote Area User**
- Age: 20-60
- Tech Savvy: Low to Moderate
- Use Case: Communication in areas with no cellular coverage
- Key Requirement: Range (mesh), battery efficiency, ease of use

### User Needs Matrix

| Need | Priority | Addressed By |
|------|----------|--------------|
| Secure messaging | Critical | Noise Protocol, SQLCipher |
| No internet required | Critical | BLE mesh networking |
| Offline message delivery | High | Offline message queue |
| Battery efficiency | High | Adaptive power management |
| Ease of use | High | QR code pairing, simple UI |
| Range extension | High | Multi-hop mesh relay |
| Privacy (no telemetry) | Critical | Local-only storage, no analytics |
| Contact verification | Medium | Security level system, PIN/crypto verification |
| Message history | Medium | SQLite storage, archive system |
| Send the same update to several contacts | Medium | Sender-local broadcast list service |

---

**Document Version**: 1.0
**Last Updated**: 2025-01-19

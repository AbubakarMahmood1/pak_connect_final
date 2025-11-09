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
2. **Mesh Networking**: Extended range through multi-hop relay
3. **Offline Resilience**: Persistent message queue for deferred delivery
4. **Open Source**: Transparent, auditable security implementation
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
   - Enable multi-hop message relay
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
   - Duty cycling for background operation

### Secondary Objectives

- Full-text search for archived messages
- Group messaging with per-member delivery tracking
- Contact favorites and organization
- Message export/import for backup
- Network topology visualization

## 2.4 Scope

### In Scope

**Core Messaging**
- One-to-one encrypted messaging
- Group messaging (multi-unicast)
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
- Duplicate detection (5-minute window)
- Network topology tracking
- Route optimization

**Data Management**
- SQLite storage with SQLCipher encryption
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

1. **BLE Range**: 10-30 meters line-of-sight (hardware dependent)
2. **MTU Limitations**: Typical 160-220 bytes per packet (requires fragmentation)
3. **Connection Limits**: Android ~7 simultaneous connections, iOS ~10
4. **Background Restrictions**: iOS severely limits background BLE operations
5. **Battery Drain**: Continuous BLE scanning/advertising consumes significant power
6. **Latency**: Multi-hop mesh introduces delays (seconds to minutes)

### Cryptographic Constraints

1. **Key Storage**: Limited by platform secure storage (FlutterSecureStorage)
2. **Computation**: Mobile CPUs slower than desktop for crypto operations
3. **Handshake Time**: Noise handshake adds ~200-500ms per new connection

### Platform Constraints

1. **Flutter BLE Plugins**: Dependent on `bluetooth_low_energy` plugin capabilities
2. **Android Permissions**: Location permission required for BLE scanning (Android 10+)
3. **iOS Background**: Requires app in foreground for reliable operation
4. **Windows/Linux/macOS**: Desktop BLE support varies by adapter

### Regulatory Constraints

1. **No Personal Data Collection**: GDPR/privacy compliance through local-only storage
2. **Open Source License**: MIT License requirements
3. **Export Control**: Cryptography export regulations (generally exempt for open source)

## 2.6 Stakeholder and User Description

### Primary Stakeholders

1. **End Users**
   - Need: Secure, private communication without infrastructure
   - Concerns: Ease of use, battery life, reliability
   - Technical Skill: Varies (basic smartphone users to technical experts)

2. **Open Source Contributors**
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
| Group communication | Medium | Group messaging service |

---

**Document Version**: 1.0
**Last Updated**: 2025-01-19

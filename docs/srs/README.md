# PakConnect - System Requirements Specification (SRS)

**Version**: 1.0
**Date**: Originally extracted 2025-01-19, last updated 2026-04
**Status**: Living, implementation-derived specification; verification tracked
separately

> **Note**: This SRS is derived from implementation and historical design
> material. Presence in code is not the same as production composition or
> device proof. Stealth addressing, sealed sender and proof-of-work include
> implemented/tested primitives but are not enabled default relay guarantees.
> Use [READINESS_AUDIT.md](../status/READINESS_AUDIT.md) and
> [DEVICE_VALIDATION_STATUS.md](../testing/DEVICE_VALIDATION_STATUS.md) for the
> current evidence state.

---

## Document Structure

This SRS is organized into 10 documents. Each requirement must still be checked
against current composition and the cited verification status; future,
dormant, and device-gated statements are called out where known.

### 1. Abstract (`01-abstract.md`)
High-level overview of PakConnect's capabilities, technology stack, and key design principles.

**Contents**:
- Core capabilities
- Technology stack (Flutter, Dart, Riverpod, Noise Protocol)
- Key design principles
- Primary use cases

---

### 2. Vision Document (`02-vision.md`)
Problem statement, project motivation, objectives, scope, and stakeholder analysis.

**Contents**:
- Problem statement (centralized communication vulnerabilities)
- Project motivation (privacy, censorship-resistance, mesh networking)
- Objectives (primary + secondary)
- Scope (in-scope, out-of-scope, future considerations)
- Constraints (technical, cryptographic, platform, regulatory)
- Stakeholder descriptions (users, contributors, privacy advocates)
- User personas (4 archetypes)

---

### 3. Functional Requirements (`03-requirements-functional.md`)
Detailed functional requirements extracted from implemented code.

**Sections**:
- **FR-1: Messaging** (1-to-1, sender-local broadcast lists, offline queue, features)
  - 26 requirements
- **FR-2: Mesh Networking** (relay, topology, queue sync)
  - 15 requirements
- **FR-3: Security & Cryptography** (Noise Protocol, keys, levels, identity)
  - 20 requirements
- **FR-4: Contact Management** (operations, trust)
  - 11 requirements
- **FR-5: Chat Management** (operations, features)
  - 11 requirements
- **FR-6: Archive System** (operations, maintenance)
  - 10 requirements
- **FR-7: BLE Communication** (dual-role, handshake, fragmentation)
  - 15 requirements
- **FR-8: Power Management** (adaptive modes, scanning)
  - 10 requirements
- **FR-9: Data Management** (database, export/import)
  - 12 requirements
- **FR-10: Notifications** (types, management)
  - 10 requirements
- **FR-11: Search** (messages, contacts)
  - 10 requirements

**Total**: 137 functional requirements

---

### 4. Non-Functional Requirements (`04-requirements-nonfunctional.md`)
Quality attributes and constraints.

**Sections**:
- **NFR-1: Performance** (response time, throughput, scalability)
- **NFR-2: Security** (cryptographic strength, data protection, privacy)
- **NFR-3: Reliability** (availability, fault tolerance, data integrity)
- **NFR-4: Usability** (UI, accessibility, learnability)
- **NFR-5: Maintainability** (code quality, testability, extensibility)
- **NFR-6: Portability** (platform support, environment)
- **NFR-7: Efficiency** (battery, resource usage, storage)
- **NFR-8: Compliance** (legal, standards)
- **NFR-9: Localization** (i18n)
- **NFR-10: Compatibility** (backward compat, interoperability)

**Total**: 105 non-functional requirements

---

### 5. Use Case Diagrams (`05-usecase-diagrams.md`)
Use case context for diagram generation.

**Contents**:
- 6 use case diagrams
- 36 use cases total
- Actors: User, BLE System, System (automated)
- Includes/extends relationships
- Mermaid syntax examples

**Diagrams**:
1. Core Messaging (send, receive, relay)
2. Contact Management (add, verify, delete, search)
3. Chat Management (open, archive, pin, export)
4. Broadcast Lists (create local list, add recipients, multi-unicast into direct chats)
5. Security & Keys (identity, handshake, upgrade, rekey)
6. Mesh Networking (relay, sync, spam prevention)

---

### 6. Sequence Diagrams (`06-sequence-diagrams.md`)
Detailed interaction flows for key scenarios.

**Contents**:
- 6 sequence diagrams
- All with Mermaid syntax
- Participants extracted from actual classes

**Diagrams**:
1. **Send Message (Direct Delivery)**: User → ChatScreen → MeshNetworkingService → NoiseSessionManager → BLEService
2. **Receive Message**: Sender → BLEService → BLEMessageHandler, then either
   direct authentication/decryption → MessageRepository, or relay-envelope
   routing → final-recipient authentication/decryption → MessageRepository
3. **Noise Handshake (XX Pattern)**: 3-message exchange between User A and User B
4. **Mesh Relay (A→B→C)**: Multi-hop message forwarding with smart routing
5. **Offline Message Queue**: Queue, retry, backoff, delivery on reconnection
6. **Database Migration**: Startup, version check, migration SQL, verification

---

### 7. Class & Domain Models (`07-class-and-domain-models.md`)
Object-oriented design and domain entities.

**Contents**:
- Domain model (9 conceptual entities)
- 5 class diagrams covering all layers
- 25+ core classes documented

**Diagrams**:
1. **Core Layer (Security)**: NoiseEncryptionService, NoiseSessionManager, NoiseSession, CipherState, DHState
2. **Core Layer (Messaging)**: MeshRelayEngine, OfflineMessageQueue, MessageRouter, SmartMeshRouter
3. **Data Layer (Repositories)**: ContactRepository, MessageRepository, ChatsRepository, GroupRepository
4. **Domain Layer (Services)**: MeshNetworkingService, ContactManagementService, ChatManagementService, GroupMessagingService
5. **BLE Layer**: BLEService, BLEConnectionManager, BLEMessageHandler, PeripheralInitializer

**Each class includes**:
- Public methods with signatures
- Key attributes
- Relationships
- Mermaid syntax

---

### 8. Architecture, Component & Data Flow (`08-architecture-component-dataflow.md`)
System architecture and data movement.

**Contents**:
- Layered architecture (4 layers)
- Component diagram
- Data flow diagrams (Level 0 & 1)
- Technology stack diagram

**Sections**:
1. **Layer 1: Presentation** - UI, screens, providers
2. **Layer 2: Domain** - Services, entities, use cases
3. **Layer 3: Core** - Security, messaging, BLE, routing, power
4. **Layer 4: Data** - Services, repositories, database

**Data Flow**:
- Level 0: Context (User ↔ PakConnect ↔ Remote Device ↔ Platform)
- Level 1: Major Processes (7 processes: Send, Receive, Relay, Handshake, Queue, Contact, Archive)

---

### 9. Activity & State Machine Diagrams (`09-activity-statemachine-diagrams.md`)
Process flows and state transitions.

**Contents**:
- 3 activity diagrams
- 3 state machine diagrams
- All with Mermaid syntax

**Activity Diagrams**:
1. **Send Message Flow**: Validation → Encrypt → Fragment → Send OR Queue → Retry
2. **Mesh Relay Flow**: Parse the relay envelope → Inspect visible metadata →
   Check duplicate/hop/spam → Route → Forward the unchanged encrypted inner
   payload over BLE
3. **Handshake (XX Pattern)**: 4 phases with 3-message Noise exchange

**State Machines**:
1. **Message Status**: DRAFT → PENDING → SENDING → AWAITING_ACK → DELIVERED/FAILED
2. **Noise Session State**: UNINITIALIZED → HANDSHAKING_* → ESTABLISHED → REKEYING/EXPIRED
3. **BLE Connection State**: DISCONNECTED → SCANNING/ADVERTISING → CONNECTING → CONNECTED → HANDSHAKING → READY

---

### 10. Database Schema (`10-database-schema.md`)
Complete database documentation.

**Contents**:
- 18 ordinary tables + 1 FTS5 virtual table
- All SQL CREATE statements
- ER diagram (Mermaid)
- Migration history (v1 → v12)

**Key Tables**:
- **contacts**: Three-ID model (publicKey, persistentPublicKey, currentEphemeralId)
- **chats**: Chat list with metadata
- **messages**: Enhanced message storage with JSON blobs
- **offline_message_queue**: Persistent queue with retry logic
- **archived_chats** + **archived_messages**: Archive system with FTS5
- **contact_groups** + **group_members** + **group_messages** + **group_message_delivery**: sender-local broadcast lists/status (legacy v9 names)
- **seen_messages**: Persistent mesh duplicate detection (v10)
- **change_log**: Incremental change tracking (v11)

**Features**:
- SQLCipher-backed mobile database path (Android/iOS); desktop/test may use
  plaintext SQLite, and device at-rest proof remains pending
- WAL mode for concurrency
- Foreign key constraints (11 relationships)
- 30+ indexes for performance
- FTS5 full-text search

---

## Reading Guide

- **Functional Requirements** (doc 3): Start here for feature coverage and verification.
- **Architecture & Data Flow** (doc 8): Entry point for understanding system structure and component responsibilities.
- **Sequence Diagrams** (doc 6): Use when tracing message paths or debugging protocol flows.
- **Class & Domain Models** (doc 7): Reference when navigating the codebase or planning refactoring.
- **Database Schema** (doc 10): Use for query writing, migration planning, and index optimization.
- **Diagram syntax**: All diagrams use Mermaid and can be rendered at [mermaid.live](https://mermaid.live) or any compatible tool.

---

## Statistics

| Metric | Count |
|--------|-------|
| Total Documents | 10 |
| Functional Requirements | 137 |
| Non-Functional Requirements | 105 |
| Use Cases | 36 |
| Sequence Diagrams | 6 |
| Class Diagrams | 5 |
| Activity Diagrams | 3 |
| State Machines | 3 |
| Database Tables | 18 ordinary + 1 FTS5 virtual table |
| Classes Documented | 25+ |
| Total Pages (estimated) | 100+ |

---

## Document Generation Metadata

**Extraction Method**: Direct code analysis and file reading
**Verification**: Database/toolchain/testing claims were revalidated on
2026-07-11; feature-status claims elsewhere in the SRS may still require
runtime or device evidence
**Codebase Version**: Database Schema v12
**Excluded**: UI implementation details, test files, future/planned features
**Included**: Core, Domain, Data layers; all business logic and infrastructure
**Documentation Date**: Originally extracted 2025-01-19, last updated 2026-07-11

---

**End of SRS Documentation**

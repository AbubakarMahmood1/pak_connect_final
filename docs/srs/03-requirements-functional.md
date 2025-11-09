# Functional Requirements

This document details system capabilities extracted from actual implemented code.

## FR-1: Messaging

### FR-1.1: One-to-One Messaging
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-1.1.1 | Send encrypted messages to individual contacts | `MeshNetworkingService.sendMeshMessage()` |
| FR-1.1.2 | Receive and decrypt messages from contacts | `BLEMessageHandler.handleIncomingMessage()` |
| FR-1.1.3 | Track message status (pending, sending, delivered, failed) | `QueuedMessage.status` enum |
| FR-1.1.4 | Store message history persistently | `MessageRepository.saveMessage()` with SQLite |
| FR-1.1.5 | Display sent/received timestamps | `Message.timestamp` field |

### FR-1.2: Group Messaging
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-1.2.1 | Send messages to multiple recipients (multi-unicast) | `GroupMessagingService.sendGroupMessage()` |
| FR-1.2.2 | Track per-member delivery status | `GroupMessage.deliveryStatus` map |
| FR-1.2.3 | Create and manage contact groups | `GroupRepository` with `contact_groups` table |
| FR-1.2.4 | Add/remove members from groups | `GroupRepository.addMember()`, `removeMember()` |
| FR-1.2.5 | Retrieve group message history | `GroupMessagingService.getGroupMessages()` |

### FR-1.3: Offline Message Queue
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-1.3.1 | Queue messages for offline recipients | `OfflineMessageQueue.queueMessage()` |
| FR-1.3.2 | Retry delivery with exponential backoff | `QueuedMessage.retryCount`, `nextRetryAt` |
| FR-1.3.3 | Persist queue across app restarts | `offline_message_queue` SQL table |
| FR-1.3.4 | Deliver queued messages on reconnection | `MeshNetworkingService._deliverQueuedMessagesToDevice()` |
| FR-1.3.5 | Support message priorities (urgent, normal, low) | `MessagePriority` enum |

### FR-1.4: Message Features
**Priority**: Medium
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-1.4.1 | Star/favorite messages | `messages.is_starred` field, `ChatManagementService.toggleMessageStar()` |
| FR-1.4.2 | Delete messages | `ChatManagementService.deleteMessages()` |
| FR-1.4.3 | Message threading/replies | `messages.reply_to_message_id`, `thread_id` fields |
| FR-1.4.4 | Message editing | `messages.edited_at`, `original_content` fields |
| FR-1.4.5 | Message forwarding | `messages.is_forwarded` flag |

## FR-2: Mesh Networking

### FR-2.1: Message Relay
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-2.1.1 | Relay messages through intermediate nodes | `MeshRelayEngine.processIncomingMessage()` |
| FR-2.1.2 | Detect and prevent duplicate relays | `SeenMessageStore` with 5-minute window |
| FR-2.1.3 | Limit relay hops (max 5) | `MeshRelayMetadata.hopCount`, `maxHops` check |
| FR-2.1.4 | Route optimization via topology analysis | `SmartMeshRouter.determineOptimalRoute()` |
| FR-2.1.5 | Flood prevention | `SpamPreventionManager.shouldRelay()` |

### FR-2.2: Network Topology
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-2.2.1 | Track connected peers | `TopologyManager.addNode()` |
| FR-2.2.2 | Estimate network size | `NetworkTopologyAnalyzer.estimateNetworkSize()` |
| FR-2.2.3 | Monitor connection quality | `ConnectionQualityMonitor.recordMessageSent()` |
| FR-2.2.4 | Calculate optimal routes | `RouteCalculator.calculateRoute()` |
| FR-2.2.5 | Visualize network topology | `NetworkTopologyScreen` (UI) |

### FR-2.3: Queue Synchronization
**Priority**: Medium
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-2.3.1 | Sync message queues between devices | `QueueSyncManager.initiateSync()` |
| FR-2.3.2 | Compare queue hashes | `OfflineMessageQueue.calculateQueueHash()` |
| FR-2.3.3 | Exchange missing messages | `QueueSyncManager.exchangeMessages()` |
| FR-2.3.4 | Track deleted message IDs | `deleted_message_ids` SQL table |
| FR-2.3.5 | Prevent duplicate delivery after sync | Hash-based deduplication |

## FR-3: Security & Cryptography

### FR-3.1: Noise Protocol
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-3.1.1 | Generate X25519 key pairs | `DHState.generateKeyPair()` |
| FR-3.1.2 | Perform XX pattern handshake (3 messages) | `NoiseSession` with XX pattern |
| FR-3.1.3 | Perform KK pattern handshake (2 messages, pre-shared keys) | `HandshakeStateKK` |
| FR-3.1.4 | Encrypt messages with ChaCha20-Poly1305 | `CipherState.encryptWithAd()` |
| FR-3.1.5 | Decrypt messages with AEAD verification | `CipherState.decryptWithAd()` |
| FR-3.1.6 | Session rekeying after 10k messages or 1 hour | `NoiseSession.needsRekey()` |

### FR-3.2: Key Management
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-3.2.1 | Generate static identity keys | `NoiseEncryptionService._loadOrGenerateStaticKey()` |
| FR-3.2.2 | Store keys in secure storage | `FlutterSecureStorage` |
| FR-3.2.3 | Generate ephemeral session keys | `EphemeralKeyManager.generateEphemeralKey()` |
| FR-3.2.4 | Rotate ephemeral keys periodically | `EphemeralKeyManager.cleanupExpiredKeys()` |
| FR-3.2.5 | Calculate key fingerprints (SHA-256) | `NoiseEncryptionService.calculateFingerprint()` |

### FR-3.3: Contact Security Levels
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-3.3.1 | LOW: Ephemeral session only | `Contact.securityLevel = 0`, ephemeral keys |
| FR-3.3.2 | MEDIUM: Persistent key + 4-digit PIN | `SecurityManager.upgradeContactSecurity()` with PIN |
| FR-3.3.3 | HIGH: Cryptographic verification | Triple DH with verification |
| FR-3.3.4 | Upgrade security level | `SecurityManager.upgradeContactSecurity()` |
| FR-3.3.5 | QR code key exchange | `QRContactData` with public key |

### FR-3.4: Identity Management
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-3.4.1 | Three-ID model: publicKey (immutable) | `contacts.public_key` PRIMARY KEY |
| FR-3.4.2 | persistentPublicKey (MEDIUM+ security) | `contacts.persistent_public_key` |
| FR-3.4.3 | currentEphemeralId (active session) | `contacts.current_ephemeral_id` |
| FR-3.4.4 | Chat ID resolution (security-aware) | `ChatUtils.generateChatId()` |
| FR-3.4.5 | Noise lookup (session-aware) | `NoiseSessionManager.getSession()` |

## FR-4: Contact Management

### FR-4.1: Contact Operations
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-4.1.1 | Add contact via QR code scan | `ContactManagementService` + QR scanner |
| FR-4.1.2 | Save contact with display name | `ContactRepository.saveContact()` |
| FR-4.1.3 | Update contact information | `ContactRepository.updateContact()` |
| FR-4.1.4 | Delete contact | `ContactManagementService.deleteContact()` |
| FR-4.1.5 | Mark contact as favorite | `contacts.is_favorite` flag |
| FR-4.1.6 | Search contacts by name/key | `ContactManagementService.searchContacts()` |

### FR-4.2: Contact Trust
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-4.2.1 | Track trust status | `contacts.trust_status` field |
| FR-4.2.2 | Mark as verified | `ContactRepository.markVerified()` |
| FR-4.2.3 | Display security indicators | `SecurityState` model |
| FR-4.2.4 | Verify contact fingerprint | PIN/crypto verification |
| FR-4.2.5 | Security status synchronization | `contacts.last_security_sync` timestamp |

## FR-5: Chat Management

### FR-5.1: Chat Operations
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-5.1.1 | Create chat on first message | `ChatsRepository.createChat()` |
| FR-5.1.2 | List all chats | `ChatManagementService.getAllChats()` |
| FR-5.1.3 | Archive chat | `ChatManagementService.toggleChatArchive()` |
| FR-5.1.4 | Pin chat to top | `ChatManagementService.toggleChatPin()` |
| FR-5.1.5 | Delete chat | `ChatManagementService.deleteChat()` |
| FR-5.1.6 | Clear chat history | `ChatManagementService.clearChatMessages()` |

### FR-5.2: Chat Features
**Priority**: Medium
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-5.2.1 | Unread message count | `chats.unread_count` field |
| FR-5.2.2 | Last message preview | `chats.last_message` field |
| FR-5.2.3 | Chat mute | `chats.is_muted` flag |
| FR-5.2.4 | Chat analytics | `ChatManagementService.getChatAnalytics()` |
| FR-5.2.5 | Export chat | `ChatManagementService.exportChat()` (JSON/text) |

## FR-6: Archive System

### FR-6.1: Archive Operations
**Priority**: Medium
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-6.1.1 | Archive chat with messages | `ArchiveManagementService.archiveChat()` |
| FR-6.1.2 | Restore archived chat | `ArchiveManagementService.restoreChat()` |
| FR-6.1.3 | Full-text search archived messages | `ArchiveSearchService` with FTS5 |
| FR-6.1.4 | Auto-archive by policy | `ArchivePolicy` (age-based, size-based) |
| FR-6.1.5 | Archive compression | `archived_chats.is_compressed` flag |

### FR-6.2: Archive Maintenance
**Priority**: Low
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-6.2.1 | Scheduled maintenance tasks | `AutoArchiveScheduler.start()` |
| FR-6.2.2 | Archive integrity checks | `ArchiveManagementService.performMaintenance()` |
| FR-6.2.3 | Storage capacity monitoring | Archive analytics |
| FR-6.2.4 | Archive policies configuration | `ArchivePolicy` management |
| FR-6.2.5 | Archive analytics | `ArchiveManagementService.getArchiveAnalytics()` |

## FR-7: BLE Communication

### FR-7.1: Dual-Role BLE
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-7.1.1 | Central mode scanning | `BLEService.startScanning()` |
| FR-7.1.2 | Peripheral mode advertising | `PeripheralInitializer.startAdvertising()` |
| FR-7.1.3 | Simultaneous central/peripheral | Dual-mode architecture |
| FR-7.1.4 | MTU negotiation | `BLEConnectionManager.negotiateMTU()` |
| FR-7.1.5 | Connection management | `BLEConnectionManager` (up to 7 connections) |

### FR-7.2: Handshake Protocol
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-7.2.1 | Phase 0: CONNECTION_READY | MTU establishment |
| FR-7.2.2 | Phase 1: IDENTITY_EXCHANGE | ephemeralId, displayName, noisePublicKey |
| FR-7.2.3 | Phase 1.5: NOISE_HANDSHAKE | XX/KK pattern execution |
| FR-7.2.4 | Phase 2: CONTACT_STATUS_SYNC | Security levels, trust status |
| FR-7.2.5 | Handshake timeout handling | `HandshakeCoordinator` with timeouts |

### FR-7.3: Message Fragmentation
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-7.3.1 | Fragment large messages | `MessageFragmenter.fragment()` |
| FR-7.3.2 | Reassemble fragments | `MessageFragmenter.reassemble()` |
| FR-7.3.3 | Handle out-of-order chunks | Sequence number tracking |
| FR-7.3.4 | Fragment timeout (30 seconds) | Cleanup of stale fragments |
| FR-7.3.5 | Interleaved message handling | Per-sender fragment state |

## FR-8: Power Management

### FR-8.1: Adaptive Power Modes
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-8.1.1 | HIGH_POWER: Continuous scanning | `AdaptivePowerManager.setMode(HIGH_POWER)` |
| FR-8.1.2 | BALANCED: Burst scanning (10s/20s) | Default mode with duty cycling |
| FR-8.1.3 | LOW_POWER: Minimal scanning (5s/60s) | Battery saver mode |
| FR-8.1.4 | Battery level monitoring | `BatteryOptimizer.currentLevel` |
| FR-8.1.5 | Automatic mode switching | Based on battery % and charging status |

### FR-8.2: Scanning Strategy
**Priority**: High
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-8.2.1 | Burst scanning controller | `BurstScanningController` |
| FR-8.2.2 | Duty cycling | Scan/sleep intervals |
| FR-8.2.3 | Screen-aware scanning | Pause scanning when screen off (optional) |
| FR-8.2.4 | Message send wake-up | Trigger scan on message send |
| FR-8.2.5 | Adaptive intervals | Adjust based on connection quality |

## FR-9: Data Management

### FR-9.1: Database Operations
**Priority**: Critical
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-9.1.1 | SQLite storage with SQLCipher encryption | `DatabaseHelper` with encryption |
| FR-9.1.2 | WAL mode for concurrency | `PRAGMA journal_mode = WAL` |
| FR-9.1.3 | Foreign key constraints | `PRAGMA foreign_keys = ON` |
| FR-9.1.4 | Database migrations | `DatabaseHelper._onUpgrade()` (v1-v9) |
| FR-9.1.5 | Database vacuum | `DatabaseHelper.vacuum()` (monthly) |

### FR-9.2: Data Export/Import
**Priority**: Medium
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-9.2.1 | Export contacts | `ContactManagementService.exportContacts()` |
| FR-9.2.2 | Export chats | `ChatManagementService.exportChat()` |
| FR-9.2.3 | Selective backup | `SelectiveBackupService` |
| FR-9.2.4 | Selective restore | `SelectiveRestoreService` |
| FR-9.2.5 | Full database backup | `DatabaseBackupService` |
| FR-9.2.6 | Encrypted export bundles | `EncryptionUtils` with password |

## FR-10: Notifications

### FR-10.1: Notification Types
**Priority**: Medium
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-10.1.1 | New message notifications | `NotificationService.showMessageNotification()` |
| FR-10.1.2 | Contact request notifications | `showContactRequestNotification()` |
| FR-10.1.3 | System notifications | `showSystemNotification()` |
| FR-10.1.4 | Background notifications (Android) | `BackgroundNotificationHandlerImpl` |
| FR-10.1.5 | Notification channels | MESSAGES, CONTACTS, SYSTEM |

### FR-10.2: Notification Management
**Priority**: Low
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-10.2.1 | Cancel individual notification | `NotificationService.cancelNotification()` |
| FR-10.2.2 | Cancel all notifications | `cancelAllNotifications()` |
| FR-10.2.3 | Notification permissions | `requestPermissions()` |
| FR-10.2.4 | Notification tap handling | Navigate to chat/contact |
| FR-10.2.5 | Platform-specific handlers | Factory pattern for Android/iOS |

## FR-11: Search

### FR-11.1: Message Search
**Priority**: Medium
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-11.1.1 | Search messages by content | `ChatManagementService.searchMessages()` |
| FR-11.1.2 | Search in active chats | SQLite LIKE queries |
| FR-11.1.3 | Search in archived messages | FTS5 full-text search |
| FR-11.1.4 | Unified search (active + archived) | `searchMessagesUnified()` |
| FR-11.1.5 | Search history | Message search history cache |

### FR-11.2: Contact Search
**Priority**: Low
**Status**: Implemented

| ID | Requirement | Implementation |
|----|-------------|----------------|
| FR-11.2.1 | Search by display name | `ContactManagementService.searchContacts()` |
| FR-11.2.2 | Search by public key | Exact match or prefix |
| FR-11.2.3 | Filter by security level | WHERE security_level = ? |
| FR-11.2.4 | Filter by favorite status | WHERE is_favorite = 1 |
| FR-11.2.5 | Contact search history | Search history cache |

---

**Document Version**: 1.0
**Last Updated**: 2025-01-19
**Total Functional Requirements**: 137

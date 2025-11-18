# Phase 4B API Signatures Analysis

## Overview
This document defines the exact API signatures that Phase 4B extracted components must align with. All type definitions are based on current codebase implementations.

---

## 1. RelayStatistics

**File**: `/home/abubakar/dev/pak_connect/lib/core/messaging/mesh_relay_engine.dart` (lines 968-1007)

### Constructor Signature
```dart
const RelayStatistics({
  required int totalRelayed,
  required int totalDropped,
  required int totalDeliveredToSelf,
  required int totalBlocked,
  required int totalProbabilisticSkip,      // Phase 3: Probabilistic relay skips
  required double spamScore,
  required double relayEfficiency,
  required int activeRelayMessages,
  required int networkSize,                  // Phase 3: Current network size
  required double currentRelayProbability,   // Phase 3: Current relay probability
});
```

### Fields
- `totalRelayed: int` - Messages successfully relayed
- `totalDropped: int` - Messages dropped (TTL exceeded, etc)
- `totalDeliveredToSelf: int` - Messages delivered to current node
- `totalBlocked: int` - Messages blocked by spam prevention
- `totalProbabilisticSkip: int` - Messages skipped due to probabilistic relay
- `spamScore: double` - Average spam score (0.0-1.0)
- `relayEfficiency: double` - (relayed + delivered) / total processed
- `activeRelayMessages: int` - Count of messages actively being relayed
- `networkSize: int` - Estimated network size (from TopologyAnalyzer)
- `currentRelayProbability: double` - Current relay probability (0.0-1.0)

### Usage
- Created by `MeshRelayEngine.getStatistics()` (line 464)
- Passed to `onStatsUpdated` callback (line 59)

---

## 2. QueueSyncMessage

**File**: `/home/abubakar/dev/pak_connect/lib/core/models/mesh_relay_models.dart` (lines 296-424)

### Constructor Signature
```dart
const QueueSyncMessage({
  required String queueHash,
  required List<String> messageIds,
  required DateTime syncTimestamp,
  required String nodeId,
  required QueueSyncType syncType,
  Map<String, String>? messageHashes,
  QueueSyncStats? queueStats,
  GCSFilterParams? gcsFilter,
});
```

### Fields
- `queueHash: String` - SHA256 hash of current queue state
- `messageIds: List<String>` - IDs of pending messages
- `syncTimestamp: DateTime` - When sync was initiated
- `nodeId: String` - Node requesting/responding to sync
- `syncType: QueueSyncType` - request/response/update
- `messageHashes: Map<String, String>?` - Optional message hashes for verification
- `queueStats: QueueSyncStats?` - Optional queue statistics
- `gcsFilter: GCSFilterParams?` - Optional GCS filter (98% bandwidth reduction)

### Factory Methods
```dart
// Create sync request
factory QueueSyncMessage.createRequest({
  required List<String> messageIds,
  required String nodeId,
  Map<String, String>? messageHashes,
  String? queueHash,                      // Optional: pre-calculated
  GCSFilterParams? gcsFilter,
})

// Create sync response
factory QueueSyncMessage.createResponse({
  required List<String> messageIds,
  required String nodeId,
  required QueueSyncStats stats,
  Map<String, String>? messageHashes,
})
```

### JSON Serialization
- `toJson()`: Returns `Map<String, dynamic>`
- `fromJson(Map<String, dynamic>)`: Factory constructor

### Enums
```dart
enum QueueSyncType { request, response, update }
```

---

## 3. QueueSyncResult

**File**: `/home/abubakar/dev/pak_connect/lib/core/messaging/queue_sync_manager.dart` (lines 532-614)

### Constructor Signature
```dart
const QueueSyncResult._({
  required bool success,
  String? error,
  required int messagesReceived,
  required int messagesUpdated,
  required int messagesSkipped,
  String? finalHash,
  Duration? syncDuration,
  required QueueSyncResultType type,
});
```

### Fields
- `success: bool` - Whether sync succeeded
- `error: String?` - Error message if failed
- `messagesReceived: int` - Count of new messages received
- `messagesUpdated: int` - Count of messages updated
- `messagesSkipped: int` - Count of messages skipped (already deleted locally)
- `finalHash: String?` - Final queue hash after sync
- `syncDuration: Duration?` - Time taken to complete sync
- `type: QueueSyncResultType` - success/alreadySynced/rateLimited/timeout/error

### Factory Methods
```dart
// Success with message counts
factory QueueSyncResult.success({
  required int messagesReceived,
  required int messagesUpdated,
  required int messagesSkipped,
  required String finalHash,
  required Duration syncDuration,
})

// Queues already synchronized
factory QueueSyncResult.alreadySynced()

// Rate limited
factory QueueSyncResult.rateLimited(String reason)

// Timeout
factory QueueSyncResult.timeout()

// Error
factory QueueSyncResult.error(String error)
```

### Helper Methods
```dart
// Copy with new duration (for internal use)
QueueSyncResult copyWithDuration(Duration duration)
```

### Enums
```dart
enum QueueSyncResultType { success, alreadySynced, rateLimited, timeout, error }
```

---

## 4. MeshRelayMessage

**File**: `/home/abubakar/dev/pak_connect/lib/core/models/mesh_relay_models.dart` (lines 189-293)

### Constructor Signature
```dart
const MeshRelayMessage({
  required String originalMessageId,
  required String originalContent,
  required RelayMetadata relayMetadata,
  required String relayNodeId,
  required DateTime relayedAt,
  String? encryptedPayload,
  ProtocolMessageType? originalMessageType,  // PHASE 2
});
```

### Fields
- `originalMessageId: String` - ID of original message
- `originalContent: String` - Unencrypted message content
- `relayMetadata: RelayMetadata` - Routing path, TTL, hop count, etc
- `relayNodeId: String` - Current relay node's public key
- `relayedAt: DateTime` - When this relay was created
- `encryptedPayload: String?` - Optional encrypted version
- `originalMessageType: ProtocolMessageType?` - For relay policy filtering (PHASE 2)

### Factory Methods
```dart
// Create new relay message
factory MeshRelayMessage.createRelay({
  required String originalMessageId,
  required String originalContent,
  required RelayMetadata metadata,
  required String relayNodeId,
  String? encryptedPayload,
  ProtocolMessageType? originalMessageType,  // PHASE 2
})

// Create next hop relay
MeshRelayMessage nextHop(String nextRelayNodeId)
```

### Getters
- `canRelay: bool` - Whether message can be relayed further
- `messageSize: int` - Size in bytes

### JSON Serialization
- `toJson()`: Returns `Map<String, dynamic>`
- `fromJson(Map<String, dynamic>)`: Factory constructor

### Key Dependencies
- `RelayMetadata`: Routing path, TTL, hop count, message hash
- `ProtocolMessageType`: Enum defining message types

---

## 5. ProtocolMessage Factory Methods

**File**: `/home/abubakar/dev/pak_connect/lib/core/models/protocol_message.dart`

### Existing Factory Methods (Used by Phase 4B)

**meshRelay** (lines 633-654):
```dart
static ProtocolMessage meshRelay({
  required String originalMessageId,
  required String originalSender,
  required String finalRecipient,
  required Map<String, dynamic> relayMetadata,
  required Map<String, dynamic> originalPayload,
  bool useEphemeralAddressing = false,        // STEP 7
  ProtocolMessageType? originalMessageType,  // PHASE 2
})
```

**relayAck** (lines 663-675):
```dart
static ProtocolMessage relayAck({
  required String originalMessageId,
  required String relayNode,
  required bool delivered,
})
```

**queueSync** (lines 656-661):
```dart
static ProtocolMessage queueSync({
  required QueueSyncMessage queueMessage,
})
```

**NOTE**: No `createRelay`, `createRelayAck`, or `createQueueSync` methods exist. Use the factory methods above instead.

---

## 6. QueuedMessage

**File**: `/home/abubakar/dev/pak_connect/lib/core/messaging/offline_message_queue.dart` (lines 1439-1597)

### Constructor Signature
```dart
QueuedMessage({
  required String id,
  required String chatId,
  required String content,
  required String recipientPublicKey,
  required String senderPublicKey,
  required MessagePriority priority,
  required DateTime queuedAt,
  required int maxRetries,
  String? replyToMessageId,
  List<String> attachments = const [],
  QueuedMessageStatus status = QueuedMessageStatus.pending,
  int attempts = 0,
  DateTime? lastAttemptAt,
  DateTime? nextRetryAt,
  DateTime? deliveredAt,
  DateTime? failedAt,
  String? failureReason,
  DateTime? expiresAt,
  // Relay-specific fields
  bool isRelayMessage = false,
  RelayMetadata? relayMetadata,
  String? originalMessageId,
  String? relayNodeId,
  String? messageHash,
  int senderRateCount = 0,
});
```

### Fields
**Core Message Fields**:
- `id: String` - Unique message ID
- `chatId: String` - Chat this message belongs to
- `content: String` - Message content
- `recipientPublicKey: String` - Recipient's public key
- `senderPublicKey: String` - Sender's public key
- `priority: MessagePriority` - normal/high/urgent/low
- `queuedAt: DateTime` - When queued

**Delivery Tracking**:
- `status: QueuedMessageStatus` - pending/sending/awaitingAck/retrying/delivered/failed
- `attempts: int` - Number of delivery attempts
- `lastAttemptAt: DateTime?` - Time of last attempt
- `nextRetryAt: DateTime?` - Scheduled retry time
- `deliveredAt: DateTime?` - When successfully delivered
- `failedAt: DateTime?` - When finally failed
- `failureReason: String?` - Why it failed

**Expiry & Limits**:
- `maxRetries: int` - Max retry attempts
- `expiresAt: DateTime?` - TTL deadline

**Relay-Specific** (optional):
- `isRelayMessage: bool` - Is this a relay message?
- `relayMetadata: RelayMetadata?` - Routing info
- `originalMessageId: String?` - Original message ID
- `relayNodeId: String?` - Current relay node
- `messageHash: String?` - For deduplication
- `senderRateCount: int` - Rate limit counter

### Factory Methods
```dart
// Create from mesh relay message
factory QueuedMessage.fromRelayMessage({
  required MeshRelayMessage relayMessage,
  required String chatId,
  required int maxRetries,
  QueuedMessageStatus status = QueuedMessageStatus.pending,
})

// Create next hop relay
QueuedMessage createNextHopRelay(String nextRelayNodeId)
```

### Getters
- `canRelay: bool` - Can this relay be forwarded?
- `relayHopCount: int` - Current hop count
- `hasExceededTTL: bool` - Has message expired?

### JSON Serialization
- `toJson()`: Returns `Map<String, dynamic>`
- `fromJson(Map<String, dynamic>)`: Factory constructor

### Enums
```dart
enum QueuedMessageStatus {
  pending,
  sending,
  awaitingAck,    // Waiting for final recipient ACK in mesh relay
  retrying,
  delivered,
  failed,
}
```

---

## 7. RelayMetadata

**File**: `/home/abubakar/dev/pak_connect/lib/core/models/mesh_relay_models.dart` (lines 14-186)

### Constructor Signature
```dart
const RelayMetadata({
  required int ttl,
  required int hopCount,
  required List<String> routingPath,
  required String messageHash,
  required MessagePriority priority,
  required DateTime relayTimestamp,
  required String originalSender,
  required String finalRecipient,
  int senderRateCount = 0,
});
```

### Fields
- `ttl: int` - Time-to-live (max hops)
- `hopCount: int` - Current hop count
- `routingPath: List<String>` - Nodes that relayed (EPHEMERAL keys)
- `messageHash: String` - SHA256 hash for deduplication
- `priority: MessagePriority` - Message priority level
- `relayTimestamp: DateTime` - When relay started
- `originalSender: String` - Original sender's public key
- `finalRecipient: String` - Final recipient's public key
- `senderRateCount: int` - Rate limiting counter

### Factory Methods
```dart
factory RelayMetadata.create({
  required String originalMessageContent,
  required MessagePriority priority,
  required String originalSender,
  required String finalRecipient,
  required String currentNodeId,
})

// Create next hop metadata
RelayMetadata nextHop(String currentNodeId)
```

### Getters
- `canRelay: bool` - hopCount < ttl
- `remainingHops: int` - ttl - hopCount
- `ackRoutingPath: List<String>` - Reversed for ACK propagation
- `previousHop: String?` - Where to send ACK back
- `isOriginator: bool` - Is this the originator?

### JSON Serialization
- `toJson()`: Returns `Map<String, dynamic>`
- `fromJson(Map<String, dynamic>)`: Factory constructor

---

## 8. Key Enums Used

### ProtocolMessageType
**File**: `/home/abubakar/dev/pak_connect/lib/core/models/protocol_message.dart` (lines 8-44)

Key types for Phase 4B:
- `meshRelay` - Relay message
- `relayAck` - Relay acknowledgment
- `queueSync` - Queue synchronization
- `textMessage` - Regular text message

### MessagePriority
**Location**: Used throughout, likely in `domain/entities/enhanced_message.dart`

Values: `urgent`, `high`, `normal`, `low`

### QueueSyncType
**File**: `/home/abubakar/dev/pak_connect/lib/core/models/mesh_relay_models.dart` (line 427)

```dart
enum QueueSyncType { request, response, update }
```

---

## 9. Critical Implementation Notes for Phase 4B

### 1. Factory Methods - DO NOT CREATE
- ProtocolMessage has NO `createRelay`, `createRelayAck`, `createQueueSync` methods
- Use: `ProtocolMessage.meshRelay()`, `ProtocolMessage.relayAck()`, `ProtocolMessage.queueSync()`

### 2. RelayStatistics Constructor
- ALL 10 fields are REQUIRED (no defaults)
- Retrieved via `MeshRelayEngine.getStatistics()`

### 3. QueueSyncMessage Dual Construction
- Use `QueueSyncMessage.createRequest()` for initiating sync
- Use `QueueSyncMessage.createResponse()` for responding
- Do NOT use `const` constructor directly in business logic

### 4. MeshRelayMessage.createRelay()
- Takes `RelayMetadata metadata` parameter (pre-created)
- Original message type is OPTIONAL (phase 2 feature)
- Factory returns new `MeshRelayMessage` instance

### 5. QueuedMessage Relay Fields
- `isRelayMessage` flag determines queue destination (direct vs relay)
- `relayMetadata` is optional but required if `isRelayMessage == true`
- Use `QueuedMessage.fromRelayMessage()` factory for type conversion

### 6. RelayMetadata Chain
- Create initial via `RelayMetadata.create()`
- Chain via `.nextHop(nodeId)` to increment hop count
- Validates TTL and loop prevention

### 7. JSON Serialization Round-Trips
- All types support `toJson()` and `fromJson()`
- QueueSyncMessage handles backward compatibility with GCS filters
- MeshRelayMessage preserves originalMessageType through serialization

---

## 10. Type Dependencies Chart

```
ProtocolMessage
├── payload contains:
│   ├── meshRelay payload
│   │   └── relayMetadata: Map<String, dynamic>
│   │       └── RelayMetadata.toJson()
│   ├── relayAck payload
│   └── queueSync payload
│       └── QueueSyncMessage.toJson()
│
MeshRelayMessage
├── relayMetadata: RelayMetadata
├── originalMessageType: ProtocolMessageType?
└── toJson() → Map<String, dynamic>
    └── Used in ProtocolMessage.meshRelay()
│
QueuedMessage
├── relayMetadata: RelayMetadata?
├── Creates via QueuedMessage.fromRelayMessage()
└── Stored in OfflineMessageQueue dual-queue system
│
RelayStatistics
└── Created by MeshRelayEngine.getStatistics()
│
QueueSyncMessage
├── factory constructors (createRequest, createResponse)
├── toJson() → payload for ProtocolMessage.queueSync()
└── Deserialized via QueueSyncMessage.fromJson()
```

---

## Summary for Phase 4B

**Components that must align with these signatures:**
1. `BLERelayHandler` - Creates/processes `MeshRelayMessage` and `ProtocolMessage`
2. `BLEQueueSyncHandler` - Creates `QueueSyncMessage` and processes results
3. `BLEMessageRecoveryHandler` - Works with `QueuedMessage` status tracking
4. `BLEStatisticsHandler` - Receives `RelayStatistics` callbacks

**Critical Alignment Points:**
- Use existing factory methods, not custom `create*` variants
- All RelayStatistics fields are required
- QueuedMessage has dual-queue routing via `isRelayMessage` flag
- MeshRelayMessage.nextHop() for chain progression
- RelayMetadata.create() + .nextHop() for metadata chain

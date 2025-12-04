# Mesh Networking Architecture

## Relay Decision Flow

```
Message Received
  ↓
Relay Enabled? → NO → Deliver locally only
  ↓ YES
Duplicate? (via SeenMessageStore) → YES → Drop
  ↓ NO
Already Delivered to Self? → NO → Deliver locally
  ↓
Find Route (SmartMeshRouter)
  ↓
Send to Next Hop(s)
```

**Key Components**:
- `MeshRelayEngine`: Core relay logic (`lib/core/messaging/mesh_relay_engine.dart`)
- `SmartMeshRouter`: Route optimization based on topology
- `NetworkTopologyAnalyzer`: Network size estimation
- `SeenMessageStore`: Duplicate detection (Message ID → timestamp)
- `SpamPreventionManager`: Flood protection

## Message ID Generation

```dart
// Unique and deduplicatable across relay hops
String messageId = base64Encode(
  sha256.convert(
    utf8.encode('$timestamp$senderKey$content')
  ).bytes
);
```

**Why SHA-256**: Ensures consistent IDs across devices without coordination.

## Key Service Classes

### MeshRelayEngine (Relay Orchestrator)

**Location**: `lib/core/messaging/mesh_relay_engine.dart`

**Responsibilities**: Relay decision logic, duplicate detection, route finding.

**Key Methods**:
- `processIncomingMessage(message)`: Main relay decision entry point
- `shouldRelay(message)`: Relay policy check
- `findBestRoute(targetKey)`: Route optimization

### OfflineMessageQueue (Message Persistence)

**Location**: `lib/core/messaging/offline_message_queue.dart`

**Responsibilities**: Queue messages for offline recipients, retry logic.

**Key Methods**:
- `enqueue(recipient, message)`: Add to queue
- `processQueue()`: Retry sending queued messages
- `dequeue(messageId)`: Remove after successful send

## Message Flow

### Sending a Message

```
1. User types in ChatScreen
   ↓
2. ChatScreen calls BLEService.sendMessage(recipient, content)
   ↓
3. BLEService → SecurityManager.encryptMessage(content, recipientKey)
   ↓
4. SecurityManager → NoiseSessionManager.getSession(recipientKey)
   ↓
5. NoiseSession.encryptMessage(plaintext) → ciphertext
   ↓
6. BLEService → MessageFragmenter.fragment(ciphertext) → chunks
   ↓
7. Send each chunk via BLE characteristic write
   ↓
8. If recipient offline → OfflineMessageQueue.enqueue()
```

### Receiving a Message

```
1. BLE characteristic notification received
   ↓
2. BLEMessageHandler.handleIncomingMessage(chunk)
   ↓
3. MessageFragmenter.reassemble(chunks) → complete ciphertext
   ↓
4. SecurityManager.decryptMessage(ciphertext, senderKey)
   ↓
5. NoiseSession.decryptMessage(ciphertext) → plaintext
   ↓
6. MeshRelayEngine.processIncomingMessage(message)
   ↓
7. If for me → Deliver to UI (via Provider/Stream)
   ↓
8. If relay enabled → Find route and forward
```

## Mesh Performance

- **Relay Limits**: Cap relay hops (max 3-5) to prevent network flooding
- **Duplicate Detection**: Use bloom filters for memory-efficient seen message tracking
- **Topology Updates**: Cache topology for 5-10 seconds, don't recalculate on every message

## Relay Invariants

1. **Message IDs MUST be deterministic** (same content → same ID across devices)
2. **Duplicate detection window = 5 minutes** (older messages re-relayed)
3. **Relay MUST deliver locally before forwarding** (prevent message loss)

## Known Mesh Limitations

- **Mesh Hops**: Max 3-5 hops before latency becomes noticeable

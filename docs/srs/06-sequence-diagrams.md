# Sequence Diagrams Context

This document provides structured context for generating sequence diagrams of key flows.

## Sequence Diagram 1: Send Message (Direct Delivery)

### Participants
- User
- ChatScreen (UI)
- MeshNetworkingService
- OfflineMessageQueue
- NoiseSessionManager
- BLEService
- Recipient

### Flow
```
1. User types message, taps Send
2. ChatScreen → MeshNetworkingService.sendMeshMessage(content, recipientKey)
3. MeshNetworkingService → Check if recipient directly connected
4. IF connected:
   5. MeshNetworkingService → OfflineMessageQueue.queueMessage(chatId, content, recipientKey)
   6. OfflineMessageQueue → Generate messageId (timestamp-based)
   7. OfflineMessageQueue → Save to queue (status: PENDING)
   8. OfflineMessageQueue → Trigger delivery
   9. OfflineMessageQueue → MeshNetworkingService._handleSendMessage(messageId)
   10. MeshNetworkingService → NoiseSessionManager.encrypt(plaintext, recipientKey)
   11. NoiseSessionManager → NoiseSession.encryptMessage(plaintext)
   12. NoiseSession → CipherState.encryptWithAd(plaintext, nonce)
   13. NoiseSession → Return ciphertext
   14. MeshNetworkingService → MessageFragmenter.fragment(ciphertext)
   15. MessageFragmenter → Split into chunks (if > MTU)
   16. MeshNetworkingService → BLEService.sendMessage(ciphertext)
   17. BLEService → Write to BLE characteristic
   18. BLEService → Recipient device
   19. OfflineMessageQueue → Mark messageId as DELIVERED
   20. OfflineMessageQueue → Save to MessageRepository
   21. ChatScreen ← Update UI (message sent)
```

### Mermaid Syntax
```mermaid
sequenceDiagram
    participant U as User
    participant CS as ChatScreen
    participant MNS as MeshNetworkingService
    participant Q as OfflineMessageQueue
    participant NSM as NoiseSessionManager
    participant BLE as BLEService
    participant R as Recipient

    U->>CS: Type message, tap Send
    CS->>MNS: sendMeshMessage(content, recipientKey)
    MNS->>MNS: Check if connected
    MNS->>Q: queueMessage(chatId, content, recipientKey)
    Q->>Q: Generate messageId
    Q->>Q: Save (status: PENDING)
    Q->>MNS: _handleSendMessage(messageId)
    MNS->>NSM: encrypt(plaintext, recipientKey)
    NSM->>NSM: NoiseSession.encryptMessage()
    NSM->>MNS: ciphertext
    MNS->>BLE: sendMessage(ciphertext)
    BLE->>R: BLE characteristic write
    Q->>Q: Mark DELIVERED
    CS->>CS: Update UI
```

## Sequence Diagram 2: Receive Message

### Participants
- Sender
- BLEService
- BLEMessageHandler
- MessageFragmenter
- NoiseSessionManager
- MeshRelayEngine
- MessageRepository
- ChatScreen

### Flow
```
1. Sender → BLEService (characteristic notification received)
2. BLEService → BLEMessageHandler.handleIncomingMessage(data)
3. BLEMessageHandler → Check if fragmented
4. IF fragmented:
   5. BLEMessageHandler → MessageFragmenter.addFragment(fragment)
   6. MessageFragmenter → Check if complete
   7. IF incomplete: Return (wait for more)
   8. IF complete: MessageFragmenter → Reassemble fragments
9. BLEMessageHandler → NoiseSessionManager.decrypt(ciphertext, senderKey)
10. NoiseSessionManager → NoiseSession.decryptMessage(ciphertext)
11. NoiseSession → CipherState.decryptWithAd(ciphertext, nonce)
12. NoiseSession → Verify MAC tag
13. NoiseSession → Return plaintext
14. BLEMessageHandler → MeshRelayEngine.processIncomingMessage(plaintext, senderKey)
15. MeshRelayEngine → Check if for current node
16. IF for self:
   17. MeshRelayEngine → MessageRepository.saveMessage(Message)
   18. MessageRepository → SQLite INSERT
   19. ChatScreen ← Notification (new message)
   20. ChatScreen ← Update UI
17. ELSE (relay):
   18. MeshRelayEngine → Check duplicate
   19. MeshRelayEngine → SmartMeshRouter.determineOptimalRoute()
   20. MeshRelayEngine → Queue for relay to next hop
```

### Mermaid Syntax
```mermaid
sequenceDiagram
    participant S as Sender
    participant BLE as BLEService
    participant MH as BLEMessageHandler
    participant MF as MessageFragmenter
    participant NSM as NoiseSessionManager
    participant MRE as MeshRelayEngine
    participant MR as MessageRepository
    participant CS as ChatScreen

    S->>BLE: BLE notification
    BLE->>MH: handleIncomingMessage(data)
    MH->>MF: addFragment(fragment)
    MF->>MF: Check complete
    MF-->>MH: Complete message
    MH->>NSM: decrypt(ciphertext, senderKey)
    NSM->>NSM: NoiseSession.decryptMessage()
    NSM-->>MH: plaintext
    MH->>MRE: processIncomingMessage(plaintext)
    MRE->>MRE: Check if for self
    alt Message for current node
        MRE->>MR: saveMessage(Message)
        MR->>MR: SQLite INSERT
        CS->>CS: Update UI
    else Relay required
        MRE->>MRE: Route to next hop
    end
```

## Sequence Diagram 3: Noise Handshake (XX Pattern)

### Participants
- Initiator (User A)
- Responder (User B)
- NoiseSessionManager (A)
- NoiseSessionManager (B)
- BLEService (A)
- BLEService (B)

### Flow
```
1. Initiator → NoiseSessionManager(A).initiateHandshake(peerID, pattern=XX)
2. NoiseSessionManager(A) → Create HandshakeState(XX, initiator=true)
3. HandshakeState(A) → Generate ephemeral keypair
4. HandshakeState(A) → WriteMessage() → e (32 bytes)
5. BLEService(A) → Send "e" to Responder
6. BLEService(B) → Receive "e"
7. NoiseSessionManager(B) → processHandshakeMessage(peerID, data)
8. HandshakeState(B) → ReadMessage(e)
9. HandshakeState(B) → Generate ephemeral keypair
10. HandshakeState(B) → WriteMessage() → e, ee, s, es (96 bytes)
11. BLEService(B) → Send "e, ee, s, es" to Initiator
12. BLEService(A) → Receive "e, ee, s, es"
13. HandshakeState(A) → ReadMessage(e, ee, s, es)
14. HandshakeState(A) → Extract remote static key
15. HandshakeState(A) → WriteMessage() → s, se (48 bytes)
16. BLEService(A) → Send "s, se" to Responder
17. BLEService(B) → Receive "s, se"
18. HandshakeState(B) → ReadMessage(s, se)
19. HandshakeState(B) → Extract remote static key
20. Both → Split() → Generate send/receive CipherStates
21. Both → Session established, ready for encryption
```

### Mermaid Syntax
```mermaid
sequenceDiagram
    participant A as User A (Initiator)
    participant NSM_A as NoiseSessionManager A
    participant BLE_A as BLEService A
    participant BLE_B as BLEService B
    participant NSM_B as NoiseSessionManager B
    participant B as User B (Responder)

    A->>NSM_A: initiateHandshake(B, XX)
    NSM_A->>NSM_A: Create HandshakeState(XX)
    NSM_A->>NSM_A: Generate ephemeral key
    NSM_A->>NSM_A: WriteMessage() → e
    NSM_A->>BLE_A: Send handshake msg 1 (32B)
    BLE_A->>BLE_B: e
    BLE_B->>NSM_B: processHandshakeMessage(e)
    NSM_B->>NSM_B: ReadMessage(e)
    NSM_B->>NSM_B: Generate ephemeral key
    NSM_B->>NSM_B: WriteMessage() → e,ee,s,es
    NSM_B->>BLE_B: Send handshake msg 2 (96B)
    BLE_B->>BLE_A: e,ee,s,es
    BLE_A->>NSM_A: processHandshakeMessage(e,ee,s,es)
    NSM_A->>NSM_A: ReadMessage(e,ee,s,es)
    NSM_A->>NSM_A: WriteMessage() → s,se
    NSM_A->>BLE_A: Send handshake msg 3 (48B)
    BLE_A->>BLE_B: s,se
    BLE_B->>NSM_B: processHandshakeMessage(s,se)
    NSM_B->>NSM_B: ReadMessage(s,se)
    NSM_B->>NSM_B: Split() → CipherStates
    NSM_A->>NSM_A: Split() → CipherStates
    Note over NSM_A,NSM_B: Session established
```

## Sequence Diagram 4: Mesh Relay (A→B→C)

### Participants
- Node A (Originator)
- Node B (Relay)
- Node C (Final Recipient)
- MeshRelayEngine (B)
- SmartMeshRouter (B)
- SeenMessageStore (B)

### Flow
```
1. Node A → Create message for Node C
2. Node A → Send to Node B (nearest hop)
3. Node B (BLEService) → Receive message
4. Node B → Decrypt with Noise session (A→B)
5. Node B → MeshRelayEngine.processIncomingMessage(message)
6. MeshRelayEngine → Extract relay metadata
7. MeshRelayEngine → Check finalRecipient != current node
8. MeshRelayEngine → SeenMessageStore.hasSeen(messageId)
9. IF seen: Drop (duplicate)
10. IF not seen:
   11. SeenMessageStore → markSeen(messageId, timestamp)
   12. MeshRelayEngine → Check hopCount < maxHops (5)
   13. MeshRelayEngine → SmartMeshRouter.determineOptimalRoute(C, availableHops)
   14. SmartMeshRouter → NetworkTopologyAnalyzer.estimateNetworkSize()
   15. SmartMeshRouter → ConnectionQualityMonitor.getQuality(C)
   16. SmartMeshRouter → RouteCalculator.calculateRoute()
   17. SmartMeshRouter → Return optimal next hop (Node C or intermediary)
   18. MeshRelayEngine → Increment hopCount
   19. MeshRelayEngine → Encrypt with Noise session (B→C or B→intermediary)
   20. MeshRelayEngine → BLEService.sendMessage(nextHop, ciphertext)
21. Node C → Receive message
22. Node C → Decrypt
23. Node C → MeshRelayEngine.processIncomingMessage()
24. MeshRelayEngine → Check finalRecipient == current node
25. MeshRelayEngine → Deliver to self (save to MessageRepository)
```

### Mermaid Syntax
```mermaid
sequenceDiagram
    participant A as Node A (Sender)
    participant B as Node B (Relay)
    participant MRE as MeshRelayEngine B
    participant SMS as SeenMessageStore B
    participant SMR as SmartMeshRouter B
    participant C as Node C (Recipient)

    A->>B: Send message (to C)
    B->>B: Decrypt (A→B session)
    B->>MRE: processIncomingMessage()
    MRE->>MRE: Extract relay metadata
    MRE->>SMS: hasSeen(messageId)?
    alt Not seen
        SMS->>SMS: markSeen(messageId)
        MRE->>MRE: Check hopCount < 5
        MRE->>SMR: determineOptimalRoute(C)
        SMR->>SMR: Analyze topology
        SMR-->>MRE: Next hop: C
        MRE->>MRE: Increment hopCount
        MRE->>B: Encrypt (B→C session)
        B->>C: Forward message
        C->>C: Decrypt
        C->>C: Deliver to self
    else Already seen
        MRE->>MRE: Drop (duplicate)
    end
```

## Sequence Diagram 5: Offline Message Queue

### Participants
- User
- ChatScreen
- MeshNetworkingService
- OfflineMessageQueue
- BLEService (offline)
- BLEService (comes online)
- Recipient

### Flow
```
1. User → Send message to offline recipient
2. ChatScreen → MeshNetworkingService.sendMeshMessage()
3. MeshNetworkingService → Check if recipient connected
4. IF offline:
   5. MeshNetworkingService → OfflineMessageQueue.queueMessage()
   6. OfflineMessageQueue → Save to offline_message_queue table (status: PENDING)
   7. OfflineMessageQueue → Set nextRetryAt = now + backoff
   8. ChatScreen ← Status: "Queued for delivery"
9. [TIME PASSES - Retry attempts]
10. OfflineMessageQueue → Periodic check (every 30s)
11. OfflineMessageQueue → Check nextRetryAt <= now
12. OfflineMessageQueue → Attempt send via BLEService
13. IF still offline:
   14. OfflineMessageQueue → Increment retryCount
   15. OfflineMessageQueue → Calculate exponential backoff
   16. OfflineMessageQueue → Set nextRetryAt = now + backoff
   17. IF retryCount > maxRetries:
      18. OfflineMessageQueue → Mark status: FAILED
19. [RECIPIENT COMES ONLINE]
20. BLEService → Connection established event
21. BLEService → MeshNetworkingService._handleConnectionChange(deviceId)
22. MeshNetworkingService → _deliverQueuedMessagesToDevice(deviceId)
23. MeshNetworkingService → Get messages for deviceId (status: PENDING/RETRYING)
24. FOR EACH message:
   25. MeshNetworkingService → _handleSendMessage(messageId)
   26. Encrypt → Send via BLE → Mark DELIVERED
27. ChatScreen ← Status: "Delivered"
```

### Mermaid Syntax
```mermaid
sequenceDiagram
    participant U as User
    participant CS as ChatScreen
    participant MNS as MeshNetworkingService
    participant Q as OfflineMessageQueue
    participant BLE as BLEService

    U->>CS: Send message
    CS->>MNS: sendMeshMessage()
    MNS->>MNS: Check if recipient online
    alt Recipient Offline
        MNS->>Q: queueMessage()
        Q->>Q: Save (PENDING)
        Q->>Q: Set nextRetryAt
        CS-->>U: Status: Queued
        loop Retry Loop
            Q->>Q: Periodic check
            Q->>BLE: Attempt send
            BLE-->>Q: Still offline
            Q->>Q: Increment retryCount
            Q->>Q: Exponential backoff
        end
    end
    Note over BLE: Recipient comes online
    BLE->>MNS: Connection event
    MNS->>Q: Get pending messages
    loop For each message
        Q->>BLE: Send message
        BLE-->>Q: Success
        Q->>Q: Mark DELIVERED
    end
    CS-->>U: Status: Delivered
```

## Sequence Diagram 6: Database Migration

### Participants
- App Startup
- DatabaseHelper
- SharedPreferences
- SQLite Database
- MigrationService

### Flow
```
1. App Startup → DatabaseHelper.database (first access)
2. DatabaseHelper → Check if database exists
3. IF exists:
   4. DatabaseHelper → Open database
   5. DatabaseHelper → Check current version
   6. IF version < latest (9):
      7. DatabaseHelper → _onUpgrade(db, oldVersion, newVersion)
      8. FOR EACH version upgrade (e.g., v7 → v8 → v9):
         9. Apply migration SQL (ALTER TABLE, CREATE INDEX, etc.)
         10. Log migration completion
   11. DatabaseHelper → Set new version
12. IF not exists:
   13. DatabaseHelper → _onCreate(db, version=9)
   14. Create all 17 tables + indexes + FTS5
15. DatabaseHelper → Enable foreign keys (PRAGMA)
16. DatabaseHelper → Enable WAL mode (PRAGMA)
17. [OPTIONAL: SharedPreferences → SQLite migration]
18. IF migration needed:
   19. MigrationService → Check migration_metadata table
   20. IF not migrated:
      21. MigrationService → Read SharedPreferences data
      22. MigrationService → Convert to SQLite format
      23. MigrationService → Insert into tables
      24. MigrationService → Verify checksums
      25. MigrationService → Mark migration complete
26. DatabaseHelper → Return database instance
```

### Mermaid Syntax
```mermaid
sequenceDiagram
    participant App as App Startup
    participant DH as DatabaseHelper
    participant SP as SharedPreferences
    participant DB as SQLite Database
    participant MS as MigrationService

    App->>DH: Get database instance
    DH->>DH: Check if exists
    alt Database Exists
        DH->>DB: Open database
        DH->>DB: Check version
        alt Version < 9
            DH->>DH: _onUpgrade(old, new)
            loop For each version
                DH->>DB: Apply migration SQL
            end
            DH->>DB: Set version = 9
        end
    else New Database
        DH->>DB: _onCreate(version=9)
        DH->>DB: Create 17 tables + FTS5
    end
    DH->>DB: PRAGMA foreign_keys=ON
    DH->>DB: PRAGMA journal_mode=WAL
    opt SharedPreferences Migration
        DH->>MS: Check if migration needed
        MS->>SP: Read old data
        MS->>DB: Insert into SQLite
        MS->>MS: Verify checksums
    end
    DH-->>App: Database ready
```

---

**Total Sequence Diagrams**: 6 key flows
**Last Updated**: 2025-01-19

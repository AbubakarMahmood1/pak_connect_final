# Expanded Use Cases

Detailed use case specifications with full template format.

---

## UC-1: Send Message

### Basic Information
**Use Case ID**: UC-1
**Use Case Name**: Send Message
**Created By**: System Analysis
**Date Created**: 2025-01-19
**Actor**: User (Primary), BLE System (Supporting)
**Stakeholders**: User (wants reliable message delivery), Recipient (wants to receive messages)
**Preconditions**:
- User is logged into the app
- Contact exists in contact list
- Noise session established with contact OR contact is offline (will queue)
- BLE adapter is available

**Postconditions**:
- Success: Message encrypted, sent/queued, status updated
- Failure: Error message displayed, message remains in draft

### Main Success Scenario
1. User opens chat with contact
2. User types message in text field
3. User taps Send button
4. System validates message (not empty)
5. System generates message ID (timestamp + hash)
6. System checks if recipient is connected
7. System retrieves Noise session for recipient
8. System encrypts message with ChaCha20-Poly1305
9. System fragments message if size > MTU
10. System sends fragments via BLE characteristic writes
11. System marks message as "Sending..."
12. System receives delivery confirmation
13. System updates message status to "Delivered"
14. System saves message to repository
15. UI updates to show delivered checkmark

**Result**: Message successfully delivered to recipient

### Extensions (Alternative Flows)

**6a. Recipient is offline**
- 6a1. System queues message in offline_message_queue
- 6a2. System sets status to "Queued"
- 6a3. System calculates nextRetryAt with exponential backoff
- 6a4. System displays "Queued for delivery" in UI
- 6a5. Use case continues at step 14 (save to repository)
- 6a6. Background process monitors for reconnection (see UC-3)

**7a. No Noise session exists**
- 7a1. System initiates handshake (see UC-8)
- 7a2. If handshake succeeds, continue at step 8
- 7a3. If handshake fails, display error "Failed to establish secure connection"
- 7a4. Use case ends in failure

**8a. Encryption fails**
- 8a1. Log error with details
- 8a2. Display "Encryption failed" error
- 8a3. Use case ends in failure

**10a. BLE transmission fails**
- 10a1. System marks message status as "Failed to send"
- 10a2. System moves message to retry queue
- 10a3. System schedules retry with backoff
- 10a4. Use case continues at background retry

**12a. No delivery confirmation (timeout)**
- 12a1. System marks message as "Sent" (not "Delivered")
- 12a2. System waits for delivery receipt (future enhancement)
- 12a3. Use case ends

### Special Requirements
- **Performance**: Message encryption < 50ms
- **Performance**: BLE transmission < 200ms per fragment
- **Security**: Must use established Noise session (no plaintext)
- **Reliability**: Messages must persist in queue if offline
- **Usability**: UI must show real-time status updates

### Technology & Data Variations
**Channel**: Bluetooth Low Energy (GATT)
**Encryption**: ChaCha20-Poly1305 AEAD
**Fragmentation**: MTU-based (typically 160-220 bytes)
**Storage**: SQLite (messages table + offline_message_queue table)

### Frequency of Use
**Expected**: 10-100 messages per day per user

### Open Issues
- Delivery receipts not yet implemented (message status stops at "Sent")
- Read receipts planned for future version
- Typing indicators not implemented

---

## UC-7: Add Contact via QR

### Basic Information
**Use Case ID**: UC-7
**Use Case Name**: Add Contact via QR Code
**Created By**: System Analysis
**Date Created**: 2025-01-19
**Actor**: User (Primary), BLE System (Supporting)
**Stakeholders**: User (wants easy contact addition), Contact being added (wants secure pairing)
**Preconditions**:
- User has camera permission
- User is on Add Contact screen
- Remote contact is advertising via BLE
- Remote contact is displaying QR code

**Postconditions**:
- Success: Contact saved with established Noise session, ready for messaging
- Failure: Error displayed, no contact saved

### Main Success Scenario
1. User taps "Add Contact" button
2. System opens QR scanner
3. User points camera at contact's QR code
4. System scans and decodes QR data
5. System parses QR payload (publicKey, ephemeralId, displayName, noisePublicKey)
6. System validates QR format and data integrity
7. System checks if contact already exists (by publicKey)
8. System initiates BLE scan for ephemeralId
9. System finds advertised device matching ephemeralId
10. System connects to device
11. System negotiates MTU (512 bytes requested)
12. System initiates Noise XX handshake (see UC-8)
13. Handshake completes successfully
14. System saves contact to database (contacts table)
15. System saves Noise session state
16. System displays "Contact added successfully"
17. UI navigates to chat with new contact

**Result**: Contact successfully added and ready for encrypted messaging

### Extensions (Alternative Flows)

**4a. QR scan fails**
- 4a1. Display "Unable to read QR code"
- 4a2. Return to step 3 (allow retry)

**6a. Invalid QR format**
- 6a1. Display "Invalid QR code format"
- 6a2. Use case ends in failure

**7a. Contact already exists**
- 7a1. Display "Contact already in your list"
- 7a2. Ask user: "Update existing contact?"
- 7a3. If yes, continue at step 8 (re-establish session)
- 7a4. If no, use case ends

**8a. Device not found via BLE**
- 8a1. Display "Contact not found nearby"
- 8a2. Suggest: "Make sure contact is on Add Contact screen"
- 8a3. Offer retry button
- 8a4. Use case ends or retry from step 8

**10a. Connection fails**
- 10a1. Log BLE connection error
- 10a2. Display "Failed to connect to contact"
- 10a3. Retry up to 3 times
- 10a4. If all retries fail, use case ends in failure

**12a. Handshake fails**
- 12a1. Display "Handshake failed - please try again"
- 12a2. Disconnect BLE
- 12a3. Use case ends in failure

### Special Requirements
- **Security**: Must use Noise XX pattern (mutual authentication)
- **Performance**: QR scan + handshake should complete < 10 seconds
- **Usability**: Clear error messages for each failure point
- **Privacy**: Ephemeral IDs used in QR to avoid tracking

### Technology & Data Variations
**QR Format**: JSON encoded as Base64
**QR Content**: `{publicKey, ephemeralId, displayName, noisePublicKey}`
**Handshake Pattern**: Noise XX (3 messages, 176 bytes total)
**Storage**: contacts table with security_level=0 (LOW)

### Frequency of Use
**Expected**: 1-10 times per user (initial setup + occasional new contacts)

### Open Issues
- QR code expiry not implemented (ephemeral IDs should rotate)
- Distance-based pairing security not enforced
- Group QR codes for multi-user events not supported

---

## UC-23: Send Group Message

### Basic Information
**Use Case ID**: UC-23
**Use Case Name**: Send Group Message
**Created By**: System Analysis
**Date Created**: 2025-01-19
**Actor**: User (Primary)
**Stakeholders**: User (wants to message multiple people), Group members (want to receive messages)
**Preconditions**:
- User has created a group
- Group has at least 1 member
- User has Noise sessions established with members OR members are offline (will queue)

**Postconditions**:
- Success: Individual encrypted messages sent/queued for each member
- Failure: Partial success (some members receive, others fail)

### Main Success Scenario
1. User selects group from chat list
2. User types message in group chat
3. User taps Send button
4. System validates message (not empty)
5. System generates unique message ID
6. System retrieves group members list from group_members table
7. System creates GroupMessage record with initial delivery status
8. FOR EACH member in group:
   9. System retrieves member's contact record
   10. System generates chat ID for member
   11. System queues individual message via OfflineMessageQueue
   12. System encrypts with member's Noise session
   13. System sends via BLE OR queues if offline
   14. System updates delivery status for member (pending → sent)
15. System saves GroupMessage to group_messages table
16. System saves delivery records to group_message_delivery table
17. UI displays message with per-member delivery indicators
18. Background process monitors delivery confirmations

**Result**: Message sent to all group members with individual delivery tracking

### Extensions (Alternative Flows)

**6a. Group has no members**
- 6a1. Display "Cannot send to empty group"
- 6a2. Suggest "Add members to group first"
- 6a3. Use case ends

**9a. Member contact not found**
- 9a1. Log warning "Member not in contacts"
- 9a2. Mark delivery status as "failed" for that member
- 9a3. Continue with next member

**12a. No Noise session for member**
- 12a1. Attempt handshake with member
- 12a2. If handshake fails, mark status as "failed"
- 12a3. Continue with next member

**13a. Member is offline**
- 13a1. Message queued in offline_message_queue
- 13a2. Mark status as "queued"
- 13a3. Continue with next member

**13b. Send fails for member**
- 13b1. Log error for that member
- 13b2. Mark status as "failed"
- 13b3. Continue with next member (partial success allowed)

### Special Requirements
- **Security**: Each member receives individually encrypted message (multi-unicast, not broadcast)
- **Performance**: Should handle groups of up to 50 members
- **Reliability**: Partial success acceptable (some deliver, some fail)
- **Usability**: Clear per-member delivery status visualization

### Technology & Data Variations
**Architecture**: Multi-unicast (N individual Noise sessions)
**No Shared Keys**: Each message encrypted separately per recipient
**Storage**: group_messages + group_message_delivery (junction table)
**Delivery Tracking**: Per-member status (pending, sent, delivered, failed)

### Frequency of Use
**Expected**: 1-20 group messages per day (depending on group activity)

### Open Issues
- Group size limit not enforced (performance degrades > 50 members)
- Group message editing not supported
- Group delivery receipts aggregate view not implemented
- Group admin/permissions system not implemented

---

## UC-31: Process Incoming Relay Message

### Basic Information
**Use Case ID**: UC-31
**Use Case Name**: Process Incoming Relay Message
**Created By**: System Analysis
**Date Created**: 2025-01-19
**Actor**: System (Automated)
**Stakeholders**: Message originator (wants delivery), Final recipient (wants to receive)
**Preconditions**:
- Device is acting as mesh relay node
- Relay feature is enabled in settings
- BLE connection active with sender
- Noise session established with sender

**Postconditions**:
- Success: Message delivered to self OR forwarded to next hop
- Failure: Message dropped (duplicate, spam, or hop limit exceeded)

### Main Success Scenario
1. System receives BLE characteristic notification
2. System passes data to BLEMessageHandler
3. System reassembles fragments (if fragmented)
4. System decrypts using sender's Noise session
5. System extracts MeshRelayMetadata from message
6. System parses: originalMessageId, finalRecipient, originalSender, hopCount
7. System checks if finalRecipient == current node's publicKey
8. IF NOT for self, proceed to relay decision:
   9. System queries SeenMessageStore with messageId
   10. IF message not seen before:
      11. System marks message as seen (timestamp)
      12. System checks hopCount < maxHops (5)
      13. System queries SpamPreventionManager
      14. System calls SmartMeshRouter.determineOptimalRoute()
      15. System gets list of available next hops (connected devices)
      16. Router analyzes topology and connection quality
      17. Router returns optimal next hop
      18. System increments hopCount
      19. System re-encrypts for next hop's Noise session
      20. System sends to next hop via BLE
      21. System logs relay statistics
9. IF for self:
   22. System extracts original content
   23. System generates chat ID from originalSender
   24. System creates Message record (isFromMe=false)
   25. System saves to MessageRepository
   26. System triggers notification
   27. System updates UI

**Result**: Message successfully relayed or delivered

### Extensions (Alternative Flows)

**5a. Invalid relay metadata**
- 5a1. Log "Invalid relay message format"
- 5a2. Drop message
- 5a3. Use case ends

**9a. Message already seen (duplicate)**
- 9a1. Log "Duplicate relay message blocked"
- 9a2. Increment duplicate count in statistics
- 9a3. Drop message
- 9a4. Use case ends

**12a. Hop count >= maxHops**
- 12a1. Log "Hop limit exceeded, dropping message"
- 12a2. Update relay statistics
- 12a3. Drop message
- 12a4. Use case ends

**13a. Spam check fails**
- 13a1. Log "Spam prevention blocked relay"
- 13a2. Increment spam block count
- 13a3. Drop message
- 13a4. Use case ends

**14a. No next hops available**
- 14a1. Log "No route to destination"
- 14a2. Keep message in buffer (may retry later)
- 14a3. Use case ends

**19a. Re-encryption fails**
- 19a1. Log "Failed to encrypt for next hop"
- 19a2. Drop message
- 19a3. Use case ends

**20a. BLE send fails**
- 20a1. Log "Failed to forward to next hop"
- 20a2. May queue for retry
- 20a3. Use case ends

### Special Requirements
- **Performance**: Relay decision < 100ms
- **Security**: Must verify MAC before relaying (prevent forgery)
- **Reliability**: Duplicate detection window = 5 minutes
- **Scalability**: Should handle network of 50-100 nodes

### Technology & Data Variations
**Duplicate Detection**: In-memory SeenMessageStore (5-minute TTL)
**Routing**: SmartMeshRouter with topology analysis
**Hop Limit**: Configurable (default 5)
**Storage**: Relay statistics logged, but messages not stored unless for self

### Frequency of Use
**Expected**: 0-50 relay decisions per hour (depending on network activity)

### Open Issues
- Route caching not implemented (recalculate every message)
- Mesh network size estimation inaccurate
- No mechanism to report delivery confirmation back to originator
- SeenMessageStore not persisted (lost on app restart)

---

## UC-8: Perform Noise Handshake (XX Pattern)

### Basic Information
**Use Case ID**: UC-8
**Use Case Name**: Perform Noise Handshake (XX Pattern)
**Created By**: System Analysis
**Date Created**: 2025-01-19
**Actor**: System (Automated, triggered by UC-7 or connection event)
**Stakeholders**: Both users (want secure communication)
**Preconditions**:
- BLE connection established
- MTU negotiated
- Both devices have static identity keys
- This is first contact (no pre-shared keys)

**Postconditions**:
- Success: Mutual authentication complete, CipherStates established
- Failure: Session removed, handshake must restart

### Main Success Scenario

**Initiator (Device A) Actions:**
1. System creates HandshakeState(pattern=XX, initiator=true)
2. System generates ephemeral keypair (e)
3. System calls WriteMessage() → produces 32-byte message containing e
4. System sends message 1 to Responder via BLE
5. System receives message 2 from Responder (96 bytes)
6. System calls ReadMessage(msg2)
7. System extracts: remote ephemeral key, remote static key
8. System performs DH operations: ee, es
9. System calls WriteMessage() → produces 48-byte message containing s, se
10. System sends message 3 to Responder
11. System calls Split() → generates send and receive CipherStates
12. System transitions to ESTABLISHED state
13. System saves remote static public key
14. System saves session to contacts.noise_session_state

**Responder (Device B) Actions:**
1. System receives message 1 from Initiator (32 bytes)
2. System creates HandshakeState(pattern=XX, initiator=false)
3. System calls ReadMessage(msg1)
4. System extracts: remote ephemeral key
5. System generates ephemeral keypair (e)
6. System performs DH operations: ee, se
7. System calls WriteMessage() → produces 96-byte message containing e, s
8. System sends message 2 to Initiator
9. System receives message 3 from Initiator (48 bytes)
10. System calls ReadMessage(msg3)
11. System extracts: remote static key
12. System performs DH operation: se
13. System calls Split() → generates send and receive CipherStates
14. System transitions to ESTABLISHED state
15. System saves remote static public key
16. System saves session to contacts.noise_session_state

**Result**: Both devices have established encrypted session with mutual authentication

### Extensions (Alternative Flows)

**4a. Message 1 send fails**
- 4a1. Retry up to 3 times
- 4a2. If all fail, abort handshake
- 4a3. Notify user "Connection failed"

**6a. Message 2 receive timeout (> 5 seconds)**
- 6a1. Abort handshake
- 6a2. Log "Handshake timeout"
- 6a3. Use case ends in failure

**7a. MAC verification fails on message 2**
- 7a1. Log "Invalid handshake message"
- 7a2. Abort handshake
- 7a3. Use case ends in failure

**10a. MAC verification fails on message 3**
- 10a1. Log "Invalid handshake message"
- 10a2. Abort handshake
- 10a3. Use case ends in failure

**General: BLE disconnection during handshake**
- G1. Abort handshake immediately
- G2. Clean up HandshakeState
- G3. Use case ends in failure

### Special Requirements
- **Security**: Full Noise Protocol XX spec compliance (Revision 34)
- **Performance**: Complete handshake < 2 seconds
- **Cryptography**: X25519 DH, ChaCha20-Poly1305 AEAD, SHA-256
- **Reliability**: Must handle out-of-order messages (reject)

### Technology & Data Variations
**DH Algorithm**: X25519 (pinenacl package)
**Symmetric Cipher**: ChaCha20-Poly1305 (cryptography package)
**Hash**: SHA-256 (crypto package)
**Message Sizes**:
- Message 1: 32 bytes (ephemeral public key only)
- Message 2: 96 bytes (ephemeral + static keys, encrypted)
- Message 3: 48 bytes (static key, encrypted)

### Frequency of Use
**Expected**: 1-3 times per contact (initial pairing + periodic rekey)

### Open Issues
- No mechanism to resume failed handshake mid-stream
- Handshake timeout not configurable
- No fallback to KK pattern if static keys already known

---

**Total Expanded Use Cases**: 5 critical flows (representative sample)
**Format**: Full use case template with all sections
**Last Updated**: 2025-01-19

**Note**: Remaining 31 use cases follow same template structure. These 5 represent the most architecturally significant flows for your documentation.

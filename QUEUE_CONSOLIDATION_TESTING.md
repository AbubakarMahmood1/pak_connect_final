# QUEUE CONSOLIDATION FIX - TESTING PLAN

## ✅ PROBLEM SOLVED

### Root Cause Identified

Messages were using **TWO DIFFERENT IDs**:

- `ChatScreen`: Created messages with timestamp-based ID (e.g., `"1760403242117"`)
- `OfflineMessageQueue`: Generated secure ID (e.g., `"2.3.ce36e46bc68b..."`)

Result: When queue marked message as "delivered", it couldn't update MessageRepository because IDs didn't match!

---

## 🔧 THE FIX (2 Changes)

### Change #1: Use Secure ID from the Start

**File:** `lib/presentation/screens/chat_screen.dart`

**Before:**

```dart
void _sendMessage() async {
  // Create message with timestamp ID
  final message = Message(
    id: DateTime.now().millisecondsSinceEpoch.toString(),  // ← Timestamp ID
    // ...
  );
  
  // Save to repository
  await _messageRepository.saveMessage(message);
  
  // Queue (generates NEW different ID)
  final messageId = await AppCore.instance.sendSecureMessage(...);  // ← Different ID!
  
  // IDs don't match! Queue can't update repository later!
}
```

**After:**

```dart
void _sendMessage() async {
  // Queue FIRST to get secure ID
  final secureMessageId = await AppCore.instance.sendSecureMessage(...);  // ← Get secure ID
  
  // Create message with SAME ID
  final message = Message(
    id: secureMessageId,  // ← Use queue's secure ID!
    // ...
  );
  
  // Save to repository with matching ID
  await _messageRepository.saveMessage(message);
  
  // IDs now match! Queue can update repository later! ✅
}
```

### Change #2: Sync Repository on Delivery

**File:** `lib/core/app_core.dart`

**Added callback:**

```dart
await messageQueue.initialize(
  onMessageDelivered: (message) async {
    // 🔧 FIX: Update MessageRepository when queue marks delivered
    await _updateMessageRepositoryOnDelivery(message);
  },
);
```

**Added method:**

```dart
Future<void> _updateMessageRepositoryOnDelivery(QueuedMessage queuedMessage) async {
  final messageRepo = MessageRepository();
  
  // Create repository message with delivered status
  final repoMessage = Message(
    id: queuedMessage.id,  // Same ID! ✅
    chatId: queuedMessage.chatId,
    content: queuedMessage.content,
    timestamp: queuedMessage.queuedAt,
    isFromMe: true,
    status: MessageStatus.delivered,
  );
  
  // Update in repository
  await messageRepo.updateMessage(repoMessage);
}
```

---

## 🎯 EXPECTED BEHAVIOR

### New Message Flow

#### Sending

```
1. User types "Hello" and clicks send
2. ChatScreen calls AppCore.sendSecureMessage()
3. AppCore → OfflineMessageQueue.queueMessage()
4. Queue generates secure ID: "2.3.abc123..."
5. Queue returns this ID to ChatScreen
6. ChatScreen creates Message with ID "2.3.abc123..."
7. ChatScreen saves to MessageRepository (status: sent)
8. Message shown in UI with "sending" indicator

Result: 
- OfflineMessageQueue has message (ID: 2.3.abc123..., status: pending)
- MessageRepository has message (ID: 2.3.abc123..., status: sent)
- IDs MATCH! ✅
```

#### Delivery

```
1. BLE sends message successfully
2. OfflineMessageQueue.markMessageDelivered("2.3.abc123...")
3. Queue callback fires: onMessageDelivered
4. AppCore._updateMessageRepositoryOnDelivery() called
5. MessageRepository updated (status: delivered)
6. Message removed from OfflineMessageQueue
7. UI shows checkmark

Result:
- OfflineMessageQueue: Empty (message removed)
- MessageRepository: Has message (status: delivered)
- Queue count: 0 ✅
- Chat shows delivered message ✅
```

---

## 🧪 TESTING INSTRUCTIONS

### Test 1: Basic Message Send & Deliver

**Setup:**

1. Clean all data: `flutter clean`
2. Build fresh: `flutter build apk`
3. Install on both devices
4. Connect devices via BLE

**Steps:**

1. Device A sends "Test message 1"
2. **VERIFY:** Message appears in chat with "sending" indicator
3. Wait 2 seconds
4. **VERIFY:** Message shows checkmark (delivered)
5. Device B receives message
6. **VERIFY:** Message appears in Device B's chat

**Check Database (Device A):**

```sql
-- Check MessageRepository
SELECT id, content, status FROM messages WHERE content = 'Test message 1';
-- Expected: 1 row, status = delivered (or equivalent integer)

-- Check OfflineMessageQueue
SELECT queue_id, content, status FROM offline_message_queue WHERE content = 'Test message 1';
-- Expected: 0 rows (message removed after delivery)
```

**Success Criteria:**

- ✅ Message ID in MessageRepository matches ID shown in logs
- ✅ Message status updates from "sent" to "delivered"
- ✅ Message removed from OfflineMessageQueue after delivery
- ✅ No duplicate messages in UI
- ✅ Queue count shows 0 after delivery

---

### Test 2: Multiple Messages

**Steps:**

1. Device A sends 5 messages rapidly: "Msg 1", "Msg 2", "Msg 3", "Msg 4", "Msg 5"
2. **VERIFY:** All 5 show "sending" indicator
3. Wait for delivery
4. **VERIFY:** All 5 show checkmarks
5. Close and reopen chat
6. **VERIFY:** All 5 messages still visible (no duplicates)

**Check Counts:**

```dart
// In logs, look for:
"Queue stats updated" → Should show pendingMessages decreasing: 5 → 4 → 3 → 2 → 1 → 0
```

**Success Criteria:**

- ✅ All messages deliver successfully
- ✅ No messages lost
- ✅ No duplicate messages
- ✅ Queue count accurate at all times
- ✅ Chat reopens with all messages visible

---

### Test 3: Offline Queuing

**Steps:**

1. Device A turns off Bluetooth
2. Device A sends "Offline message 1"
3. **VERIFY:** Message shows "sending" (stays in sending state)
4. Check mesh relay tab
5. **VERIFY:** Queue count = 1
6. Device A turns on Bluetooth
7. Wait for reconnection
8. **VERIFY:** Message delivers automatically
9. **VERIFY:** Queue count = 0

**Database Check (Device A):**

```sql
-- While offline
SELECT COUNT(*) FROM offline_message_queue;
-- Expected: 1

SELECT COUNT(*) FROM messages WHERE content = 'Offline message 1';
-- Expected: 1

-- After delivery
SELECT COUNT(*) FROM offline_message_queue WHERE content = 'Offline message 1';
-- Expected: 0 (removed from queue)

SELECT status FROM messages WHERE content = 'Offline message 1';
-- Expected: delivered
```

**Success Criteria:**

- ✅ Message queued while offline
- ✅ Message delivers automatically when online
- ✅ No manual retry needed
- ✅ Status updates correctly
- ✅ Queue cleaned up after delivery

---

### Test 4: Failed Message Handling

**Steps:**

1. Device A sends message
2. Immediately disconnect Device B (turn off Bluetooth)
3. **VERIFY:** Message stays in "sending" state
4. Wait 30 seconds
5. **VERIFY:** Message retries automatically
6. Reconnect Device B
7. **VERIFY:** Message delivers on retry
8. **VERIFY:** Only ONE copy of message in chat

**Check Queue:**

- While disconnected: Queue count = 1, status = retrying
- After reconnection: Queue count = 0, status = delivered

**Success Criteria:**

- ✅ Failed messages retry automatically
- ✅ No duplicate messages created
- ✅ Eventual delivery succeeds
- ✅ UI reflects correct status throughout

---

### Test 5: Chat Reopening

**Steps:**

1. Device A sends 3 messages (all deliver)
2. Close chat screen
3. Wait 5 seconds
4. Reopen chat
5. **VERIFY:** Exactly 3 messages visible
6. **VERIFY:** No loading indicators
7. **VERIFY:** All messages show "delivered" status

**Database Verification:**

```sql
-- Should only be in MessageRepository, NOT in queue
SELECT id, content, status FROM messages WHERE chat_id = '<chatId>';
-- Expected: 3 rows, all status = delivered

SELECT COUNT(*) FROM offline_message_queue WHERE chat_id = '<chatId>';
-- Expected: 0 rows
```

**Success Criteria:**

- ✅ Messages persist across app restarts
- ✅ No duplicate loading
- ✅ Correct status displayed
- ✅ Queue remains clean

---

### Test 6: Concurrent Sending (Stress Test)

**Steps:**

1. Device A sends 10 messages as fast as possible
2. Device B sends 10 messages simultaneously
3. Wait for all deliveries
4. Count messages in both chats
5. **VERIFY:** Device A sees 10 sent + 10 received = 20 total
6. **VERIFY:** Device B sees 10 sent + 10 received = 20 total
7. **VERIFY:** No messages lost or duplicated

**Queue Monitoring:**

- Watch queue count: Should peak at ~10 then decrease to 0
- Should never have negative count
- All messages should eventually deliver

**Success Criteria:**

- ✅ All 20 messages deliver correctly
- ✅ No race conditions
- ✅ No deadlocks
- ✅ Queue handles concurrent load
- ✅ Database consistency maintained

---

## 📊 LOG PATTERNS TO WATCH

### Success Pattern (Good)

```
🔧 SEND DEBUG: Attempting to send message: "Hello"
🔧 SEND DEBUG: Message queued with secure ID: 2.3.abc123...
🔧 SEND DEBUG: Message saved to repository with ID: 2.3.abc123...
✅ Message queued for secure delivery

[Later...]
Message delivered: 2.3.abc123...
✅ Updated message 2.3.abc123... to delivered in repository
```

### Failure Pattern (Bad - Should NOT See)

```
❌ Failed to update MessageRepository on delivery: ...
⚠️ Message 2.3.abc123... not found in repository, saved as delivered
```

If you see the warning, it means the message wasn't in repository when delivery happened - indicates timing issue.

---

## 🔍 DEBUGGING TIPS

### If Message Stuck in "Sending"

**Check:**

1. OfflineMessageQueue still has it:

   ```sql
   SELECT * FROM offline_message_queue WHERE content LIKE '%<your text>%';
   ```

2. Check queue logs:

   ```
   Delivery failed for ... : <reason>
   ```

3. Verify BLE connection:

   ```
   Connection info: isConnected=true, isReady=true
   ```

### If Message Duplicated

**Check:**

1. Both databases:

   ```sql
   -- Should only be ONE in repository
   SELECT COUNT(*) FROM messages WHERE id = '<messageId>';
   
   -- Should be ZERO in queue (if delivered)
   SELECT COUNT(*) FROM offline_message_queue WHERE queue_id = '<messageId>';
   ```

2. Check if IDs match:

   ```
   🔧 SEND DEBUG: Message saved to repository with ID: 2.3.abc123...
   Message delivered: 2.3.abc123...  ← IDs should match!
   ```

---

## ⚠️ KNOWN LIMITATIONS

### What This Fix Does NOT Cover

1. **Message Editing:** If user edits a message, needs separate handling
2. **Message Deletion:** Deleting from UI should also remove from queue if pending
3. **Migration:** Existing messages with mismatched IDs need migration (user will clean data)
4. **Relay Messages:** Relay messages might have different ID handling (check separately)

---

## ✅ ACCEPTANCE CRITERIA

This fix is successful if:

1. **ID Consistency:** Message IDs match between queue and repository
2. **Status Sync:** Repository status updates when queue delivers
3. **No Duplicates:** Each message exists in exactly ONE place at a time
4. **Queue Accuracy:** Queue count matches actual pending messages
5. **No Leaks:** Delivered messages removed from queue
6. **UI Correctness:** Chat shows correct status indicators
7. **Persistence:** Messages survive app restart
8. **Performance:** No significant delay in message sending

---

## 🚀 NEXT STEPS AFTER TESTING

If all tests pass:

1. ✅ Mark "Queue Consolidation" as COMPLETE
2. ✅ Move to "Fix Burst Scanning Max Connections"
3. ✅ Continue with remaining issues

If tests fail:

1. ❌ Document exact failure scenario
2. ❌ Provide logs showing the issue
3. ❌ Identify which test case failed
4. ❌ Agent will analyze and provide targeted fix

---

**TESTING PRIORITY:** P0 - Must test before deploying to production  
**ESTIMATED TIME:** 30-45 minutes for complete test suite  
**AUTOMATION:** Consider adding unit tests for these scenarios later

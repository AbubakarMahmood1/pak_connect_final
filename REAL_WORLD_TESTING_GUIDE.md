# Real-World Testing Guide - Multi-Device Validation

**Purpose**: Test the app on real devices to validate logic assumptions made in unit tests.

**Goal**: Determine what ACTUALLY happens vs. what we THINK should happen, then fix code or tests accordingly.

---

## 📱 Required Setup

### Devices Needed
- **Minimum**: 2 Android/iOS devices with BLE
- **Recommended**: 3 devices (for mesh relay testing)
- **Naming**: Device A, Device B, Device C

### Before Starting
1. ✅ Install app on all devices
2. ✅ Enable Bluetooth on all devices
3. ✅ Grant all permissions (Bluetooth, storage, notifications)
4. ✅ Have notebook/document ready to record results
5. ✅ Take screenshots of failures

---

## 🎯 Testing Methodology

### For Each Test Scenario:

**Step 1: Record Expected Behavior** (from this guide)
**Step 2: Perform Test** (follow steps)
**Step 3: Record Actual Behavior** (what actually happened)
**Step 4: Compare & Report** (use templates below)

### Reporting Format (CRITICAL - Use This Exact Format)

```markdown
## Test: [Test Name]
**Devices**: Device A, Device B [, Device C]
**Date**: YYYY-MM-DD
**App Version**: [from profile screen]

### Expected Behavior:
[What SHOULD happen - from this guide]

### Actual Behavior:
[What ACTUALLY happened - be specific]

### Screenshots/Evidence:
[Attach screenshots]

### Related Unit Tests:
[Copy from this guide]

### My Analysis:
- [ ] Code is wrong (fix production code)
- [ ] Test is wrong (fix test expectations)
- [ ] Both might be wrong (investigate design intent)
- [ ] Not sure (needs discussion)

### Error Messages (if any):
```
[Copy any error messages exactly]
```
```

---

## 🔍 Test Scenarios - By Priority

---

## PRIORITY 1: Direct P2P Messaging (Core Functionality)

### Test 1.1: Basic P2P Message Exchange

**Devices**: A, B (physically close, ~2 meters)

**Steps**:
1. Open app on Device A
2. Open app on Device B
3. Device A: Go to "Devices" tab
4. Device A: Wait for Device B to appear (should see Device B's name/ID)
5. Device A: Tap on Device B → Opens chat
6. Device A: Type "Hello from A" → Send
7. **Observe Device A**: Message should show as "Sent" or "Delivered"
8. **Observe Device B**: Should receive "Hello from A" notification
9. Device B: Open chat with Device A
10. Device B: Should see "Hello from A" message
11. Device B: Type "Reply from B" → Send
12. **Observe both devices**: Message exchange successful

**Expected Behavior**:
- ✅ Devices discover each other within 5-10 seconds
- ✅ Messages sent show "Delivered" status on sender
- ✅ Messages received appear in recipient's chat
- ✅ No echo (sender doesn't receive their own message)
- ✅ Message content matches exactly what was sent

**If Failed - Check These**:
- Discovery issues → BLE scanning/advertising problem
- Message not sent → Encryption/transmission problem
- Message echo → P2P routing logic (we fixed this!)
- Wrong content → Encryption/decryption mismatch

**Related Unit Tests**:
- `test/p2p_message_routing_fix_test.dart`:
  - "Direct P2P message without routing info should be accepted"
  - "Direct P2P message with recipient info should be accepted"
  - "Message from ourselves should be blocked"

**Code Location**:
- `lib/data/services/ble_message_handler.dart`: lines 531-553 (routing logic)
- `lib/core/services/security_manager.dart`: encryption/decryption

**Decision Tree**:
```
Message echo (sender sees own message)?
├─ YES → Code bug (routing logic wrong) → Fix ble_message_handler.dart
└─ NO → Continue

Message not delivered?
├─ Check Device B screen → Message appeared?
   ├─ YES → Test expectation issue (check what test expects)
   └─ NO → Code bug (transmission/decryption issue)

Message garbled/wrong content?
└─ Encryption/decryption bug → Fix security_manager.dart
```

---

### Test 1.2: Encrypted Message Exchange

**Devices**: A, B

**Steps**:
1. Device A & B: Pair via QR code (if not paired)
2. Device A: Send "Encrypted test message" to Device B
3. **Observe**: Message should be encrypted in transit
4. Device B: Should see "Encrypted test message" (decrypted)
5. Device B: Reply "Encrypted reply"
6. Device A: Should see "Encrypted reply" (decrypted)

**Expected Behavior**:
- ✅ Messages are encrypted (you won't see plaintext on wire)
- ✅ Decrypted content matches sent content
- ✅ No "[❌ Could not decrypt message]" errors
- ✅ Encryption method shows in debug logs (ECDH, pairing, or global)

**If Failed - Check These**:
- Decryption errors → Security level mismatch
- Wrong keys → Key exchange issue
- Garbled text → Encryption algorithm bug

**Related Unit Tests**:
- `test/p2p_message_routing_fix_test.dart`:
  - "Encrypted P2P message should be processed normally"
- `test/contact_repository_sqlite_test.dart`: security level tests

**Code Location**:
- `lib/core/services/security_manager.dart`: encryptMessage/decryptMessage
- `lib/data/repositories/contact_repository.dart`: security levels

---

### Test 1.3: Message Persistence (App Restart)

**Devices**: A, B

**Steps**:
1. Device A: Send "Test message 1" to Device B
2. Device B: Verify message received
3. Device B: Force close app (swipe away from recent apps)
4. Device B: Reopen app
5. Device B: Navigate to chat with Device A
6. **Observe**: "Test message 1" should still be there

**Expected Behavior**:
- ✅ All messages persist after app restart
- ✅ Chat list shows last message
- ✅ Unread count preserved
- ✅ Message order maintained

**If Failed - Check These**:
- Messages disappear → Database persistence bug
- Wrong order → Timestamp/sorting issue
- Duplicates → Message deduplication bug

**Related Unit Tests**:
- `test/message_repository_sqlite_test.dart`:
  - "Save and retrieve message"
  - "Get messages returns sorted list"
- `test/chat_lifecycle_persistence_test.dart` (skipped - this validates it!)

**Code Location**:
- `lib/data/repositories/message_repository.dart`: saveMessage, getMessages
- `lib/data/database/database_helper.dart`: database schema

---

## PRIORITY 2: Mesh Relay (Multi-Device)

### Test 2.1: Three-Node Relay (A → B → C)

**Devices**: A, B, C

**Physical Setup**:
```
Device A <--2m--> Device B <--2m--> Device C
(A and C should NOT see each other directly)
```

**Steps**:
1. Position devices as shown (A and C out of range)
2. **Verify**: Device A should see Device B only
3. **Verify**: Device C should see Device B only
4. **Verify**: Device A should NOT see Device C
5. Device A: Try to send message to Device C
6. **Expected**: Message should route through Device B (relay)
7. **Observe Device B**: Should show relay activity in logs (if debug enabled)
8. **Observe Device C**: Should receive message from Device A

**Expected Behavior**:
- ✅ Message routes A → B → C automatically
- ✅ Device C sees message from Device A (not from B)
- ✅ Relay is transparent (Device A doesn't know it was relayed)
- ✅ No duplicates (message delivered once)
- ✅ Relay node (B) increments relay count in stats

**If Failed - Check These**:
- Message not delivered → Relay routing logic
- Duplicate messages → Deduplication issue
- Message shows wrong sender → Relay metadata preservation
- Relay loop → TTL/hop count not working

**Related Unit Tests**:
- `test/mesh_networking_integration_test.dart` (12 BLE failures - THIS IS WHAT THEY TEST!)
  - "should send relay message when recipient not directly connected"
  - "should integrate with ContactRepository"
- `test/relay_ack_propagation_test.dart`
- `test/mesh_relay_flow_test.dart` (skipped - complex multi-node)

**Code Location**:
- `lib/core/messaging/mesh_relay_engine.dart`: relay logic
- `lib/data/services/ble_message_handler.dart`: _handleMeshRelay (lines 796-869)
- `lib/core/routing/smart_mesh_router.dart`: routing decisions

**Decision Tree**:
```
Message delivered to C?
├─ YES → Success ✅
└─ NO → Check:
   ├─ Message reached B? → Check B's debug logs
   │  ├─ YES → B → C relay failed (check B's routing logic)
   │  └─ NO → A → B transmission failed (basic P2P issue)
   └─ Message duplicated? → Deduplication bug in relay engine
```

---

### Test 2.2: Relay ACK Propagation (C → B → A)

**Devices**: A, B, C (same setup as Test 2.1)

**Steps**:
1. Device A: Send "Test relay ACK" to Device C (via B relay)
2. **Observe Device A**: Message status should change from "Sent" → "Delivered"
3. **Expected**: ACK should propagate back C → B → A
4. Check Device A: Should show "Delivered" status (not stuck on "Sent")

**Expected Behavior**:
- ✅ ACK travels backward through relay chain
- ✅ Original sender (A) knows message was delivered
- ✅ Relay node (B) forwards ACK backward
- ✅ Status shows "Delivered" within 2-5 seconds

**If Failed - Check These**:
- Status stuck on "Sent" → ACK not propagating backward
- Status shows "Failed" → Relay timeout
- Duplicate ACKs → ACK deduplication issue

**Related Unit Tests**:
- `test/relay_ack_propagation_test.dart`:
  - "should send ACK back through relay chain"
  - "should handle relay ACK at originator"
- `test/message_retry_coordination_test.dart`

**Code Location**:
- `lib/data/services/ble_message_handler.dart`: _sendRelayAck (lines 1001-1046)
- `lib/data/services/ble_message_handler.dart`: _handleRelayAck (lines 1049-1114)

---

### Test 2.3: Offline Message Queue (Delayed Delivery)

**Devices**: A, B

**Steps**:
1. Device A: Turn OFF Bluetooth
2. Device B: Send "Offline message 1" to Device A
3. **Observe Device B**: Message should show "Pending" or "Queued"
4. Device B: Send "Offline message 2" to Device A
5. Device A: Turn ON Bluetooth
6. **Wait 5-10 seconds** (for discovery and sync)
7. **Observe Device A**: Should receive BOTH messages in order
8. **Observe Device B**: Message status should change to "Delivered"

**Expected Behavior**:
- ✅ Messages queue when recipient offline
- ✅ Messages deliver when recipient comes online
- ✅ Message order preserved (1 then 2)
- ✅ No duplicates
- ✅ Sender knows when messages delivered (status change)

**If Failed - Check These**:
- Messages never delivered → Queue sync not working
- Wrong order → Queue ordering issue
- Duplicates → Deduplication bug
- Lost messages → Queue persistence issue

**Related Unit Tests**:
- `test/offline_message_queue_sqlite_test.dart`:
  - "Queue message for offline recipient"
  - "Deliver queued messages when device comes online"
- `test/queue_sync_system_test.dart`:
  - "should handle sync requests" (we fixed this!)

**Code Location**:
- `lib/core/messaging/offline_message_queue.dart`: queueMessage, getQueuedMessages
- `lib/core/messaging/queue_sync_manager.dart`: handleSyncRequest (we fixed line 276!)

---

## PRIORITY 3: Contact Management

### Test 3.1: QR Code Pairing

**Devices**: A, B

**Steps**:
1. Device A: Go to Profile → Show My QR Code
2. Device B: Go to Devices → Scan QR Code
3. Device B: Scan Device A's QR code
4. **Observe Device B**: Should show "Contact added" or similar
5. Device A: Should receive "Contact request from [Device B name]"
6. Device A: Accept contact request
7. **Verify**: Both devices show each other in contacts list
8. Device A: Send message to Device B
9. **Observe**: Message should be encrypted (higher security level)

**Expected Behavior**:
- ✅ QR scan creates contact
- ✅ Contact appears in list with name
- ✅ Security level upgrades (from "global" to "pairing" or "high")
- ✅ Subsequent messages use stronger encryption

**If Failed - Check These**:
- QR scan fails → QR code generation/parsing issue
- Contact not added → Contact repository persistence
- Security not upgraded → Security level logic

**Related Unit Tests**:
- `test/contact_repository_sqlite_test.dart`:
  - "Save and retrieve contact"
  - "Mark contact as verified"
  - "Security upgrade path validation"

**Code Location**:
- `lib/data/repositories/contact_repository.dart`: saveContact, markAsVerified
- `lib/data/services/ble_message_handler.dart`: handleQRIntroductionClaim

---

### Test 3.2: Contact Name Updates

**Devices**: A, B

**Steps**:
1. Device A: Go to Profile → Change name to "Alice"
2. Device B: Should see name update to "Alice" in:
   - Devices list
   - Chat list (if chat exists)
   - Active chat screen (if open)
3. **Timing**: Should update within 10-30 seconds

**Expected Behavior**:
- ✅ Name updates propagate to all connected devices
- ✅ Updates appear in UI without app restart
- ✅ Updates persist after app restart

**If Failed - Check These**:
- Name doesn't update → Username propagation issue
- Requires restart → Cache invalidation issue
- Wrong name → Contact mapping issue

**Related Unit Tests**:
- `test/username_propagation_test.dart`:
  - "Username updates should propagate to UI"
  - "Contact repository should update on username change"

**Code Location**:
- `lib/data/repositories/user_preferences.dart`: setUserName (lines 31-39)
- Stream controller for reactive updates (line 16)

---

## PRIORITY 4: Archive & Search

### Test 4.1: Archive Chat

**Devices**: A (single device test)

**Steps**:
1. Device A: Create chat with Device B (send a few messages)
2. Device A: Long-press on chat in chat list → Archive
3. **Observe**: Chat disappears from main chat list
4. Device A: Go to Archive screen
5. **Verify**: Archived chat appears with message count
6. Device A: Tap archived chat → Should open with all messages
7. Device A: Restore chat
8. **Verify**: Chat returns to main chat list with all messages

**Expected Behavior**:
- ✅ Archived chats hidden from main list
- ✅ Archive preserves all messages
- ✅ Message count accurate
- ✅ Restore brings everything back
- ✅ Full-text search works on archived messages

**If Failed - Check These**:
- Messages lost → Archive persistence issue
- Wrong count → Counting logic
- Can't restore → Restore logic bug

**Related Unit Tests**:
- `test/archive_repository_sqlite_test.dart`:
  - "Archive chat successfully"
  - "Restore archived chat successfully"
  - "Search archived messages using FTS5"

**Code Location**:
- `lib/domain/services/archive_management_service.dart`
- `lib/data/repositories/archive_repository.dart`

---

## PRIORITY 5: Edge Cases & Stress Tests

### Test 5.1: Rapid Message Sending

**Devices**: A, B

**Steps**:
1. Device A: Send 10 messages rapidly (as fast as possible)
   - "Message 1", "Message 2", ..., "Message 10"
2. **Observe Device A**: All should send (may queue)
3. **Observe Device B**: All 10 should arrive in order
4. **Verify**: No duplicates, no missing messages

**Expected Behavior**:
- ✅ All messages send (may be queued)
- ✅ All messages received in order
- ✅ No duplicates
- ✅ No crashes

**If Failed - Check These**:
- Duplicates → Deduplication bug
- Lost messages → Queue overflow
- Out of order → Timestamp sorting issue
- Crash → Race condition in message handling

**Related Unit Tests**:
- `test/message_repository_sqlite_test.dart`: performance tests
- `test/queue_sync_system_test.dart`: large queue tests

---

### Test 5.2: App Backgrounding

**Devices**: A, B

**Steps**:
1. Device A: Send message to Device B
2. Device B: Background app (home button, don't close)
3. Device A: Send "Background test" to Device B
4. **Observe Device B**: Should show notification
5. Device B: Tap notification → App should open to chat
6. **Verify**: "Background test" message visible

**Expected Behavior**:
- ✅ Notifications work when app backgrounded
- ✅ Messages still received
- ✅ Tapping notification opens correct chat

**If Failed - Check These**:
- No notification → Notification service
- Message not received → Background BLE scanning
- Wrong chat opens → Notification deep linking

---

### Test 5.3: Large Message (Fragmentation)

**Devices**: A, B

**Steps**:
1. Device A: Send very long message (500+ characters)
2. **Observe**: Message should send (may take longer)
3. Device B: Should receive complete message
4. **Verify**: Content matches exactly, no truncation

**Expected Behavior**:
- ✅ Long messages send successfully
- ✅ Content preserved exactly
- ✅ No truncation or corruption
- ✅ Reassembly transparent to user

**If Failed - Check These**:
- Truncation → Fragmentation chunk size
- Corruption → Reassembly logic
- Timeout → Chunk delivery timing

**Related Unit Tests**:
- `test/message_fragmenter_test.dart` (if exists)

**Code Location**:
- `lib/core/utils/message_fragmenter.dart`
- `lib/data/services/ble_message_handler.dart`: MessageReassembler

---

## 🐛 How to Report Failures

### Template 1: Code Bug (Fix Production Code)

```markdown
## BUG: [Short Description]

**Test**: [Test number and name from this guide]
**Severity**: Critical / High / Medium / Low

### Expected (from guide):
[Copy from "Expected Behavior"]

### Actual:
[What happened]

### Steps to Reproduce:
1. [Exact steps]
2. [...]

### Evidence:
- Screenshot 1: [Before]
- Screenshot 2: [During/After]
- Logs: [If available]

### Impact on Unit Tests:
**These tests are CORRECT** (testing right thing):
- [ ] test/[test_file.dart]: "[test name]"
- [ ] test/[test_file.dart]: "[test name]"

**Production code to fix**:
- lib/[file.dart]: [function/method]

### Suggested Fix (optional):
[If you have an idea]
```

---

### Template 2: Test Bug (Fix Test Expectations)

```markdown
## TEST EXPECTATION WRONG: [Short Description]

**Test**: [Test number and name from this guide]

### What Actually Happens (and it's CORRECT):
[Real behavior that makes sense]

### What Test Expects (WRONG):
[What the test thinks should happen]

### Why Real Behavior is Right:
[Explanation of why actual behavior is correct]

### Tests to Update:
- [ ] test/[test_file.dart]: "[test name]" - Change expectation from X to Y
- [ ] test/[test_file.dart]: "[test name]" - Change expectation from X to Y

### Keep Production Code:
- lib/[file.dart] is working correctly ✅
```

---

### Template 3: Both Wrong (Design Discussion)

```markdown
## DESIGN ISSUE: [Short Description]

**Test**: [Test number and name from this guide]

### The Confusion:
- Real behavior: [What happens]
- Test expects: [What test thinks]
- Guide says: [What this guide says]
- **Problem**: Not sure which is correct!

### Questions:
1. Should [feature] behave like [option A] or [option B]?
2. Is [current behavior] the intended design?

### Impact:
This affects:
- User experience: [How?]
- Related features: [Which ones?]

### Need Discussion:
- [ ] Clarify design intent
- [ ] Then fix either code OR test (not sure which yet)
```

---

## 📊 Testing Progress Tracker

Copy this to a new document to track your testing:

```markdown
# Testing Progress - [Date]

## Priority 1: Direct P2P Messaging
- [ ] Test 1.1: Basic P2P Message Exchange
  - Status: Not Started / In Progress / ✅ Pass / ❌ Fail
  - Notes:
- [ ] Test 1.2: Encrypted Message Exchange
  - Status:
  - Notes:
- [ ] Test 1.3: Message Persistence
  - Status:
  - Notes:

## Priority 2: Mesh Relay
- [ ] Test 2.1: Three-Node Relay
  - Status:
  - Notes:
- [ ] Test 2.2: Relay ACK Propagation
  - Status:
  - Notes:
- [ ] Test 2.3: Offline Message Queue
  - Status:
  - Notes:

## Priority 3: Contact Management
- [ ] Test 3.1: QR Code Pairing
  - Status:
  - Notes:
- [ ] Test 3.2: Contact Name Updates
  - Status:
  - Notes:

## Priority 4: Archive & Search
- [ ] Test 4.1: Archive Chat
  - Status:
  - Notes:

## Priority 5: Edge Cases
- [ ] Test 5.1: Rapid Message Sending
  - Status:
  - Notes:
- [ ] Test 5.2: App Backgrounding
  - Status:
  - Notes:
- [ ] Test 5.3: Large Message Fragmentation
  - Status:
  - Notes:

## Summary
- Total Tests: 12
- Passed: 0
- Failed: 0
- Bugs Found: 0
- Tests to Fix: 0

## Next Session Plan:
[What to fix based on results]
```

---

## 🎯 Success Criteria

**After this testing session, you should know**:
1. ✅ Which unit tests are testing the RIGHT behavior (keep them)
2. ❌ Which unit tests have WRONG expectations (fix them)
3. 🐛 Which production code has BUGS (fix them)
4. 📝 Which features need design clarification

**Ideal Outcome**:
- All Priority 1-3 tests pass ✅
- Any failures have clear root cause identified
- Know exactly what to fix (code or test)

---

## 💡 Pro Tips

### During Testing

1. **Test one thing at a time**
   - Don't skip ahead if earlier test fails
   - Fix blockers before continuing

2. **Document everything**
   - Take screenshots of every failure
   - Copy error messages exactly
   - Note device states (BT on/off, app state, etc.)

3. **Reproduce failures**
   - If something fails, try it 2-3 times
   - Note if it's consistent or intermittent

4. **Check logs**
   - Enable debug logging if possible
   - Look for error messages
   - Note any warnings

### After Testing

1. **Categorize failures**
   - Code bugs (fix production)
   - Test bugs (fix expectations)
   - Design issues (discuss)

2. **Prioritize fixes**
   - Critical: Blocks core functionality
   - High: Impacts user experience
   - Medium: Edge cases
   - Low: Nice to have

3. **Create clear report**
   - Use templates above
   - One report per issue
   - Link related tests

---

## 🚀 Next Steps After Testing

### Scenario A: Most Tests Pass (>80%)
1. Fix the few failures
2. Update unit tests if needed
3. Add new unit tests for uncovered edge cases
4. Move to Phase 2 (new features)

### Scenario B: Many Failures (20-50%)
1. Identify patterns (common root cause?)
2. Fix most critical issues first
3. Retest after fixes
4. Iterate until >80% pass

### Scenario C: Fundamental Issues (>50% fail)
1. Reassess core architecture
2. May need design discussion
3. Prioritize what to fix vs. redesign
4. Create focused test plan for rebuild

---

## 📞 How to Report Back

**Best Format**:
```
Completed testing session [date]
Devices used: [list]
Tests run: X/12

Summary:
- ✅ Passing: X tests
- ❌ Failing: Y tests
- 📝 Issues found: Z

Detailed results attached using templates.
Ready for next steps: [Yes/No]
Questions: [Any confusion?]
```

Then paste individual bug reports using templates above.

---

## Final Note

**Remember**: The goal isn't to make all tests pass by tweaking tests. The goal is to **discover truth**:
- What actually works?
- What actually doesn't work?
- Where are our assumptions wrong?

Be honest. Report what you see. We'll fix what needs fixing (code or tests or both).

Good luck! 🚀

---

**Created**: 2025-10-05
**Purpose**: Real-world validation of unit test assumptions
**Next**: Test on real devices, report findings, fix accordingly

# Step 10: End-to-End Testing Plan

**Date:** October 7, 2025
**Status:** 🔄 IN PROGRESS
**Focus:** Comprehensive end-to-end testing of all implemented features

---

## 🎯 Testing Objectives

1. Verify complete pairing workflow
2. Test hint recognition system
3. Validate chat migration
4. Confirm message addressing
5. Test discovery overlay improvements
6. Verify security levels
7. Performance benchmarking

---

## 🧪 Test Scenarios

### Scenario 1: Fresh Install - First Connection

**Steps:**
1. Install app on two devices (Device A & Device B)
2. Open Discovery Overlay on Device A
3. Connect to Device B
4. Exchange names

**Expected Results:**
- ✅ Devices discover each other
- ✅ Names exchange successfully
- ✅ Chat opens with "needs pairing" status
- ✅ Messages use ephemeral addressing
- ✅ Discovery shows device with basic encryption badge

**Verification:**
- Check logs for ephemeral ID usage
- Verify no persistent key broadcast
- Confirm chat ID is ephemeral

---

### Scenario 2: Pairing Flow

**Steps:**
1. From Scenario 1, click lock icon in chat
2. Wait for pairing request to arrive on Device B
3. Accept pairing on Device B
4. Verify 6-digit codes match on both devices
5. Enter codes

**Expected Results:**
- ✅ Pairing request sent successfully
- ✅ Popup appears on Device B
- ✅ Same 6-digit code shown on both devices
- ✅ Code verification succeeds
- ✅ Shared key established
- ✅ Security level upgrades to "PAIRED"

**Verification:**
- Check logs for "STEP 3" pairing messages
- Verify persistent key exchange
- Confirm security level = MEDIUM
- Check chat status shows "Secured"

---

### Scenario 3: Contact Addition

**Steps:**
1. From Scenario 2 (paired state), click + icon
2. Accept contact request on Device B
3. Verify contact appears in contacts list

**Expected Results:**
- ✅ Contact request sent
- ✅ Popup appears on Device B
- ✅ Contact added to both devices
- ✅ Security level upgrades to "ECDH"
- ✅ Trust status = "verified"

**Verification:**
- Check logs for ECDH secret computation
- Verify security level = HIGH
- Confirm contact appears in repository
- Check chat status shows "Verified Contact"

---

### Scenario 4: Chat Migration

**Steps:**
1. From Scenario 1-3, check chat ID before and after pairing
2. Verify messages persist across migration

**Expected Results:**
- ✅ Chat ID starts as ephemeral (temp_xxx)
- ✅ After pairing, chat ID becomes persistent (PK_xxx)
- ✅ All messages migrate successfully
- ✅ No message duplication
- ✅ Chat history preserved

**Verification:**
- Check logs for "STEP 6" migration messages
- Verify database: old chat removed, new chat has all messages
- Confirm message count matches before/after

---

### Scenario 5: Discovery with Hints

**Steps:**
1. From Scenario 3 (contacts added), disconnect devices
2. Close and reopen app
3. Open Discovery Overlay

**Expected Results:**
- ✅ Contact name appears in discovery (not device ID)
- ✅ "CONTACT" badge visible
- ✅ "ECDH" security badge visible
- ✅ "VERIFIED" badge visible
- ✅ Green avatar color
- ✅ Green status dot

**Verification:**
- Check logs for hint resolution
- Verify hint cache hit
- Confirm contact match from advertisement data

---

### Scenario 6: Message Addressing

**Steps:**
1. Test messaging at each security level:
   - After connection (before pairing)
   - After pairing
   - After contact addition

**Expected Results:**

**Before Pairing:**
- ✅ Messages use ephemeral addressing
- ✅ Recipient ID = temp_xxx
- ✅ useEphemeralAddressing = true

**After Pairing:**
- ✅ Messages use persistent addressing
- ✅ Recipient ID = PK_xxx
- ✅ useEphemeralAddressing = false

**After Contact Addition:**
- ✅ Messages use persistent addressing
- ✅ Recipient ID = PK_xxx
- ✅ ECDH encryption active

**Verification:**
- Check logs for "STEP 7" addressing messages
- Verify correct ID type used
- Confirm addressing flag matches pairing status

---

### Scenario 7: Reconnection

**Steps:**
1. From Scenario 3 (verified contact), disconnect
2. Close app completely
3. Reopen app and connect again

**Expected Results:**
- ✅ Contact recognized immediately
- ✅ Name appears (not device ID)
- ✅ Security level restored (ECDH)
- ✅ Chat history available
- ✅ No re-pairing needed

**Verification:**
- Check hint recognition in logs
- Verify persistent key loaded from storage
- Confirm security state restored

---

### Scenario 8: Multiple Contacts

**Steps:**
1. Connect to Device C (third device)
2. Pair with Device C
3. Add Device C as contact
4. Open Discovery Overlay

**Expected Results:**
- ✅ All contacts shown with names
- ✅ Correct security badges for each
- ✅ Independent security levels
- ✅ No cross-contamination of keys

**Verification:**
- Check contact repository has both contacts
- Verify unique keys per contact
- Confirm correct security levels

---

### Scenario 9: Edge Cases

#### 9a: Pairing Timeout
**Steps:**
1. Start pairing
2. Don't accept on other device
3. Wait 30 seconds

**Expected:**
- ✅ Timeout occurs
- ✅ Pairing cancelled
- ✅ Can retry pairing

#### 9b: Contact Request Rejection
**Steps:**
1. Send contact request
2. Reject on other device

**Expected:**
- ✅ Request rejected gracefully
- ✅ Stays in paired state
- ✅ Can retry later

#### 9c: Disconnection During Pairing
**Steps:**
1. Start pairing
2. Force disconnect during code verification

**Expected:**
- ✅ Pairing fails gracefully
- ✅ Returns to connected state
- ✅ Can retry

---

## 📊 Performance Benchmarks

### Test 1: Hint Generation
```bash
flutter test test/hint_system_test.dart
```

**Expected:**
- ✅ 10,000 intro hints: < 200ms
- ✅ 10,000 sensitive hints: < 100ms
- ✅ 10,000 pack/parse: < 10ms

### Test 2: Discovery Performance
**Metrics:**
- Time to first device: < 2 seconds
- Time to resolve contact name: < 100ms
- UI responsiveness: No lag

### Test 3: Chat Loading
**Metrics:**
- Load 100 messages: < 500ms
- Load 1000 messages: < 2 seconds
- Scroll performance: 60 FPS

---

## 🔒 Security Validation

### Test 1: Encryption Verification
**Steps:**
1. Send message
2. Inspect network traffic (if possible)
3. Verify encrypted content

**Expected:**
- ✅ No plaintext in BLE characteristics
- ✅ Messages encrypted before transmission
- ✅ Different ciphertext for same plaintext

### Test 2: Key Isolation
**Steps:**
1. Pair with multiple contacts
2. Verify keys are unique

**Expected:**
- ✅ Each contact has unique key
- ✅ No key reuse
- ✅ Proper key derivation

### Test 3: Privacy Validation
**Steps:**
1. Monitor BLE advertisements
2. Verify no persistent key broadcast

**Expected:**
- ✅ Only ephemeral hints broadcast
- ✅ No direct public key exposure
- ✅ Hints change appropriately

---

## 🐛 Bug Tracking

### Issues Found
_(To be filled during testing)_

### Resolutions
_(To be filled during testing)_

---

## ✅ Test Execution Log

### Run 1: [Date/Time]
- **Tester:** [Name]
- **Devices:** [Device models]
- **Results:** [Pass/Fail counts]
- **Issues:** [List any issues]

### Run 2: [Date/Time]
- **Tester:** [Name]
- **Devices:** [Device models]
- **Results:** [Pass/Fail counts]
- **Issues:** [List any issues]

---

## 📋 Final Checklist

### Core Functionality
- [ ] Device discovery works
- [ ] Name exchange succeeds
- [ ] Pairing flow completes
- [ ] Contact addition works
- [ ] Chat migration succeeds
- [ ] Message addressing correct

### Discovery Overlay
- [ ] Contact names appear
- [ ] Security badges correct
- [ ] Verification badges shown
- [ ] Signal strength accurate
- [ ] UI responsive

### Security
- [ ] Encryption working
- [ ] Keys properly isolated
- [ ] Privacy preserved
- [ ] No key leakage

### Performance
- [ ] Hint generation fast
- [ ] Discovery responsive
- [ ] Chat loading quick
- [ ] No memory leaks

### Edge Cases
- [ ] Timeout handling works
- [ ] Rejection handling works
- [ ] Disconnection recovery works
- [ ] Multiple contacts work

---

## 🎯 Success Criteria

To consider Phase 10 complete, ALL of the following must pass:

1. ✅ All 47 unit tests passing
2. ✅ All 9 test scenarios passing
3. ✅ All performance benchmarks met
4. ✅ No critical bugs found
5. ✅ Security validation complete
6. ✅ Documentation accurate

---

## 📝 Notes

_Add observations, insights, or recommendations here during testing._

---

**Status:** Ready for manual testing
**Next:** Execute test scenarios and document results
**Date:** October 7, 2025

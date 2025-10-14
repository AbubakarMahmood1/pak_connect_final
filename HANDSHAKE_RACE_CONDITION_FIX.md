# Handshake Race Condition Fix

## Problem Summary

**Issue**: Infinite reconnection loop caused by handshake completing successfully but then immediately failing.

**User's Original Report**:
```
"i keep getting stuck in this loop... i cannot even maintain connection"
```

**User's Log Evidence**:
```
🤝 Handshake phase: ConnectionPhase.complete  ← Handshake succeeds ✅
isConnected=true, isReady=true                ← UI updates correctly ✅
⏱️ Phase timeout waiting for: contactStatus   ← Timer fires! ❌
❌ Handshake failed: Timeout waiting for contactStatus
🤝 Handshake phase: ConnectionPhase.failed   ← False failure ❌
Disconnecting...                              ← Triggers disconnect
Success: Device reconnected!                  ← Reconnection starts
(Loop repeats infinitely)
```

**User's Correct Analysis**:
> "handshake had succeeded, but that fail trigger fired disconnect and my reconnection logic took over"

The handshake COMPLETES successfully, but then a timer callback fires and marks it as failed, creating a false positive that triggers the reconnection loop.

---

## Root Cause Analysis

### The Race Condition

**Location**: `lib/core/bluetooth/handshake_coordinator.dart`

**Timeline of Events**:

1. ContactStatus phase timer started (10 second timeout)
2. ContactStatus response received quickly
3. `_advanceToContactStatusComplete()` called
4. `_advanceToComplete()` called
5. Phase set to `complete` ✅
6. Timer cancelled with `_timeoutTimer?.cancel()` ✅
7. **`await _onHandshakeComplete(...)` called** ⏳ (takes time for DB operations)
8. **Timer callback fires during the await** 💥 (was already scheduled in event loop)
9. Timer callback executes `_failHandshake()` - NO phase check
10. Phase changes to `failed` ❌

### Why Timer Callback Fired After Cancellation

**Dart Timer Behavior**:

- When a `Timer` expires, its callback is queued in the event loop
- `Timer.cancel()` prevents future execution but **cannot remove already-queued callbacks**
- If cancellation happens during the brief window when callback is already queued, it will still execute

**The Async Gap**:
```dart
Future<void> _advanceToComplete() async {
  _timeoutTimer?.cancel();  // ← Cancels timer
  _phase = ConnectionPhase.complete;
  _phaseController.add(_phase);
  
  // 🚨 ASYNC WORK HERE - if timer callback was queued, it fires during this
  await _onHandshakeComplete(_theirEphemeralId!, _theirDisplayName!);
}
```

**What `_onHandshakeComplete()` Does** (from `ble_service.dart`):

- Database query: `getMessages(chatId)` - can take 10-100ms
- Database write: `saveContact()` - can take 10-50ms  
- Database update: `updateContactLastSeen()` - can take 10-50ms
- Database write: `storeDeviceMapping()` - can take 10-50ms
- Message processing: `_processPendingMessages()` - variable time

**Total async time**: 40-250ms where timer callback could execute

---

## The Fix

### Previous Attempt (Incorrect)

**What was tried**: Added immediate `isReady=false` in BLE service when handshake fails
**Why it didn't work**: Treated the symptom (reconnection loop) not the cause (false failure)

### Correct Solution

**Add defensive phase check in timer callback**:

```dart
void _startPhaseTimeout(String waitingFor) {
  _timeoutTimer?.cancel();
  _timeoutTimer = Timer(_phaseTimeout, () {
    // ✅ NEW: Defensive check prevents false failures
    if (_phase == ConnectionPhase.complete) {
      _logger.info('⏱️ Timer fired but handshake already complete - ignoring');
      return;
    }
    _logger.warning('⏱️ Phase timeout waiting for: $waitingFor');
    _failHandshake('Timeout waiting for $waitingFor');
  });
}
```

**Why this works**:

1. Timer callback checks current phase **before** executing failure logic
2. If handshake already complete, callback exits harmlessly
3. Real timeouts still work correctly (phase won't be complete)
4. No performance impact (single equality check)
5. Future-proof against similar race conditions

---

## Testing Plan

1. **Rebuild app** with the fix
2. **Test normal handshake** (should complete without false failure)
3. **Test reconnection** (should maintain connection, not loop)
4. **Test real timeout** (disconnect device mid-handshake, verify timeout still triggers)
5. **Test rapid connections** (connect/disconnect quickly, verify no race conditions)

**Expected Behavior After Fix**:
```
🤝 Handshake phase: ConnectionPhase.complete  ← Completes
⏱️ Timer fired but handshake already complete - ignoring  ← Timer ignored! ✅
isConnected=true, isReady=true                ← Stays connected
Ready to chat                                 ← No reconnection loop
```

---

## Why This Approach is Future-Proof

1. **Defensive Programming**: Checks state before destructive action
2. **Minimal Change**: One line added, no architectural changes
3. **No Side Effects**: Doesn't affect normal timeout behavior
4. **Clear Intent**: Comment explains why check exists
5. **Testable**: Easy to verify both success and failure paths

**User's Requirement Met**:
> "understanding and preparation is the key to success... future proof solution"

This fix addresses the root cause (async race condition) with a defensive check that prevents similar issues in future async operations.

---

## Files Modified

### `lib/core/bluetooth/handshake_coordinator.dart`

- **Line 340-352**: Added phase check in `_startPhaseTimeout()` timer callback
- **Purpose**: Prevent timer from failing handshake if already complete
- **Impact**: Eliminates false positive failures caused by async timing

---

## Related Code (No Changes Needed)

### `lib/data/services/ble_service.dart`

- Lines 1561-1574: Handles legitimate handshake failures
- This code is CORRECT and still needed for real timeouts
- With the fix, this only triggers on genuine failures

---

## Next Steps

1. User rebuilds and tests the fix
2. If successful, mark handshake issue as **RESOLVED** ✅
3. Return to queue architecture decision
4. Continue with remaining features:
   - Fix burst scanning max connections
   - Fix unread count behavior  
   - Implement message notifications
   - Fix ephemeral contacts name persistence

# Two-Device Testing Requirements
**Purpose**: Guide for testing BLE-specific features that cannot be tested on a single device/emulator
**Required for**: CG-004 (Handshake timing) and CG-007 (Self-connection prevention)
**Total time**: 25 minutes

---

## 🎯 What Needs Two Devices

### ❌ **Cannot Test Single-Device**

These 2 confidence gaps **require physical BLE hardware**:

1. **CG-004: Handshake Phase Timing** (15 min)
   - **Why**: BLE GATT handshake requires real BLE stack
   - **Risk**: Phase 2 may start before Phase 1.5 completes
   - **Impact**: Encryption errors if Noise session not ready

2. **CG-007: Self-Connection Prevention** (10 min)
   - **Why**: BLE advertising/scanning requires real radio
   - **Risk**: Device may connect to itself (BLE dual-role)
   - **Impact**: Infinite loop, resource exhaustion

---

## ✅ **What You CAN Test Before Devices**

**All Phase 1 tests (30 minutes)** can run on your development machine:

```bash
# These DON'T need devices - run these FIRST
flutter test test/debug_nonce_test.dart                    # Nonce race
flutter test test/database_query_optimizer_test.dart       # N+1 query
timeout 60 flutter test test/mesh_relay_flow_test.dart     # Flaky tests
timeout 60 flutter test test/chat_lifecycle_persistence_test.dart
timeout 60 flutter test test/chats_repository_sqlite_test.dart
```

**Save outputs to**: `PHASE1_COMPLETE_OUTPUT.txt`

**YOU SHOULD DO PHASE 1 FIRST** - this gives you:
- 98.5% confidence (up from 97%)
- Clear error messages for flaky tests
- Performance baselines
- Understanding of what's broken

**THEN** decide if you need device testing based on Phase 1 results.

---

## 📱 Device Setup Requirements

### Minimum Hardware

**Option 1: Two Android Devices**
- Android 5.0+ (API 21+)
- BLE 4.0+ support
- USB debugging enabled
- ~100 MB free space

**Option 2: Two iOS Devices**
- iOS 10.0+
- BLE 4.0+ support
- Developer mode enabled
- ~100 MB free space

**Option 3: Mixed (1 Android + 1 iOS)**
- Best for cross-platform validation
- Tests BLE compatibility

### Software Setup

1. **Build debug APK/IPA**:
   ```bash
   # Android
   flutter build apk --debug
   # Location: build/app/outputs/flutter-apk/app-debug.apk

   # iOS
   flutter build ios --debug
   # Requires Xcode, Apple Developer account
   ```

2. **Install on devices**:
   ```bash
   # Android (via ADB)
   adb install build/app/outputs/flutter-apk/app-debug.apk

   # iOS (via Xcode)
   # Open in Xcode → Run on physical device
   ```

3. **Grant permissions**:
   - Location (required for BLE scanning)
   - Bluetooth
   - Storage (for logs)

4. **Enable verbose logging**:
   - Open app
   - Settings → Debug → Log Level = ALL
   - OR: Modify `lib/main.dart:15` to set `Logger.root.level = Level.ALL`

---

## 🧪 Test Procedures

### Test 1: Handshake Phase Timing (CG-004) - 15 minutes

**Goal**: Verify Phase 2 waits for Phase 1.5 (Noise handshake) to complete

**Setup** (5 min):
1. Install debug APK on Device A and Device B
2. Enable verbose logging on both
3. Connect both devices to computer via USB
4. Open 2 terminal windows for `adb logcat`

**Scenario 1: Normal Handshake** (5 min):

```bash
# Terminal 1: Device A logs
adb -s <device_a_serial> logcat | grep -E "HandshakeCoordinator|NoiseSession" | tee device_a_handshake_normal.txt

# Terminal 2: Device B logs
adb -s <device_b_serial> logcat | grep -E "HandshakeCoordinator|NoiseSession" | tee device_b_handshake_normal.txt
```

**Steps**:
1. Device A: Open app, go to Contacts screen
2. Device B: Open app, go to Contacts screen
3. Device A: Tap "Scan for Nearby"
4. Device A: Tap Device B in scan results
5. Wait for handshake to complete (~5 seconds)
6. Verify contact added on both devices

**Expected logs**:
```
[HandshakeCoordinator] Phase 0: CONNECTION_READY
[HandshakeCoordinator] Phase 1: IDENTITY_EXCHANGE sent
[NoiseSession] Starting XX handshake...
[NoiseSession] Handshake message 1/3 sent
[NoiseSession] Handshake message 2/3 received
[NoiseSession] Handshake message 3/3 sent
[NoiseSession] Session established ✅
[HandshakeCoordinator] Phase 1.5: NOISE_HANDSHAKE complete
[HandshakeCoordinator] Phase 2: CONTACT_STATUS_SYNC sent
```

**Success criteria**:
- ✅ "Session established" appears BEFORE "Phase 2"
- ✅ No "Noise session not ready" errors
- ✅ Contact added successfully

**Scenario 2: Race Condition Trigger** (5 min):

**Steps**:
1. Repeat Scenario 1 but add network delay:
   - Device A: Settings → Developer Options → Bluetooth HCI snoop log (enable)
   - This adds ~50-100ms latency to BLE operations
2. Repeat handshake 3 times
3. Check for timing errors

**Expected issue (if bug exists)**:
```
[HandshakeCoordinator] Phase 2: CONTACT_STATUS_SYNC sent
[NoiseSession] Session established ✅  ← AFTER Phase 2!
❌ ERROR: Attempted to encrypt before session ready
```

**If this happens**: Bug confirmed (92% → 100%)
**If no errors**: Bug doesn't manifest in practice (good news!)

---

### Test 2: Dual-Role Device Appearance (CG-007) - 10 minutes

**Goal**: Verify Device A doesn't incorrectly show Device B on both central AND peripheral sides

**Setup** (3 min):
1. Install debug APK on Device A and Device B
2. Enable verbose logging on both devices
3. Connect both devices to computer via USB

**Procedure** (7 min):

```bash
# Terminal 1: Device A logs
adb -s <device_a_serial> logcat | grep -E "BLEConnectionManager|PeripheralInitializer|discovered" | tee device_a_dual_role.txt

# Terminal 2: Device B logs
adb -s <device_b_serial> logcat | grep -E "BLEConnectionManager|PeripheralInitializer|discovered" | tee device_b_dual_role.txt
```

**Steps**:
1. Device A: Open app, go to Contacts screen
2. Device B: Open app, go to Contacts screen
3. Device A: Tap "Scan for Nearby"
4. Device A: Tap Device B in scan results (initiates central connection)
5. Wait for handshake to complete (~5 seconds)
6. Verify both devices' contact lists
7. Check both devices' UI for incorrect "dual role" badges

**Expected logs (CORRECT behavior - Device A as central)**:
```
[Device A] Scanning for nearby devices (central mode)
[Device A] Found Device B (peripheral)
[Device A] Connecting to Device B (central initiator)
[Device A] Connected to Device B - shows in chat list as contacted peer
[Device B] Received connection from Device A (peripheral acceptor)
[Device B] Connected to Device A - shows as connected contact
[Device B] No "dual role" badge (connected only as peripheral)
```

**Success criteria**:
- ✅ Device A shows Device B in chat list (initiator perspective)
- ✅ Device B shows Device A in chat list (acceptor perspective)
- ✅ Device A does NOT show Device B on peripheral side (no dual-role badge)
- ✅ Device B does NOT show Device A twice
- ✅ No "dual role" UI badges appear

**Expected issue (if bug exists)**:
```
[Device A] Scanning for nearby devices (central mode)
[Device A] Found Device B (peripheral)
[Device A] Connecting to Device B (central)
[Device A] Connected to Device B ✅
[Device A] ALSO shows Device B in peripheral discovered list ❌
[Device A] Shows "dual role" badge for Device B ❌
[UI] Can open chat from either central OR peripheral entry ❌
```

**If this happens**: Bug confirmed (85% → 100%)
**If only central entry**: Behavior is correct (good news!)

---

## 📊 Data Collection

### Log Files to Save

After each test, save these files:

```
device_a_handshake_normal.txt      # Scenario 1 normal handshake (Device A)
device_b_handshake_normal.txt      # Scenario 1 normal handshake (Device B)
device_a_handshake_race.txt        # Scenario 2 race condition (Device A)
device_b_handshake_race.txt        # Scenario 2 race condition (Device B)
device_a_self_connection.txt       # Self-connection test (Device A)
```

**Consolidate**:
```bash
cat device_*.txt > TWO_DEVICE_TEST_COMPLETE_OUTPUT.txt
```

### What to Look For

**🔴 CRITICAL - Report immediately**:
- "Noise session not ready" errors
- "Attempted to encrypt before session ready"
- "Connection to self detected"
- Any crashes or ANRs

**🟡 WARNING - Note but not blocking**:
- Handshake takes >10 seconds
- Scan results include own device (but filtered correctly)
- Connection retries

**✅ SUCCESS - Expected behavior**:
- All phases complete in order
- No encryption errors
- Own device filtered from scan results
- Contacts added successfully

---

## 🎯 Decision Points

### After Phase 1 Tests (30 min)

**If Phase 1 reveals critical issues**:
- ❌ Don't proceed to device testing yet
- Fix critical issues first (nonce race, N+1 query, flaky tests)
- Re-run Phase 1 to verify fixes

**If Phase 1 passes cleanly**:
- ✅ Proceed to device testing
- You'll have high confidence going in

### After Device Testing (25 min)

**If both tests pass**:
- ✅ Bump confidence to 100%
- ✅ Mark CG-004 and CG-007 as RESOLVED
- ✅ Focus on fixing other issues (security, performance)

**If handshake timing fails**:
- Implement FIX-008 from RECOMMENDED_FIXES.md
- Add `_waitForRemoteKey()` and `_waitForSessionEstablished()`
- Re-test

**If dual-role device appearance fails**:
- Review BLE connection tracking in `BLEConnectionManager.dart`
- Check if centrally-connected devices are added to peripheral discovered list
- Add deduplication logic for connected vs discovered devices
- Verify notification subscriptions on both connection sides

---

## 📋 Quick Reference Commands

### Build and Install

```bash
# Build debug APK
flutter build apk --debug

# Install on connected device
adb install build/app/outputs/flutter-apk/app-debug.apk

# List connected devices
adb devices

# Install on specific device
adb -s <serial> install app-debug.apk
```

### Log Collection

```bash
# Real-time logs with filter
adb logcat | grep -E "HandshakeCoordinator|NoiseSession|DeviceDeduplication"

# Save logs to file
adb logcat | grep -E "HandshakeCoordinator|NoiseSession" > handshake_logs.txt

# Clear logs (start fresh)
adb logcat -c

# Pull logs from device storage
adb pull /sdcard/pakconnect_logs.txt ./device_logs.txt
```

### Debugging

```bash
# Check BLE permissions
adb shell dumpsys bluetooth_manager

# Check app permissions
adb shell dumpsys package com.yourapp.pakconnect | grep permission

# Force stop app
adb shell am force-stop com.yourapp.pakconnect

# Restart app
adb shell am start -n com.yourapp.pakconnect/.MainActivity
```

---

## ⏱️ Time Budget

| Activity | Time | Cumulative |
|----------|------|------------|
| Build debug APK | 3 min | 3 min |
| Install on 2 devices | 2 min | 5 min |
| Setup logging | 2 min | 7 min |
| Test CG-004 Scenario 1 | 5 min | 12 min |
| Test CG-004 Scenario 2 | 5 min | 17 min |
| Test CG-007 | 7 min | 24 min |
| Save and consolidate logs | 1 min | 25 min |

**Total: 25 minutes** (assuming no issues found)

**If issues found**: +30-60 min for diagnosis and fix validation

---

## 🎓 Success Criteria Summary

### CG-004: Handshake Timing ✅

**Pass if**:
- Phase 1.5 timestamp < Phase 2 timestamp
- "Session established" before "Phase 2"
- No encryption errors

**Fail if**:
- "Noise session not ready" errors
- Phase 2 starts before session established
- Encryption failures during handshake

### CG-007: Dual-Role Device Appearance ✅

**Pass if**:
- Device A shows Device B only in central/chat section
- Device A does NOT show Device B on peripheral side
- No "dual role" badges appear
- Device B shows Device A only as connected contact

**Fail if**:
- Device A shows Device B on both central AND peripheral sides
- "Dual role" badge appears for Device B
- Chat can be opened from either central or peripheral entry
- Missing notification subscription on connected device

---

## 📞 Help and Troubleshooting

### Common Issues

**"Device not found" in adb**:
```bash
# Check USB debugging is enabled
adb devices

# If no devices, try:
adb kill-server && adb start-server
```

**"App won't install"**:
```bash
# Uninstall old version first
adb uninstall com.yourapp.pakconnect

# Re-install
adb install app-debug.apk
```

**"No BLE scan results"**:
- Check location permission granted
- Check Bluetooth enabled
- Check location services enabled (Android requirement)

**"Logs too noisy"**:
```bash
# More specific filter
adb logcat | grep -E "HandshakeCoordinator.*Phase|NoiseSession.*established"

# Exclude debug messages
adb logcat | grep -v "DEBUG"
```

---

## 📝 Report Template

After completing device tests, fill out this template:

```markdown
# Two-Device Test Results

**Date**: YYYY-MM-DD
**Devices**: [Device A model], [Device B model]
**APK Build**: app-debug.apk (git commit: [hash])

## CG-004: Handshake Phase Timing

**Scenario 1 (Normal)**:
- Result: ✅ PASS / ❌ FAIL
- Phase 1.5 → Phase 2 timing: [X]ms
- Errors: [None / Error message]
- Logs: device_a_handshake_normal.txt, device_b_handshake_normal.txt

**Scenario 2 (Race Condition)**:
- Result: ✅ PASS / ❌ FAIL
- Phase 1.5 → Phase 2 timing: [X]ms
- Errors: [None / Error message]
- Logs: device_a_handshake_race.txt, device_b_handshake_race.txt

**Overall CG-004**: ✅ RESOLVED / ❌ CONFIRMED BUG

## CG-007: Dual-Role Device Appearance

**Test**:
- Result: ✅ PASS / ❌ FAIL
- Device A shows Device B on peripheral side: ✅ NO / ❌ YES
- Dual-role badge appears: ✅ NO / ❌ YES
- Notification subscription on connected device: ✅ YES / ❌ NO
- Logs: device_a_dual_role.txt, device_b_dual_role.txt

**Overall CG-007**: ✅ RESOLVED / ❌ CONFIRMED BUG

## Summary

**Confidence Update**:
- Before: 97%
- After: [98% / 100%]

**Next Steps**:
- [Fix CG-004 using FIX-008]
- [Fix CG-007 using additional filtering]
- [Proceed with Phase 2 test development]
```

---

**End of Two-Device Testing Guide**

**Remember**: You can complete 97% → 98.5% confidence with Phase 1 (30 min) before needing devices. Device testing is the final 1.5% → 100%.

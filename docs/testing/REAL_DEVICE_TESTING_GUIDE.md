# Real Device Testing Guide - Phase 2B.1

**Phase:** 2B.1 - Mesh Routing Service Extraction
**Purpose:** Validate routing service behavior on actual BLE hardware
**Duration:** 45-90 minutes (depending on device count)
**Devices:** 2-3 Android devices with BLE support

---

## Overview

Real device testing validates that Phase 2B.1 changes work correctly on actual hardware. Unit tests passed 50/50, but BLE mesh networking requires real devices to verify:

- ✅ Direct message delivery (Device A ↔ B when both online)
- ✅ Relay with offline queue (Device A → B when B offline)
- ✅ Routing service invocation (verify new interface is used)
- ✅ Queue synchronization (missing messages transferred)
- ✅ Multi-hop relay (A → B → C with 3 devices)
- ✅ Topology changes (routing adapts when device disconnects)

---

## Prerequisites

### Hardware Requirements
- **Minimum:** 2 Android devices with BLE support
- **Recommended:** 3 Android devices (enables multi-hop testing)
- **Android Version:** 8.0+ (Android Oreo or later)
- **Battery:** ≥50% charge on all devices

### Software Requirements
```bash
# Check Flutter environment
flutter doctor

# Expected output:
# ✓ Flutter (Channel stable)
# ✓ Android toolchain - Android SDK
# ✓ Connected devices (2-3 devices should show)

# Install APK deployment tools
adb --version  # Should be installed with Android SDK

# Check connected devices
adb devices
# Expected: 2-3 devices in "device" state
```

### Network Requirements
- All devices on same WiFi network (for log collection)
- BLE range: Devices within 10-30 meters line-of-sight
- No major BLE interference (minimize other BLE devices)

---

## Pre-Testing Checklist

### Device Preparation

```bash
# For each device:

# 1. Enable Developer Mode
Settings > About > Build Number (tap 7 times)
# Result: "Developer mode enabled"

# 2. Enable USB Debugging
Settings > Developer Options > USB Debugging
# Result: Checkbox enabled

# 3. Allow App Notifications
Settings > Apps > PakConnect > Notifications
# Result: All toggles ON

# 4. Disable Battery Saver/Doze Mode
Settings > Battery > Battery Optimization > PakConnect > Don't optimize
# Result: PakConnect added to exception list

# 5. Enable Bluetooth
Settings > Bluetooth > ON
# Result: Bluetooth showing active

# 6. Set Display to Stay Awake
Settings > Developer Options > Stay Awake
# Result: Checkbox enabled

# 7. Clear Previous App Data
Settings > Apps > PakConnect > Storage > Clear Cache & Clear Storage
# Result: App reset to clean state
```

### Device Labeling

Create labels for your devices (on sticky notes):

**Device A (Primary):**
- Role: Sender
- Serial: `adb devices` output
- Test Contact: "Device B"

**Device B (Secondary):**
- Role: Receiver / Relay
- Serial: `adb devices` output
- Test Contact: "Device A"

**Device C (Optional - for multi-hop):**
- Role: Relay / Receiver
- Serial: `adb devices` output
- Test Contact: "Device B"

---

## Build & Deploy Test APK

### Step 1: Build Release APK

```bash
# Navigate to project root
cd /home/abubakar/dev/pak_connect

# Clean build artifacts
flutter clean

# Build APK (optimized for testing)
flutter build apk --release

# Expected output:
# ✓ Building APK...
# ✓ APK written to: build/app/outputs/flutter-app.apk (XX.X MB)
```

**Build time:** 3-5 minutes

### Step 2: Verify APK

```bash
# Check APK exists
ls -lh build/app/outputs/flutter-app.apk

# Expected: ~50-100 MB file

# Verify APK is valid
aapt dump badging build/app/outputs/flutter-app.apk | grep package
# Expected: package: name='com.pakconnect.app'
```

### Step 3: Deploy to Devices

```bash
# Connect devices via USB to same computer

# Verify all devices connected
adb devices
# Expected output:
# emulator-5554    device
# FA7AX1A0842      device  (Device A)
# 192.168.1.5:5555 device  (Device B)

# Deploy to all devices
for device in $(adb devices | grep device$ | awk '{print $1}'); do
  echo "Installing APK on $device..."
  adb -s $device install -r build/app/outputs/flutter-app.apk
done

# Expected: "Success" message for each device
```

**Deployment time:** 2-3 minutes per device

### Step 4: Verify Installation

```bash
# For each device, verify app installed
adb -s <device_serial> shell pm list packages | grep pakconnect
# Expected: com.pakconnect.app

# Check app version
adb -s <device_serial> shell dumpsys package com.pakconnect.app | grep versionName
# Expected: versionName=<current_version>
```

---

## Logging Setup for Testing

### Enable Enhanced Logging

Before testing, ensure logging is configured. Edit `lib/main.dart`:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up logging for testing
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.loggerName}: ${record.message}');
  });

  // ... rest of initialization
}
```

### Log Collection Strategy

**Real-time Logs (During Testing):**
```bash
# Terminal 1: Device A logs
adb -s <device_a_serial> logcat -s "flutter" > logs/device_a.log &

# Terminal 2: Device B logs
adb -s <device_b_serial> logcat -s "flutter" > logs/device_b.log &

# Terminal 3: Device C logs (if using 3 devices)
adb -s <device_c_serial> logcat -s "flutter" > logs/device_c.log &

# Keep terminals running during entire test session
```

**Critical Log Patterns to Search For:**

```bash
# Routing service initialization
grep "MeshRoutingService" logs/device_*.log

# Route determination
grep "determineOptimalRoute" logs/device_*.log

# Message relay
grep "RelayEngine.*Relaying" logs/device_*.log

# Queue operations
grep "OfflineMessageQueue" logs/device_*.log

# Errors
grep "ERROR\|Exception\|Failed" logs/device_*.log
```

---

## Test Scenarios

### Scenario 1: Direct Message Delivery (2-3 devices)

**Duration:** 10-15 minutes
**Devices:** A (Sender), B (Receiver), C (Optional)

#### Setup
1. Start app on Device A
2. Start app on Device B
3. Keep Device C offline (if using 3 devices)

#### Execution

**Device A:**
1. Open Contacts tab
2. Tap "Add Contact"
3. Scan Device B's QR code (or manually enter public key)
4. Name: "Device B"
5. Open chat with Device B
6. Send message: "Direct message test #1"

**Device B:**
1. Accept connection from Device A
2. Receive message notification
3. Verify message appears: "Direct message test #1"
4. Send reply: "Message received"

**Device A:**
1. Receive reply notification
2. Verify reply appears: "Message received"

#### Success Criteria
- ✅ Device A can send message to Device B
- ✅ Device B receives message in <2 seconds
- ✅ Device B can reply
- ✅ Device A receives reply in <2 seconds
- ✅ Logs show no errors

#### Log Analysis
```bash
# Search for successful delivery in logs
grep "Message.*sent\|Message.*received" logs/device_a.log
grep "Message.*sent\|Message.*received" logs/device_b.log

# Expected patterns:
# "✅ Message sent to <public_key>"
# "📡 Message received from <public_key>"
```

---

### Scenario 2: Relay with Offline Queue (2-3 devices)

**Duration:** 15-20 minutes
**Devices:** A (Sender), B (Relay/Offline), C (Optional Receiver)

#### Setup
1. Start app on Device A
2. Start app on Device B
3. Establish connection: A ↔ B
4. (Optional) Start app on Device C, connect A → C

#### Execution - Part 1: Offline Queue

**Device A:**
1. Open chat with Device B
2. Send message: "Queue test #1"
3. **Immediately turn off Bluetooth on Device B** (or force-kill app)

**Expected:** Message appears in "pending" state on Device A

**Device A:**
4. Send message: "Queue test #2"
5. Send message: "Queue test #3"
6. Verify 3 messages queued in chat view

**Device B:**
7. Wait 30 seconds
8. **Turn Bluetooth back ON** (or restart app)

**Expected:** Device B receives notification of pending messages

**Device B:**
9. Open app
10. Verify 3 messages received: "Queue test #1", "#2", "#3"

**Device A:**
11. Verify chat shows all 3 messages as delivered (checkmarks)

#### Execution - Part 2: Queue Synchronization (3 devices)

**Device A:**
1. Send message to Device C: "Multi-device queue test"

**Device B:** (Relay node)
1. Verify message passed through

**Device C:**
1. Receive and display message
2. Send reply to Device A

**Device A:**
1. Receive reply

#### Success Criteria
- ✅ Messages queued when Device B offline
- ✅ Queue syncs when Device B comes online
- ✅ All 3 messages delivered to Device B
- ✅ Multi-hop relay works (A → B → C)
- ✅ No message loss
- ✅ No duplicate messages

#### Log Analysis
```bash
# Queue operations
grep "OfflineMessageQueue.*enqueue\|OfflineMessageQueue.*deliver" logs/device_*.log

# Relay operations
grep "🔄.*Relaying\|✅.*Queue.*sync" logs/device_*.log

# Search for errors
grep "ERROR.*Queue\|ERROR.*Relay" logs/device_*.log
```

---

### Scenario 3: Routing Service Verification (2-3 devices)

**Duration:** 10-15 minutes
**Devices:** A, B, C (strongly recommended)

#### Setup
1. Start apps on all 3 devices
2. Establish connections: A ↔ B ↔ C

#### Execution

**Device A:**
1. Send message to Device C: "Routing test #1"

**Device B:** (Relay node)
1. Observe message passing through

**Device C:**
1. Receive message

**Device A:**
2. Turn off Bluetooth on Device B temporarily
3. Wait 5 seconds
4. Turn Bluetooth back on Device B
5. Send message to Device C: "Routing test #2"

**Expected:** Routing should adapt to new topology

#### Success Criteria
- ✅ Message routed through Device B initially
- ✅ MeshRoutingService.determineOptimalRoute() called (in logs)
- ✅ Routing adapts when Device B goes offline
- ✅ Messages still reach Device C after topology change
- ✅ No routes to unreachable devices

#### Log Analysis
```bash
# Verify routing service is used
grep "MeshRoutingService" logs/device_a.log

# Verify route determination
grep "determineOptimalRoute\|🤔 Determining route" logs/device_a.log

# Expected log output:
# "ℹ️ [MeshRoutingService] 🤔 Determining route to <recipient>"
# "✅ [MeshRoutingService] Selected hop: <hop_id> (score: 0.92)"
# "🔄 [MeshRelayEngine] Relaying via <hop_id>"
```

---

### Scenario 4: Topology Changes (2-3 devices)

**Duration:** 10-15 minutes
**Devices:** A, B, C (required)

#### Setup
1. Start apps on all 3 devices
2. Arrange in line: A — B — C
3. Establish connections: A ↔ B, B ↔ C

#### Execution

**Device A:**
1. Send message to Device C: "Topology test #1"

**Observe:** Message routes A → B → C

**Device B:**
2. Force-kill app (simulate disconnect)

**Device A:**
3. Wait 10 seconds
4. Send message to Device C: "Topology test #2"

**Expected:** Message fails or uses alternative route if available

**Device B:**
5. Restart app
6. Wait 15 seconds for reconnection

**Device A:**
7. Send message to Device C: "Topology test #3"

**Expected:** Message routes through B again

#### Success Criteria
- ✅ Routing works with B connected
- ✅ Routing adapts when B disconnects
- ✅ Routing recovers when B reconnects
- ✅ No error crashes
- ✅ Network topology updates in <5 seconds

#### Log Analysis
```bash
# Topology changes
grep "Connection.*added\|Connection.*removed" logs/device_*.log

# Route changes
grep "Selected hop changed\|New route" logs/device_a.log

# Timing of updates
grep "topology.*updated\|route.*calculated" logs/device_*.log
```

---

## Testing Checklist

### Pre-Test (5 minutes)
- [ ] All devices charged >50%
- [ ] All devices on same WiFi
- [ ] Bluetooth enabled on all devices
- [ ] Apps installed and running
- [ ] Log collection started on all devices
- [ ] Devices labeled correctly

### Scenario 1: Direct Message (15 min)
- [ ] A sends message to B
- [ ] B receives in <2 seconds
- [ ] B replies
- [ ] A receives reply in <2 seconds
- [ ] No errors in logs

### Scenario 2: Offline Queue (20 min)
- [ ] B goes offline
- [ ] A sends 3 messages
- [ ] Messages queue on A
- [ ] B comes online
- [ ] All 3 messages delivered to B
- [ ] Multi-hop works (if 3 devices)
- [ ] No duplicates

### Scenario 3: Routing Service (15 min)
- [ ] Messages route through B
- [ ] Logs show MeshRoutingService calls
- [ ] determineOptimalRoute() invoked
- [ ] Routing adapts to topology
- [ ] No unreachable node errors

### Scenario 4: Topology Changes (15 min)
- [ ] Messages work with B connected
- [ ] Messages work when B offline
- [ ] Messages work after B reconnects
- [ ] Recovery time <5 seconds
- [ ] No crashes

### Post-Test (5 minutes)
- [ ] Stop log collection on all devices
- [ ] Collect logs from all devices
- [ ] Take screenshots of final chat states
- [ ] Note any issues observed

**Total Time:** 70-80 minutes (minimum setup + all scenarios)

---

## Log Collection & Analysis

### Collecting Logs

```bash
# Create logs directory
mkdir -p testing_logs/$(date +%Y%m%d_%H%M%S)

# Stop logcat streams
pkill -f "adb.*logcat"

# Save test metadata
cat > testing_logs/test_metadata.txt << EOF
Test Date: $(date)
Devices: 2-3 Android devices
Scenarios: Direct Message, Offline Queue, Routing Service, Topology
Test Duration: 70-80 minutes
Tester: [Your Name]
Notes: [Any issues or observations]
EOF

# Copy logs to analysis directory
cp logs/device_*.log testing_logs/
```

### Analyzing Logs

**Look for these success patterns:**

```bash
# Device A sends successfully
grep "✅.*Message.*sent" testing_logs/device_a.log

# Device B receives successfully
grep "📡.*Message.*received" testing_logs/device_b.log

# Routing service active
grep "MeshRoutingService.*determineOptimalRoute" testing_logs/device_a.log

# Queue sync successful
grep "✅.*Queue.*sync" testing_logs/device_b.log

# No errors
grep -E "ERROR|Exception|Failed|Crash" testing_logs/device_*.log
# Expected: No output (no errors)
```

**Critical Errors to Watch For:**

```bash
# Crashes
grep "FATAL\|crash\|exception" testing_logs/device_*.log

# Message loss
grep "Message lost\|Duplicate message" testing_logs/device_*.log

# Connection issues
grep "Connection failed\|BLE error" testing_logs/device_*.log

# Routing failures
grep "No routes found" testing_logs/device_*.log
```

---

## Success Criteria Summary

### All Tests Must Pass

| Scenario | Success Criteria | Status |
|----------|-----------------|--------|
| Direct Message | A ↔ B messages in <2s | [ ] Pass |
| Offline Queue | 3 messages queued & synced | [ ] Pass |
| Routing Service | MeshRoutingService invoked | [ ] Pass |
| Topology Changes | Routing adapts, recovery <5s | [ ] Pass |
| No Crashes | Zero errors in logs | [ ] Pass |
| Phase 2B.1 Valid | Behavior identical to Phase 2A | [ ] Pass |

---

## Troubleshooting

### Issue: "No routes found to recipient"

**Cause:** Topology not connected
**Solution:**
1. Verify Device B is online
2. Check Bluetooth is enabled
3. Restart app on Device B
4. Re-establish connection

### Issue: Message stuck in pending

**Cause:** Queue sync not triggered
**Solution:**
1. Turn on Bluetooth on offline device
2. Restart app on offline device
3. Wait 15-30 seconds for sync

### Issue: App crashes on one device

**Cause:** Unexpected state
**Solution:**
1. Force-stop app: `adb shell am force-stop com.pakconnect.app`
2. Clear app data: `adb shell pm clear com.pakconnect.app`
3. Reinstall APK
4. Restart test scenario

### Issue: Logs not showing

**Cause:** Log collection not running
**Solution:**
```bash
# Restart logcat
adb -s <device> logcat -c  # Clear buffer
adb -s <device> logcat -s "flutter" > logs/device.log &
# Run test scenario
```

---

## Reporting Results

After completing all scenarios, create test report:

```markdown
# Phase 2B.1 Real Device Test Report

**Test Date:** [Date]
**Devices:** [Device list]
**Duration:** [Minutes]
**Tester:** [Name]

## Results

### Scenario 1: Direct Message
- Status: ✅ PASS / ❌ FAIL
- Messages delivered in: [Time]
- Issues: [None / List]

### Scenario 2: Offline Queue
- Status: ✅ PASS / ❌ FAIL
- Queue sync time: [Time]
- Issues: [None / List]

### Scenario 3: Routing Service
- Status: ✅ PASS / ❌ FAIL
- MeshRoutingService called: Yes/No
- Issues: [None / List]

### Scenario 4: Topology Changes
- Status: ✅ PASS / ❌ FAIL
- Topology recovery time: [Time]
- Issues: [None / List]

## Conclusion

Overall Status: ✅ READY FOR PRODUCTION / ❌ NEEDS FIXES

Phase 2B.1 validation: ✅ COMPLETE / ❌ INCOMPLETE
```

---

## Next Steps

### After Successful Testing
1. ✅ Commit Phase 2B.1 to git
2. ✅ Merge to main branch
3. ✅ Create release notes
4. ✅ Plan Phase 2B.2

### After Failed Testing
1. ❌ Collect logs and analyze root cause
2. ❌ Create bug report
3. ❌ Fix issues
4. ❌ Re-run failed scenario
5. ❌ Repeat until all pass

---

**Ready to start real device testing? Follow the checklist above and let me know when you complete each scenario!**

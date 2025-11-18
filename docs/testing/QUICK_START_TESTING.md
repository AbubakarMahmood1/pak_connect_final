# Quick Start: Real Device Testing for Phase 2B.1

**Time to complete:** 70-90 minutes
**Devices needed:** 2-3 Android devices with BLE

---

## 1️⃣ One-Minute Setup

```bash
# Navigate to project
cd /home/abubakar/dev/pak_connect

# Make sure devices are connected
adb devices
# You should see 2-3 devices listed

# Start the automated testing script
./scripts/real_device_test.sh

# The script will:
# ✅ Check environment
# ✅ Build APK
# ✅ Deploy to all devices
# ✅ Start log collection
# ✅ Guide you through test scenarios
```

---

## 2️⃣ What the Script Does

1. **Builds APK** (3-5 minutes)
   - Creates optimized APK for testing
   - Verifies build success

2. **Deploys to Devices** (2-3 minutes per device)
   - Installs APK on all connected devices
   - Clears previous app data
   - Verifies installation

3. **Starts Log Collection**
   - Opens logcat streams on all devices
   - Saves logs to timestamped directory
   - Captures all important debug info

4. **Guides Test Scenarios**
   - Shows step-by-step instructions
   - Tracks which scenarios completed
   - Analyzes results when done

---

## 3️⃣ What You Need to Do

### Before Testing

```bash
# 1. Connect 2-3 Android devices via USB
# 2. Enable Developer Mode on each device:
#    Settings > About > Build Number (tap 7 times)
# 3. Enable USB Debugging:
#    Settings > Developer Options > USB Debugging > ON
# 4. Trust the computer on each device
# 5. Disable Battery Saver on each device:
#    Settings > Battery > Battery Saver > OFF
```

### During Testing

**For each scenario, the script will tell you:**
- Which device to interact with
- What messages to send
- What to watch for

**Example:**

```
========================================
Scenario 1: Direct Message
========================================

Steps:
1. Device A: Open chat with Device B
2. Device A: Send message 'Direct message test #1'
3. Device B: Receive message (should appear in <2 seconds)
4. Device B: Send reply 'Message received'
5. Device A: Receive reply

Success Criteria:
✅ Messages delivered in <2 seconds
✅ No delays or errors
✅ No duplicate messages

Press Enter when scenario is complete...
```

### After Testing

The script will:
1. Stop collecting logs
2. Analyze results
3. Show success/failure summary
4. Save test report

---

## 4️⃣ Test Scenarios (70-80 minutes total)

| # | Scenario | Duration | Devices | What It Tests |
|---|----------|----------|---------|---------------|
| 1 | Direct Message | 15 min | 2-3 | A ↔ B messaging works |
| 2 | Offline Queue | 20 min | 2-3 | Queue sync when offline |
| 3 | Routing Service | 15 min | 2-3 | MeshRoutingService used |
| 4 | Topology Changes | 15 min | 3 | Routing adapts |

**Total active testing:** 65 minutes
**Including setup:** 75-85 minutes

---

## 5️⃣ Expected Log Output

**While testing, you'll see logs like:**

```
✅ [MeshRoutingService] 🤔 Determining route to <recipient>
✅ [MeshRoutingService] Selected hop: Device B (score: 0.92)
🔄 [MeshRelayEngine] Relaying via Device B
📡 [BLEService] Message sent to Device B
✅ [Device B] Message received from Device A
```

**What you're validating:**

```
✅ Direct message: A sends → B receives in <2s
✅ Offline queue: A queues → B syncs when online
✅ Routing service: determineOptimalRoute() called
✅ Topology changes: Routing adapts to disconnects
```

---

## 6️⃣ Success Criteria

### All Scenarios Must Pass

```
Scenario 1: Direct Message
├─ A sends message to B ✅
├─ B receives in <2 seconds ✅
├─ B sends reply ✅
└─ A receives reply ✅

Scenario 2: Offline Queue
├─ Messages queue when B offline ✅
├─ All messages sync when B online ✅
├─ No duplicate messages ✅
└─ Multi-hop works (if 3 devices) ✅

Scenario 3: Routing Service
├─ MeshRoutingService called ✅
├─ determineOptimalRoute() invoked ✅
├─ Routing adapts to topology ✅
└─ No errors in logs ✅

Scenario 4: Topology Changes
├─ Works with B connected ✅
├─ Works when B offline ✅
├─ Works after B reconnects ✅
└─ Recovery time <5 seconds ✅
```

### Phase 2B.1 Validation

```
✅ Behavior identical to Phase 2A
✅ All routing through new interface
✅ Zero regressions
✅ All messages delivered correctly
✅ No crashes or errors
```

---

## 7️⃣ Troubleshooting Quick Fixes

### "No devices connected"
```bash
# Check USB cable connection
# Enable USB Debugging on device
# Authorize computer on device
adb devices  # Should show devices
```

### "APK installation failed"
```bash
# Clear old version
adb shell pm clear com.pakconnect.app

# Reinstall
adb install build/app/outputs/flutter-app.apk
```

### "Messages not delivering"
```bash
# 1. Verify both devices are online
# 2. Restart app on one device
# 3. Re-establish connection
# 4. Try sending message again
```

### "Logs not showing"
```bash
# Restart log collection
pkill -f "adb.*logcat"
adb -s <device> logcat -c
adb -s <device> logcat -s "flutter" > device.log &
```

---

## 8️⃣ After Testing

### If All Scenarios Pass ✅

```bash
# Navigate to test logs
cd testing_logs/$(ls -t testing_logs | head -1)

# View test report
cat test_metadata.txt

# Commit Phase 2B.1
git add .
git commit -m "feat(routing): Phase 2B.1 - Mesh Routing Service extraction

Validated with real device testing:
- Direct message delivery: PASS
- Offline queue synchronization: PASS
- Routing service integration: PASS
- Topology adaptation: PASS
- Zero regressions from Phase 2A

Tests: 50 automated tests + real device validation"

git push origin refactor/phase2b-ble-service-split
```

### If Any Scenario Fails ❌

```bash
# Analyze logs
grep "ERROR\|Exception\|Failed" testing_logs/*/device_*.log

# Identify root cause
# Fix issue
# Re-run failed scenario only
```

---

## 9️⃣ Real Device Setup (Visual Guide)

```
┌─────────────────┐
│  Device A       │
│  (Sender)       │ ──Bluetooth── ┌─────────────────┐
│                 │               │  Device B       │
│  Contacts:      │               │  (Relay)        │
│  • Device B ✓   │               │                 │
│                 │               │  Contacts:      │
│  Chat with B:   │               │  • Device A ✓   │
│  msg1: pending  │               │  • Device C ✓   │
│  msg2: pending  │               │                 │
│  msg3: pending  │               │  Chat with A:   │
│                 │               │  [waiting...]   │
└─────────────────┘               │                 │
                                  └─────────────────┘
                                        │
                                   Bluetooth
                                        │
                                  ┌─────────────────┐
                                  │  Device C       │
                                  │  (Optional)     │
                                  │                 │
                                  │  Contacts:      │
                                  │  • Device B ✓   │
                                  │  • Device A ✓   │
                                  │                 │
                                  │  Chat with A:   │
                                  │  [waiting...]   │
                                  └─────────────────┘
```

---

## 🔟 Running Without Script (Manual)

If the script doesn't work, do this manually:

```bash
# Step 1: Build APK
cd /home/abubakar/dev/pak_connect
flutter clean
flutter build apk --release

# Step 2: Deploy
adb install -r build/app/outputs/flutter-app.apk

# Step 3: Start logs on each device
adb logcat -s "flutter" > device_a.log &
# (repeat for other devices in separate terminals)

# Step 4: Run test scenarios manually
# Follow steps in docs/testing/REAL_DEVICE_TESTING_GUIDE.md

# Step 5: Stop logs
pkill -f "adb.*logcat"

# Step 6: Analyze
grep "✅\|ERROR" device_*.log
```

---

## Summary

```
✅ Run: ./scripts/real_device_test.sh
✅ Connect 2-3 devices via USB
✅ Follow scenario instructions
✅ Collect results
✅ Validate Phase 2B.1
✅ Commit if all pass

Estimated time: 75-85 minutes
Expected result: 100% scenario pass rate
```

**Ready? Let's validate Phase 2B.1!** 🚀

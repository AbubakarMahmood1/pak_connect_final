# Quick Start: PakConnect Android Device Validation

**Time to complete:** 70-90 minutes
**Devices needed:** 2-3 Android devices with BLE

Use `docs/testing/DEVICE_VALIDATION_STATUS.md` as the live evidence matrix.
This guide is an execution aid; completing the menu does not itself turn a row
into `PASS` without saved device/build/log evidence. The exact two-phone
baseline run is
[TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md](TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md).

---

## 1️⃣ One-Minute Setup

```bash
# Run from the repository root
cd /path/to/pak_connect

# Make sure devices are connected
adb devices
# You should see 2-3 devices listed

# Start the automated testing script
bash scripts/real_device_test.sh --debug

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
   - Creates a debug APK by default
   - Verifies build success

2. **Deploys to Devices** (2-3 minutes per device)
   - Installs APK on all connected devices
   - Preserves app data (`adb install -r`); clear data manually when a scenario
     requires a fresh install
   - Verifies installation

3. **Starts Log Collection**
   - Opens logcat streams on all devices
   - Saves logs to timestamped directory
   - Captures all important debug info

4. **Guides Test Scenarios**
   - Shows step-by-step instructions
   - Lets the operator invoke a simple log-pattern summary
   - Leaves scenario state/evidence recording to the operator

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

Use menu option 6 to run the script's pattern-counting log summary, then option
7 to stop log collection. The script saves raw per-device logs; it does not
decide scenario PASS/FAIL or write the live evidence matrix for you.

---

## 4️⃣ Smoke Scenarios (70-80 minutes total)

| # | Scenario | Duration | Devices | What It Tests |
|---|----------|----------|---------|---------------|
| 1 | Direct Message | 15 min | 2-3 | A ↔ B messaging works |
| 2 | Offline Queue | 20 min | 2-3 | Queue sync when offline |
| 3 | Routing Service | 15 min | 2-3 | MeshRoutingService used |
| 4 | Topology Changes | 15 min | 3 | Routing adapts |

**Total active testing:** 65 minutes
**Including setup:** 75-85 minutes

These four menu scenarios are a subset of the authoritative matrix. XX/KK,
reverse-role discovery, exact-route fragmentation, SQLCipher, permissions, and
privacy/log inspection still need their dedicated matrix rows.

---

## 5️⃣ Expected Log Output

**Illustrative patterns (exact log wording may differ):**

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

## 6️⃣ Scenario Acceptance Targets

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

### Bounded Smoke Validation

```
□ Direct and queued messages observed on the intended peer
□ No duplicate delivery in the exercised scenarios
□ Reconnect/topology behavior recorded with timestamps
□ No crash or unexpected severe/error log in the captured window
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
adb install build/app/outputs/flutter-apk/app-debug.apk
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

1. Exit the script cleanly so logcat processes stop.
2. Record device model, Android version, app commit, build mode, timestamps,
   scenario outcome, and the relevant log filenames.
3. Redact public identifiers or other sensitive material before sharing logs.
4. Update `docs/testing/DEVICE_VALIDATION_STATUS.md` only for rows actually
   observed. Keep untested rows `BLOCKED` or `NOT RUN`.
5. For any failure, preserve the reproduction and logs before changing code,
   then rerun the affected row after a fix.

Do not commit or push solely because the four smoke scenarios completed; the
full readiness gate includes the remaining protocol, SQLCipher, lifecycle, and
privacy rows.

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
# Step 1: Build a debug APK
cd /path/to/pak_connect
flutter clean
flutter build apk --debug

# Step 2: Deploy
adb install -r build/app/outputs/flutter-apk/app-debug.apk

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
✅ Run: bash scripts/real_device_test.sh --debug
✅ Connect 2-3 devices via USB
✅ Follow scenario instructions
✅ Collect results
✅ Record exact evidence in the device validation matrix
✅ Keep unobserved rows blocked/not run

Estimated time: 75-85 minutes
Required result for promoted rows: all stated observations captured
```

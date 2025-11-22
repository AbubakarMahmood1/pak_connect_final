# Performance Baseline - PakConnect

**Baseline Date**: 2025-11-12
**Git Tag**: `v1.0-pre-refactor`
**Purpose**: Track performance metrics before and after P2 refactoring

---

## Measurement Status

🚫 **Status**: Blocked on instrumented real-device testing

The release-grade performance pass still requires:
- Two or more Android BLE devices on the bench
- Production (`--release`) builds with logging enabled
- Controlled RF environment for repeatable BLE measurements

Until hardware access is available, we record the host-only benchmarks produced by `test/performance_getAllChats_benchmark_test.dart` (captured in `flutter_test_latest.log`).

### Interim Repository Benchmarks (Host Machine, 2025-11-19)

| Scenario | Dataset | Result | Source |
| --- | --- | --- | --- |
| getAllChats benchmark | 10 contacts × 10 messages | 12 ms total (1.2 ms/chat) | `flutter_test_latest.log` 7475-7525 |
| getAllChats benchmark | 50 contacts × 10 messages | 5 ms total (0.1 ms/chat) | `flutter_test_latest.log` 7845-7890 |
| getAllChats benchmark | 100 contacts × 10 messages | 5 ms total (0.1 ms/chat) | `flutter_test_latest.log` 8074-8088 |

> These values provide a reproducible baseline for the SQLite-heavy flows while we wait for the full BLE/device metrics.

### Real-Device Measurement Plan

1. **Prepare hardware**: Two BLE-capable Android devices (A+B) with developer mode enabled, plus optional Device C for mesh relay. Charge fully and keep within 1–2 m for consistent RSSI.
2. **Build & install release APK**:
   ```bash
   flutter build apk --release
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```
   Repeat for every device that will participate.
3. **Enable performance logging**: Launch the installed release build (or `flutter run --release`) and capture logs via `adb logcat -s PerformanceMonitor,AppCore,BleService` so timestamps for startup/BLE events are preserved.
4. **Capture startup metrics**: For each device, clear the app (`adb shell pm clear com.pakconnect`), then run `adb shell am start -W com.pakconnect/.MainActivity` and record `TotalTime`, `WaitTime`, `ThisTime`.
5. **Measure BLE init & handshake**:
   - On Device A, turn on advertising (app home screen).
   - On Device B, initiate discovery/connection.
   - Use `adb logcat` timestamps from `[BleHandshake]`/`[NoiseHandshake]` logs to measure: MTU negotiation, connection established, Noise handshake complete.
6. **Message latency**:
   - Keep A↔B connected.
   - Send 10 text messages in each direction; capture send and receive timestamps from logcat (`[MeshMessaging]` entries) or by instrumenting the UI stopwatch.
   - Compute average delta per direction.
7. **Memory footprint**:
   - Immediately after cold start and after 10 minutes of active messaging, run `adb shell dumpsys meminfo com.pakconnect` on each device and note `TOTAL`, `Dalvik Heap`, and `Native Heap`.
8. **Mesh relay (optional)**:
   - Introduce Device C; send A→C with B as relay.
   - Capture processing time from `[MeshRelayEngine]` logs.
9. **Record results**: Append the measurements (device model, OS version, numbers) to the tables below so we can compare future runs against the same hardware.

---

## Metrics to Collect

### 1. App Startup Performance

**What to Measure**:
- Cold start time (app not in memory)
- Warm start time (app in background)
- Hot start time (app in foreground)

**How to Measure**:
```bash
# Android Debug Bridge (ADB)
adb shell am start -W -n com.pakconnect/.MainActivity

# Look for: TotalTime value
```

**Target**: Document baseline, maintain or improve after refactoring

**Results**: TBD (requires real device)

---

### 2. BLE Initialization Performance

**What to Measure**:
- BLE adapter initialization time
- Time to start advertising
- Time to start scanning
- First device discovery time

**How to Measure**:
- Add timestamps in BLEService initialization
- Log time from `initialize()` call to `initialized` state

**Target**: <500ms for BLE ready

**Results**: TBD (requires real device)

---

### 3. Connection Performance

**What to Measure**:
- Time to establish first BLE connection
- MTU negotiation time
- Handshake completion time (Phase 0 → Phase 2)

**How to Measure**:
- Timestamps in HandshakeCoordinator
- Log each handshake phase completion

**Target**:
- Connection: <2s
- Handshake: <3s

**Results**: TBD (requires real device)

---

### 4. Message Latency

**What to Measure**:
- End-to-end message delivery time
- Encryption time
- Fragmentation time
- BLE transmission time

**How to Measure**:
- Add timestamp to message send
- Log timestamp on message receive
- Calculate delta

**Target**: <500ms for direct connection

**Results**: TBD (requires real device)

---

### 5. Memory Footprint

**What to Measure**:
- Heap size at startup
- Heap size after 10 minutes of use
- Heap size after 100 messages
- Peak memory usage

**How to Measure**:
```bash
# Android Memory Profiler
adb shell dumpsys meminfo com.pakconnect

# Or use Flutter DevTools Memory tab
```

**Target**: <100MB heap for typical usage

**Results**: TBD (requires real device)

---

### 6. Mesh Relay Performance

**What to Measure**:
- Relay processing time
- Duplicate detection time
- Route calculation time
- Network topology analysis time

**How to Measure**:
- Timestamps in MeshRelayEngine
- Log processing time for each relay decision

**Target**: <100ms relay decision time

**Results**: TBD (requires real device)

---

### 7. Database Query Performance

**What to Measure**:
- getAllChats() execution time
- getMessages() execution time
- saveMessage() execution time
- FTS search time

**How to Measure**:
- Already tracked by DatabaseQueryOptimizer
- Check slow query logs

**Target**:
- Queries: <50ms
- Writes: <20ms

**Results**: Can be measured in tests (see DatabaseQueryOptimizer tests)

---

## Test Procedure

### Setup
1. Build release APK: `flutter build apk --release`
2. Install on 2+ Android devices
3. Clear app data
4. Fresh start

### Test Scenarios

#### Scenario 1: Cold Start
1. Force stop app
2. Clear from memory
3. Launch app
4. Measure startup time

#### Scenario 2: First Connection
1. Device A: Start app
2. Device B: Start app
3. Wait for discovery
4. Initiate connection
5. Measure handshake time

#### Scenario 3: Message Send
1. Establish connection
2. Send 10 messages
3. Measure average latency
4. Check memory usage

#### Scenario 4: Mesh Relay
1. Set up 3 devices (A → B → C)
2. A sends message to C (via B)
3. Measure relay time
4. Check duplicate detection

#### Scenario 5: Long-Running
1. Run app for 1 hour
2. Send 100 messages
3. Check memory leaks
4. Measure performance degradation

---

## Baseline Results

### To Be Collected

Once real device testing is performed, results will be documented here in this format:

```
App Startup (Cold):     XXX ms
BLE Initialization:     XXX ms
First Connection:       XXX ms
Handshake Completion:   XXX ms
Message Latency:        XXX ms
Memory (Startup):       XXX MB
Memory (After 1hr):     XXX MB
Relay Decision Time:    XXX ms
```

---

## Post-Refactoring Comparison

After P2 refactoring completion (Week 12), re-run all tests and compare:

| Metric | Baseline | After Refactoring | Change |
|--------|----------|-------------------|--------|
| App Startup (Cold) | TBD | TBD | TBD |
| BLE Initialization | TBD | TBD | TBD |
| First Connection | TBD | TBD | TBD |
| Handshake | TBD | TBD | TBD |
| Message Latency | TBD | TBD | TBD |
| Memory (Startup) | TBD | TBD | TBD |
| Memory (1hr) | TBD | TBD | TBD |
| Relay Time | TBD | TBD | TBD |

**Goal**: All metrics ≤ baseline (no performance regression)

---

## Notes

- Performance testing postponed until after refactoring begins
- Refactoring focuses on architecture, not performance optimization
- Goal is to maintain current performance, not improve it (yet)
- Performance optimization can be Phase 7 (future work)

---

**Status**: This document will be updated when real device testing is performed.

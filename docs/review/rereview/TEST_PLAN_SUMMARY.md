# Test Plan - Executive Summary

**Created**: 2025-11-11  
**Status**: Ready for Execution  
**Total Tests**: 73 tests (71 single-device + 2 two-device procedures)  
**Estimated Time**: 4.5 hours (4.1 hours single-device + 25 min two-device)

---

## 📊 Test Distribution

```
┌─────────────────────────────────────────────────────────┐
│  TEST CATEGORY BREAKDOWN                                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Unit Tests (70%)           ████████████████████  50    │
│  Integration Tests (20%)    █████              14       │
│  Benchmark Tests (5%)       ██                  4       │
│  Device Tests (5%)          ██                  5       │
│                                                         │
│  TOTAL: 73 tests                                        │
└─────────────────────────────────────────────────────────┘
```

---

## 🎯 Confidence Gaps Mapped

| Gap | Description | Priority | Tests | Device? | Time | File to Create |
|-----|-------------|----------|-------|---------|------|----------------|
| **CG-001** | Nonce race condition | P0 🔴 | 5 | ❌ No | 5 min | `noise_session_concurrency_test.dart` |
| **CG-002** | N+1 query (getAllChats) | P0 🔴 | 3 | ❌ No | 10 min | `chats_repository_benchmark_test.dart` |
| **CG-003** | MessageFragmenter untested | P1 🟡 | 15 | ❌ No | 15 min | `message_fragmenter_test.dart` |
| **CG-004** | Handshake phase timing | P0 🔴 | 1 | ✅ YES | 15 min | Manual procedure (2 devices) |
| **CG-005** | Flaky tests (11 skipped) | P1 🟡 | 11 | ❌ No | 3 hrs | Fix existing files |
| **CG-006** | Database optimization | P1 🟡 | 5 | ❌ No | 20 min | `database_benchmarks_test.dart` |
| **CG-007** | Dual-role device appearance | P1 🟡 | 1 | ✅ YES | 10 min | Manual procedure (2 devices) |
| **CG-008** | StreamProvider memory leaks | P0 🔴 | 3 | ❌ No | 5 min | `provider_lifecycle_test.dart` |
| **CG-009** | Private key memory leak | P0 🔴 | 4 | ❌ No | 5 min | `secure_key_test.dart` |
| **CG-010** | BLEService untested | P1 🟡 | 25 | ❌ No | 10 min | `ble_service_test.dart` |

**Legend**: 🔴 P0 = Critical (blocks production), 🟡 P1 = High priority

---

## ⚡ Quick Commands

### Run All P0 Tests (Critical - Week 1)
```bash
# Security tests (10 min)
flutter test test/core/security/noise/noise_session_concurrency_test.dart  # CG-001
flutter test test/core/security/secure_key_test.dart                       # CG-009

# Performance tests (30 min)
flutter test test/performance/chats_repository_benchmark_test.dart         # CG-002
flutter test test/performance/database_benchmarks_test.dart                # CG-006

# Integration tests (5 min)
flutter test test/presentation/providers/provider_lifecycle_test.dart      # CG-008
```

### Run All P1 Tests (High Priority - Week 1)
```bash
# MessageFragmenter (15 min)
flutter test test/core/utils/message_fragmenter_test.dart                  # CG-003

# BLEService (10 min)
flutter test test/data/services/ble_service_test.dart                      # CG-010

# Flaky test fixes (3 hours)
timeout 60 flutter test test/mesh_relay_flow_test.dart                     # CG-005
timeout 60 flutter test test/chat_lifecycle_persistence_test.dart          # CG-005
```

### Run Device Tests (Week 2)
```bash
# Manual procedures - requires 2 physical devices
# See COMPREHENSIVE_TEST_PLAN.md sections CG-004 and CG-007
```

---

## 📈 Expected Outcomes

### Before Fixes
| Metric | Current State |
|--------|---------------|
| **Test Coverage** | 31% (57/183 files) |
| **Flaky Tests** | 11 skipped/hanging |
| **getAllChats (100 contacts)** | ~1000ms (N+1 query) |
| **MessageFragmenter Coverage** | 0% (ZERO tests) |
| **BLEService Coverage** | 0% (ZERO tests) |
| **Nonce Race Conditions** | Possible (no mutex) |
| **Memory Leaks** | 8 StreamProviders leak |
| **Private Key Leaks** | Keys remain in heap |

### After Fixes
| Metric | Target State |
|--------|--------------|
| **Test Coverage** | 85%+ (150+/183 files) |
| **Flaky Tests** | 0 (all stable) |
| **getAllChats (100 contacts)** | <100ms (single JOIN) |
| **MessageFragmenter Coverage** | 100% (15 tests) |
| **BLEService Coverage** | 60%+ (25 tests) |
| **Nonce Race Conditions** | Impossible (mutex enforced) |
| **Memory Leaks** | 0 (autoDispose added) |
| **Private Key Leaks** | 0 (SecureKey wrapper) |

**Key Improvement**: 20x performance improvement + critical security fixes

---

## 📋 Implementation Checklist

### Week 1: Single-Device Tests (4.1 hours)

**Day 1: Critical Security & Performance (2 hours)**
- [ ] Create `test/core/security/noise/noise_session_concurrency_test.dart` (CG-001)
  - [ ] Test 1: Concurrent encrypt uses unique nonces
  - [ ] Test 2: Nonce counter increments sequentially
  - [ ] Test 3: Rekey enforced after 10k messages
  - [ ] Test 4: Decrypt rejects replayed nonces
  - [ ] Test 5: Mixed concurrent encrypt/decrypt
- [ ] Create `test/core/security/secure_key_test.dart` (CG-009)
  - [ ] Test 1: SecureKey zeros original immediately
  - [ ] Test 2: SecureKey.destroy() zeros internal copy
  - [ ] Test 3: NoiseSession uses SecureKey wrapper
  - [ ] Test 4: Memory inspection (manual validation)
- [ ] Create `test/performance/chats_repository_benchmark_test.dart` (CG-002)
  - [ ] Test 1: getAllChats with 100 contacts <100ms
  - [ ] Test 2: getAllChats with 500 contacts <200ms
  - [ ] Test 3: Single query execution (not N+1)
- [ ] Create `test/performance/database_benchmarks_test.dart` (CG-006)
  - [ ] Test 1: Chat loading performance
  - [ ] Test 2: FTS5 search performance
  - [ ] Test 3: Index usage validation
  - [ ] Test 4: Message insertion batch
  - [ ] Test 5: Seen messages cleanup

**Day 2: MessageFragmenter + Providers (3 hours)**
- [ ] Create `test/core/utils/message_fragmenter_test.dart` (CG-003)
  - [ ] Test 1: Fragment 250-byte message into 3 chunks
  - [ ] Test 2: Reassemble out-of-order chunks
  - [ ] Test 3: Handle duplicate chunks
  - [ ] Test 4: Timeout missing chunks (30s)
  - [ ] Test 5: Interleaved messages from different senders
  - [ ] Test 6: Empty message
  - [ ] Test 7: Single-chunk message
  - [ ] Test 8: Large 10KB message
  - [ ] Test 9: MTU boundary testing
  - [ ] Test 10: Memory bounds (max 100 pending)
  - [ ] Test 11: Chunk header format
  - [ ] Test 12: Base64 encoding/decoding
  - [ ] Test 13: Fragment cleanup on timeout
  - [ ] Test 14: Corruption detection (skip - future)
  - [ ] Test 15: Concurrent reassembly
- [ ] Create `test/presentation/providers/provider_lifecycle_test.dart` (CG-008)
  - [ ] Test 1: StreamProviders dispose when widget disposed
  - [ ] Test 2: Multiple StreamProviders cleanup
  - [ ] Test 3: No memory leak (100 cycles)

**Day 3: Flaky Test Fixes (3 hours)**
- [ ] Fix `test/mesh_relay_flow_test.dart` (CG-005)
  - [ ] Investigate hangs (lines 19, 20)
  - [ ] Add proper async/await
  - [ ] Add timeouts (10 seconds)
  - [ ] Remove `skip: true` flags
  - [ ] Verify all 3 tests pass
- [ ] Fix `test/chat_lifecycle_persistence_test.dart` (CG-005)
  - [ ] Investigate 3 skipped tests
  - [ ] Add TestSetup harness
  - [ ] Remove `skip: true` flags
  - [ ] Verify tests pass
- [ ] Fix `test/chats_repository_sqlite_test.dart` (CG-005)
  - [ ] Fix UserPreferences setup test
  - [ ] Add TestSetup harness for FlutterSecureStorage
  - [ ] Remove skip flag
  - [ ] Verify test passes
- [ ] Fix `test/contact_repository_sqlite_test.dart` (CG-005)
  - [ ] Fix security upgrade test
  - [ ] Add TestSetup harness
  - [ ] Remove skip flag
  - [ ] Verify test passes

**Day 4-5: BLEService Tests (2 days)**
- [ ] Create `test/data/services/ble_service_test.dart` (CG-010)
  - [ ] Group 1: Initialization (5 tests)
    - [ ] Test 1: Initialization without BLE permission
    - [ ] Test 2: Initialization with BLE disabled
    - [ ] Test 3: Initialization success
    - [ ] Test 4: Initialization with mock adapter
    - [ ] Test 5: State transitions
  - [ ] Group 2: Advertising (5 tests)
    - [ ] Test 6: Start advertising
    - [ ] Test 7: Stop advertising
    - [ ] Test 8: Advertising data format
    - [ ] Test 9: Advertisement interval
    - [ ] Test 10: Advertisement error handling
  - [ ] Group 3: Scanning (5 tests)
    - [ ] Test 11: Start scanning
    - [ ] Test 12: Stop scanning
    - [ ] Test 13: Scan result filtering
    - [ ] Test 14: Scan timeout
    - [ ] Test 15: Scan error handling
  - [ ] Group 4: Connection (5 tests)
    - [ ] Test 16: Connect to device
    - [ ] Test 17: Disconnect from device
    - [ ] Test 18: Connection timeout
    - [ ] Test 19: MTU negotiation
    - [ ] Test 20: Connection state tracking
  - [ ] Group 5: Messaging (5 tests)
    - [ ] Test 21: Send message
    - [ ] Test 22: Receive message
    - [ ] Test 23: Message queue
    - [ ] Test 24: Message retry
    - [ ] Test 25: Message error handling

### Week 2: Two-Device Tests (25 minutes)

**Device Test Setup**
- [ ] Prepare 2 physical devices (Android/iOS)
- [ ] Build debug APK with verbose logging
- [ ] Install on both devices
- [ ] Grant BLE permissions

**CG-004: Handshake Phase Timing (15 minutes)**
- [ ] Setup devices with debug builds
- [ ] Run normal handshake scenario
- [ ] Verify Phase 1.5 completes before Phase 2
- [ ] Run race condition trigger scenario
- [ ] Collect logs from both devices
- [ ] Analyze log timestamps
- [ ] Verify no "Noise session not ready" errors

**CG-007: Dual-Role Device Appearance (10 minutes)**
- [ ] Install app on Device A and Device B
- [ ] Device A: Scan for nearby devices
- [ ] Device A: Connect to Device B (central initiator)
- [ ] Collect logs from both devices
- [ ] Verify Device A shows Device B only in central/chat section
- [ ] Verify Device A does NOT show Device B on peripheral side

---

## 🎯 Success Criteria

### Critical (Must Pass Before Production)
✅ **CG-001**: No nonce collisions (all 5 tests pass)  
✅ **CG-002**: 20x performance improvement (<100ms for 100 chats)  
✅ **CG-004**: Phase 2 waits for Phase 1.5 (device test)  
✅ **CG-008**: All StreamProviders dispose correctly  
✅ **CG-009**: Private keys zeroed on destroy  

### High Priority (Before Demo)
✅ **CG-003**: MessageFragmenter 100% coverage (15/15 tests)  
✅ **CG-005**: All flaky tests stable (11/11 passing)  
✅ **CG-006**: All database queries under targets  
✅ **CG-007**: Self-connection prevented (device test)  
✅ **CG-010**: BLEService 60%+ coverage (25/25 tests)  

### Overall Targets
- **Test Pass Rate**: 100% (currently ~96% due to flaky tests)
- **Coverage**: 85%+ (currently 31%)
- **Performance**: getAllChats <100ms (currently ~1000ms)
- **Reliability**: Zero test hangs (all complete in <60s)

---

## 📚 Documentation References

- **Full Test Plan**: `COMPREHENSIVE_TEST_PLAN.md` (18,000+ words, detailed implementations)
- **Quick Start**: `TEST_PLAN_QUICK_START.md` (commands and file locations)
- **Architecture**: `CLAUDE.md` (system design and patterns)
- **Testing Strategy**: `TESTING_STRATEGY.md` (testing fundamentals)
- **FYP Review**: `docs/review/EXECUTIVE_SUMMARY.md` (confidence gaps source)
- **Fix Roadmap**: `docs/review/RECOMMENDED_FIXES.md` (P0-P2 fixes with code examples)

---

**Next Steps**:
1. Review this summary
2. Read `COMPREHENSIVE_TEST_PLAN.md` for detailed test implementations
3. Start with Day 1 tests (critical security & performance)
4. Track progress using checklist above
5. Execute two-device tests in Week 2

---

**Status**: ✅ READY FOR EXECUTION

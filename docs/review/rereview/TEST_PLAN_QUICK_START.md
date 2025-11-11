# Test Plan - Quick Start Guide

**Full Documentation**: See `COMPREHENSIVE_TEST_PLAN.md`

---

## 🎯 Quick Overview

**Total Tests Mapped**: 73 tests covering 10 confidence gaps
**Execution Time**: 4.5 hours (4.1 hours single-device + 25 min two-device)
**Coverage Target**: 85% (up from current 31%)

---

## ⚡ Quick Commands

### Run All Critical Tests (P0 - Week 1)
```bash
# Security tests (10 minutes)
flutter test test/core/security/noise/noise_session_concurrency_test.dart
flutter test test/core/security/secure_key_test.dart

# Performance tests (30 minutes)
flutter test test/performance/chats_repository_benchmark_test.dart
flutter test test/performance/database_benchmarks_test.dart

# Integration tests (5 minutes)
flutter test test/presentation/providers/provider_lifecycle_test.dart
```

### Run High Priority Tests (P1 - Week 1)
```bash
# MessageFragmenter (15 minutes)
flutter test test/core/utils/message_fragmenter_test.dart

# BLEService (10 minutes)
flutter test test/data/services/ble_service_test.dart

# Flaky test fixes (3 hours)
timeout 60 flutter test test/mesh_relay_flow_test.dart
timeout 60 flutter test test/chat_lifecycle_persistence_test.dart
```

---

## 📋 Test Categories

### ✅ Single-Device (VM-Compatible)

| ID | Test | File | Tests | Time |
|----|------|------|-------|------|
| CG-001 | Nonce race | `noise_session_concurrency_test.dart` | 5 | 5 min |
| CG-002 | N+1 query | `chats_repository_benchmark_test.dart` | 3 | 10 min |
| CG-003 | MessageFragmenter | `message_fragmenter_test.dart` | 15 | 15 min |
| CG-005 | Flaky tests | (Multiple files) | 11 | 3 hrs |
| CG-006 | DB benchmarks | `database_benchmarks_test.dart` | 5 | 20 min |
| CG-008 | Provider leaks | `provider_lifecycle_test.dart` | 3 | 5 min |
| CG-009 | Key memory leak | `secure_key_test.dart` | 4 | 5 min |
| CG-010 | BLEService | `ble_service_test.dart` | 25 | 10 min |

**Subtotal**: 71 tests, ~4.1 hours

### ❌ Two-Device (Physical Phones Required)

| ID | Test | Procedure | Devices | Time |
|----|------|-----------|---------|------|
| CG-004 | Handshake timing | Manual procedure | 2 | 15 min |
| CG-007 | Self-connection | Manual procedure | 1 | 10 min |

**Subtotal**: 2 procedures, ~25 minutes

---

## 🚀 Execution Order

### Day 1: Critical Security (2 hours)
```bash
flutter test test/core/security/noise/noise_session_concurrency_test.dart
flutter test test/core/security/secure_key_test.dart
flutter test test/performance/chats_repository_benchmark_test.dart
flutter test test/performance/database_benchmarks_test.dart
```

### Day 2: MessageFragmenter + Providers (3 hours)
```bash
flutter test test/core/utils/message_fragmenter_test.dart
flutter test test/presentation/providers/provider_lifecycle_test.dart
```

### Day 3: Flaky Test Fixes (3 hours)
```bash
# Fix each flaky test individually
timeout 60 flutter test test/mesh_relay_flow_test.dart
timeout 60 flutter test test/chat_lifecycle_persistence_test.dart
timeout 60 flutter test test/chats_repository_sqlite_test.dart
timeout 60 flutter test test/contact_repository_sqlite_test.dart
```

### Day 4-5: BLEService Tests (2 days)
```bash
flutter test test/data/services/ble_service_test.dart
```

### Week 2: Device Tests (30 minutes)
```
1. Setup 2 physical devices with debug builds
2. Run handshake timing test (15 min)
3. Run self-connection test (10 min)
4. Collect logs and analyze
```

---

## ✅ Success Criteria

### Critical (Must Pass)
- ✅ Nonce race: No collisions in 100 concurrent encrypts
- ✅ N+1 query: <100ms for 100 chats (20x improvement)
- ✅ Handshake: Phase 2 waits for Phase 1.5
- ✅ Providers: All dispose correctly (no memory leaks)
- ✅ Keys: Zeroed on destroy (no heap leaks)

### High Priority
- ✅ MessageFragmenter: 100% coverage, 15/15 tests pass
- ✅ Flaky tests: 11/11 stable (no hangs)
- ✅ BLEService: 60%+ coverage, 25/25 tests pass
- ✅ Self-connection: Device filters own ads

### Overall Targets
- **Test Pass Rate**: 100% (currently ~96%)
- **Coverage**: 85% (currently 31%)
- **Performance**: 20x improvement in getAllChats
- **Reliability**: Zero test hangs, all complete in <60s

---

## 📊 Expected Outcomes

### After P0 Fixes (Week 1)
- 🔐 All critical security vulnerabilities resolved (CVSS 7.5-9.1)
- ⚡ 20x performance improvement in chat loading
- 💾 No memory leaks from providers
- 🔄 No race conditions in encryption path

### After P1 Fixes (Week 1)
- ✅ 100% MessageFragmenter coverage
- ✅ 60%+ BLEService coverage
- ✅ All flaky tests resolved
- ✅ 85%+ overall coverage

---

## 🔧 Common Issues

**"NoiseSession not established"**
```dart
// Add state check before encrypt/decrypt
if (_state != NoiseSessionState.established) {
  throw StateError('Session not established');
}
```

**"Database is locked"**
```dart
// Use transactions
await db.transaction((txn) async {
  await txn.insert('table', data);
});
```

**"Test hangs indefinitely"**
```dart
// Add timeout
test('my test', () async {
  // ...
}, timeout: Timeout(Duration(seconds: 10)));
```

**"FlutterSecureStorage MissingPluginException"**
```dart
// Use TestSetup harness
setUpAll(() async {
  await TestSetup.initializeTestEnvironment();
});
```

---

## 📚 File Locations

**New Test Files to Create**:
```
test/core/security/noise/noise_session_concurrency_test.dart     (CG-001)
test/core/security/secure_key_test.dart                          (CG-009)
test/core/utils/message_fragmenter_test.dart                     (CG-003)
test/data/services/ble_service_test.dart                         (CG-010)
test/performance/chats_repository_benchmark_test.dart            (CG-002)
test/performance/database_benchmarks_test.dart                   (CG-006)
test/presentation/providers/provider_lifecycle_test.dart         (CG-008)
```

**Existing Files to Fix**:
```
test/mesh_relay_flow_test.dart                  (CG-005 - remove skip)
test/chat_lifecycle_persistence_test.dart       (CG-005 - remove skip)
test/chats_repository_sqlite_test.dart          (CG-005 - fix UserPreferences)
test/contact_repository_sqlite_test.dart        (CG-005 - fix secure storage)
```

---

## 🎯 Next Steps

1. **Review** `COMPREHENSIVE_TEST_PLAN.md` for detailed test implementations
2. **Create** the 7 new test files listed above
3. **Run** tests in execution order (Days 1-5)
4. **Fix** any failures (refer to troubleshooting guide)
5. **Verify** coverage targets met (85%+)
6. **Execute** two-device tests (Week 2)

---

**Document Version**: 1.0
**Created**: 2025-11-11
**Full Plan**: `COMPREHENSIVE_TEST_PLAN.md` (18,000+ words, detailed implementations)

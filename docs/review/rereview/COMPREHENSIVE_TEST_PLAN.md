# PakConnect - Comprehensive Test Plan
**Date**: 2025-11-11
**Purpose**: Map confidence gaps to actionable tests with exact commands and validation criteria
**Scope**: All items from FYP review documentation (EXECUTIVE_SUMMARY.md, RECOMMENDED_FIXES.md)

---

## Executive Summary

This plan organizes **107 identified issues** into **testable scenarios** with:
- ✅ **Single-device tests** (can run in VM with `flutter test`)
- ❌ **Two-device tests** (require physical phones with BLE radios)
- Clear test commands, expected outcomes, and time estimates

**Test Categories**:
- Unit tests (70% - pure logic isolation)
- Integration tests (20% - multi-component flows)
- Benchmark tests (5% - performance validation)
- Device tests (5% - BLE handshake, self-connection)

---

## 🎯 Quick Reference: Confidence Gaps Mapping

Based on RECOMMENDED_FIXES.md (P0-P2 fixes):

| Gap ID | Description | Test Type | Device Required | Priority | Status |
|--------|-------------|-----------|-----------------|----------|--------|
| **CG-001** | Nonce race condition (FIX-004) | Unit | ❌ No | P0 | ⏳ TODO |
| **CG-002** | N+1 query in getAllChats (FIX-006) | Benchmark | ❌ No | P0 | ⏳ TODO |
| **CG-003** | MessageFragmenter coverage (FIX-009) | Unit | ❌ No | P1 | ⏳ TODO |
| **CG-004** | Handshake phase timing (FIX-008) | Integration | ✅ YES | P0 | ⏳ TODO |
| **CG-005** | Flaky tests (11 skipped) | Fix | ❌ No | P1 | ⏳ TODO |
| **CG-006** | Database optimization benchmarks | Benchmark | ❌ No | P1 | ⏳ TODO |
| **CG-007** | Self-connection prevention | Device | ✅ YES | P1 | ⏳ TODO |
| **CG-008** | Memory leaks (StreamProviders) | Integration | ❌ No | P0 | ⏳ TODO |
| **CG-009** | Private key memory leak | Unit | ❌ No | P0 | ⏳ TODO |
| **CG-010** | BLEService unit tests (FIX-010) | Unit | ❌ No | P1 | ⏳ TODO |

---

## 📦 Part 1: SINGLE-DEVICE TESTS (VM-Compatible)

### CG-001: Nonce Race Condition Test (P0 - CRITICAL)

**Confidence Gap**: FIX-004 - NoiseSession encrypt() has no mutex, concurrent calls can reuse nonces

**Location**: `/home/abubakar/dev/pak_connect/lib/core/security/noise/noise_session.dart:384-453`

**Test File**: `test/core/security/noise/noise_session_concurrency_test.dart` (NEW)

**Test Command**:
```bash
flutter test test/core/security/noise/noise_session_concurrency_test.dart --reporter=expanded
```

**Test Cases** (5 tests, ~30 minutes to write):

```dart
// TEST 1: Concurrent encrypt operations use unique nonces
test('concurrent encrypt operations use unique nonces', () async {
  final session = await _createEstablishedSession();

  // Encrypt 100 messages concurrently
  final futures = List.generate(100, (i) {
    final msg = Uint8List.fromList([i, i, i]);
    return session.encrypt(msg);
  });

  final results = await Future.wait(futures);

  // Extract nonces (first 4 bytes)
  final nonces = results.map((r) =>
    r.buffer.asByteData().getUint32(0, Endian.big)
  ).toSet();

  // PASS CRITERIA: All nonces unique
  expect(nonces.length, equals(100),
    reason: 'All 100 encryptions should use unique nonces');
});

// TEST 2: Nonce counter increments sequentially under concurrency
test('nonce counter increments sequentially', () async {
  final session = await _createEstablishedSession();

  // Encrypt 50 messages concurrently in 5 batches
  for (int batch = 0; batch < 5; batch++) {
    final batchFutures = List.generate(10, (i) {
      return session.encrypt(Uint8List.fromList([batch, i]));
    });
    await Future.wait(batchFutures);
  }

  // Verify message counter
  expect(session.messagesSent, equals(50));
});

// TEST 3: Rekey enforcement after 10k messages
test('enforces rekey after 10k messages', () async {
  final session = await _createEstablishedSession();

  // Send 10,000 messages
  for (int i = 0; i < 10000; i++) {
    await session.encrypt(Uint8List(10));
  }

  // 10,001st should throw RekeyRequiredException
  expect(
    () => session.encrypt(Uint8List(10)),
    throwsA(isA<RekeyRequiredException>()),
    reason: 'Session should require rekey after 10k messages'
  );
});

// TEST 4: Decrypt validates nonces (replay protection)
test('decrypt rejects replayed nonces', () async {
  final session = await _createEstablishedSession();

  final plaintext = Uint8List.fromList([1, 2, 3]);
  final ciphertext = await session.encrypt(plaintext);

  // First decrypt succeeds
  final decrypted1 = await session.decrypt(ciphertext);
  expect(decrypted1, equals(plaintext));

  // Second decrypt with same ciphertext should fail (replay)
  expect(
    () => session.decrypt(ciphertext),
    throwsA(isA<ReplayAttackException>()),
    reason: 'Nonce replay should be detected'
  );
});

// TEST 5: Thread safety with mixed encrypt/decrypt
test('handles mixed concurrent encrypt and decrypt', () async {
  final sessionA = await _createEstablishedSession();
  final sessionB = await _createEstablishedSession();

  // A encrypts, B decrypts concurrently
  final encryptFutures = List.generate(50, (i) {
    return sessionA.encrypt(Uint8List.fromList([i]));
  });

  final ciphertexts = await Future.wait(encryptFutures);

  final decryptFutures = ciphertexts.map((ct) => sessionB.decrypt(ct));
  final plaintexts = await Future.wait(decryptFutures);

  // Verify all decrypted correctly
  for (int i = 0; i < 50; i++) {
    expect(plaintexts[i], equals(Uint8List.fromList([i])));
  }
});
```

**Expected Outcomes**:
- **BEFORE FIX-004**: Tests 1, 2, 5 FAIL (nonce collisions occur)
- **AFTER FIX-004**: All 5 tests PASS (mutex prevents races)

**Execution Time**: ~5 minutes (100 async operations × 5 tests)

**Validation Criteria**:
```
✅ PASS: All nonces unique (no collisions in 100+ concurrent encrypts)
✅ PASS: Message counter accurate (50 messages = counter 50)
✅ PASS: Rekey enforced (exception thrown at 10,001st message)
✅ PASS: Replay protection (duplicate nonce rejected)
✅ PASS: Thread safety (no crashes, all operations complete)
```

---

### CG-002: N+1 Query Benchmark (P0 - CRITICAL)

**Confidence Gap**: FIX-006 - `getAllChats()` makes 1 + N queries (1 second for 100 chats)

**Location**: `/home/abubakar/dev/pak_connect/lib/data/repositories/chats_repository.dart:56-75`

**Test File**: `test/performance/chats_repository_benchmark_test.dart` (NEW)

**Test Command**:
```bash
flutter test test/performance/chats_repository_benchmark_test.dart --reporter=compact
```

**Test Cases** (3 tests, ~1 hour to write):

```dart
// TEST 1: Baseline - getAllChats with 100 contacts
test('getAllChats with 100 contacts completes in <100ms', () async {
  // ARRANGE: Create 100 contacts with 10 messages each
  await _seedDatabase(contactCount: 100, messagesPerContact: 10);

  final chatsRepo = ChatsRepository();

  // ACT: Measure query time
  final stopwatch = Stopwatch()..start();
  final chats = await chatsRepo.getAllChats(nearbyDevices: []);
  stopwatch.stop();

  print('⏱️  getAllChats(100 contacts): ${stopwatch.elapsedMilliseconds}ms');

  // ASSERT: Performance target
  expect(stopwatch.elapsedMilliseconds, lessThan(100),
    reason: 'Should complete in <100ms after FIX-006 optimization');
  expect(chats.length, equals(100));
});

// TEST 2: Scalability - getAllChats with 500 contacts
test('getAllChats with 500 contacts completes in <200ms', () async {
  await _seedDatabase(contactCount: 500, messagesPerContact: 10);

  final chatsRepo = ChatsRepository();
  final stopwatch = Stopwatch()..start();
  final chats = await chatsRepo.getAllChats(nearbyDevices: []);
  stopwatch.stop();

  print('⏱️  getAllChats(500 contacts): ${stopwatch.elapsedMilliseconds}ms');

  expect(stopwatch.elapsedMilliseconds, lessThan(200));
  expect(chats.length, equals(500));
});

// TEST 3: Query count validation (ensure single JOIN query)
test('getAllChats executes single query (not N+1)', () async {
  await _seedDatabase(contactCount: 50, messagesPerContact: 5);

  // Monitor query execution
  int queryCount = 0;
  DatabaseQueryOptimizer.instance.onQueryExecuted = () => queryCount++;

  final chatsRepo = ChatsRepository();
  await chatsRepo.getAllChats(nearbyDevices: []);

  // BEFORE FIX: 1 + 50 = 51 queries
  // AFTER FIX: 1 query (single JOIN)
  expect(queryCount, lessThan(5),
    reason: 'Should use single JOIN query, not N+1 pattern');
});
```

**Expected Outcomes**:
- **BEFORE FIX-006**:
  - 100 contacts: ~1000ms (FAIL)
  - 500 contacts: ~5000ms (FAIL)
  - Query count: 51 (FAIL)
- **AFTER FIX-006**:
  - 100 contacts: ~50ms (PASS)
  - 500 contacts: ~150ms (PASS)
  - Query count: 1 (PASS)

**Execution Time**: ~10 minutes (database seeding + queries)

**Validation Criteria**:
```
✅ PASS: 20x performance improvement (1000ms → 50ms)
✅ PASS: Scalability (500 contacts in <200ms)
✅ PASS: Single query execution (query count < 5)
```

---

### CG-003: MessageFragmenter Unit Tests (P1 - HIGH)

**Confidence Gap**: FIX-009 - ZERO tests for 411 LOC critical component

**Location**: `/home/abubakar/dev/pak_connect/lib/core/utils/message_fragmenter.dart`

**Test File**: `test/core/utils/message_fragmenter_test.dart` (NEW)

**Test Command**:
```bash
flutter test test/core/utils/message_fragmenter_test.dart --coverage
genhtml coverage/lcov.info -o coverage/html --include "*/message_fragmenter.dart"
```

**Test Cases** (15 tests, ~1 day to write):

```dart
group('MessageFragmenter - Basic Operations', () {
  late MessageFragmenter fragmenter;

  setUp(() {
    fragmenter = MessageFragmenter(maxChunkSize: 100);
  });

  // TEST 1: Fragment 250-byte message into 3 chunks
  test('fragments 250-byte message into 3 chunks', () {
    final message = Uint8List(250);
    for (int i = 0; i < 250; i++) message[i] = i % 256;

    final chunks = fragmenter.fragment(message);

    expect(chunks.length, equals(3)); // 100+100+50
    expect(chunks[0][0], equals(0)); // Index
    expect(chunks[0][1], equals(3)); // Total
    expect(chunks[2].length, lessThan(chunks[0].length)); // Last smaller
  });

  // TEST 2: Reassemble out-of-order chunks
  test('reassembles out-of-order chunks correctly', () {
    final original = Uint8List.fromList(List.generate(250, (i) => i % 256));
    final chunks = fragmenter.fragment(original);

    // Send in wrong order: 1, 0, 2
    var reassembled = fragmenter.reassemble('sender1', chunks[1]);
    expect(reassembled, isNull); // Not complete

    reassembled = fragmenter.reassemble('sender1', chunks[0]);
    expect(reassembled, isNull); // Not complete

    reassembled = fragmenter.reassemble('sender1', chunks[2]);
    expect(reassembled, equals(original)); // Complete!
  });

  // TEST 3: Handle duplicate chunks
  test('handles duplicate chunks gracefully', () {
    final original = Uint8List(250);
    final chunks = fragmenter.fragment(original);

    fragmenter.reassemble('sender1', chunks[0]);
    fragmenter.reassemble('sender1', chunks[0]); // Duplicate
    final result = fragmenter.reassemble('sender1', chunks[1]);

    expect(result, isNull); // Still incomplete (only 2 unique chunks)
  });

  // TEST 4: Timeout missing chunks after 30 seconds
  test('times out missing chunks after 30 seconds', () {
    final chunks = fragmenter.fragment(Uint8List(250));

    fragmenter.reassemble('sender1', chunks[0]);

    // Simulate 31 seconds passing
    fragmenter.cleanupOldMessages(timeout: Duration(seconds: 31));

    // Send remaining chunks - should fail (session expired)
    final reassembled = fragmenter.reassemble('sender1', chunks[1]);
    expect(reassembled, isNull); // Expired
  });

  // TEST 5: Handle interleaved messages from different senders
  test('handles interleaved messages from different senders', () {
    final msg1 = Uint8List.fromList([1, 1, 1]);
    final msg2 = Uint8List.fromList([2, 2, 2]);

    final chunks1 = fragmenter.fragment(msg1);
    final chunks2 = fragmenter.fragment(msg2);

    // Interleave: sender1 chunk0, sender2 chunk0, sender1 chunk1, sender2 chunk1
    fragmenter.reassemble('sender1', chunks1[0]);
    fragmenter.reassemble('sender2', chunks2[0]);
    fragmenter.reassemble('sender1', chunks1[1]);
    final result2 = fragmenter.reassemble('sender2', chunks2[1]);

    expect(result2, equals(msg2)); // Sender2 message complete
  });
});

group('MessageFragmenter - Edge Cases', () {
  // TEST 6: Empty message
  test('handles empty message', () {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);
    final chunks = fragmenter.fragment(Uint8List(0));

    expect(chunks.length, equals(1)); // Single empty chunk
  });

  // TEST 7: Single-chunk message (no fragmentation needed)
  test('single-chunk message needs no fragmentation', () {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);
    final message = Uint8List(50);

    final chunks = fragmenter.fragment(message);
    expect(chunks.length, equals(1));
  });

  // TEST 8: Large message (10KB)
  test('handles large 10KB message', () {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);
    final message = Uint8List(10240); // 10KB

    final chunks = fragmenter.fragment(message);
    expect(chunks.length, equals(103)); // 10240 / 100 = 102.4 → 103

    // Reassemble
    String senderId = 'large_sender';
    for (int i = 0; i < chunks.length - 1; i++) {
      final result = fragmenter.reassemble(senderId, chunks[i]);
      expect(result, isNull); // Incomplete until last chunk
    }

    final final_result = fragmenter.reassemble(senderId, chunks.last);
    expect(final_result?.length, equals(10240));
  });

  // TEST 9: MTU boundary testing (various sizes)
  test('respects MTU boundaries', () {
    final sizes = [20, 100, 200, 512];

    for (final mtu in sizes) {
      final fragmenter = MessageFragmenter(maxChunkSize: mtu);
      final message = Uint8List(mtu * 3 + 10); // Exceed 3x MTU

      final chunks = fragmenter.fragment(message);

      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(mtu + 2),
          reason: 'Chunk should not exceed MTU (+ 2 byte header)');
      }
    }
  });

  // TEST 10: Memory bounds (max 100 pending messages per sender)
  test('enforces memory bounds for pending messages', () {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);

    // Send first chunk of 101 different messages
    for (int i = 0; i < 101; i++) {
      final msg = Uint8List(200);
      final chunks = fragmenter.fragment(msg);
      fragmenter.reassemble('sender1', chunks[0]);
    }

    // Verify oldest message was evicted
    final pendingCount = fragmenter.getPendingMessageCount('sender1');
    expect(pendingCount, lessThanOrEqualTo(100),
      reason: 'Should enforce max 100 pending messages per sender');
  });
});

group('MessageFragmenter - Data Integrity', () {
  // TEST 11: Chunk header format validation
  test('chunk header format is correct', () {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);
    final message = Uint8List(250);

    final chunks = fragmenter.fragment(message);

    // Header: [index byte][total byte][payload...]
    expect(chunks[0][0], equals(0)); // First chunk index
    expect(chunks[0][1], equals(3)); // Total chunks
    expect(chunks[2][0], equals(2)); // Last chunk index
  });

  // TEST 12: Base64 encoding/decoding correctness
  test('base64 encoding preserves binary data', () {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);
    final original = Uint8List.fromList([0xFF, 0xFE, 0x00, 0x01, 0x7F]);

    final encoded = base64Encode(original);
    final decoded = base64Decode(encoded);

    expect(decoded, equals(original),
      reason: 'Base64 roundtrip should preserve binary data');
  });

  // TEST 13: Fragment cleanup on timeout
  test('cleans up expired fragments', () {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);
    final chunks = fragmenter.fragment(Uint8List(200));

    fragmenter.reassemble('sender1', chunks[0]);

    final before = fragmenter.getPendingMessageCount('sender1');
    expect(before, equals(1));

    // Cleanup expired (31 seconds)
    fragmenter.cleanupOldMessages(timeout: Duration(seconds: 31));

    final after = fragmenter.getPendingMessageCount('sender1');
    expect(after, equals(0), reason: 'Expired fragments should be cleaned');
  });

  // TEST 14: Corruption detection (if checksums added)
  test('detects corrupted chunks (after adding checksums)', () {
    // TODO: Implement after FIX-016 adds CRC32 checksums
    // For now, this test documents the expected behavior
  }, skip: 'Requires CRC32 checksum implementation');

  // TEST 15: Concurrent reassembly from same sender
  test('handles concurrent reassembly attempts', () async {
    final fragmenter = MessageFragmenter(maxChunkSize: 100);
    final message = Uint8List(300);
    final chunks = fragmenter.fragment(message);

    // Reassemble chunks concurrently
    final futures = chunks.map((chunk) =>
      Future(() => fragmenter.reassemble('sender1', chunk))
    ).toList();

    final results = await Future.wait(futures);

    // Only the final chunk should return non-null
    final nonNullResults = results.where((r) => r != null).toList();
    expect(nonNullResults.length, equals(1),
      reason: 'Only final chunk should complete reassembly');
  });
});
```

**Expected Outcomes**:
- **Coverage**: 100% line coverage for `message_fragmenter.dart`
- **Pass Rate**: 15/15 tests passing

**Execution Time**: ~15 minutes (15 tests × 1 minute average)

**Validation Criteria**:
```
✅ PASS: All 15 tests passing
✅ PASS: 100% code coverage for MessageFragmenter
✅ PASS: Edge cases handled (empty, large, interleaved)
✅ PASS: Memory bounds enforced (<100 pending per sender)
✅ PASS: Timeout cleanup works (31 seconds)
```

---

### CG-005: Flaky Tests Investigation (P1 - HIGH)

**Confidence Gap**: 11 skipped/flaky tests identified in TESTING_STRATEGY.md

**Current State**: Tests hang or deadlock in `mesh_relay_flow_test.dart`, `chat_lifecycle_persistence_test.dart`

**Investigation File**: `test/debug/flaky_tests_analysis.md` (NEW)

**Test Commands**:
```bash
# Run each flaky test individually with timeout
timeout 60 flutter test test/mesh_relay_flow_test.dart --reporter=expanded
timeout 60 flutter test test/chat_lifecycle_persistence_test.dart --reporter=expanded
timeout 60 flutter test test/chats_repository_sqlite_test.dart --name "Requires UserPreferences"
timeout 60 flutter test test/contact_repository_sqlite_test.dart --name "Cannot skip security"
```

**Identified Flaky Tests** (from grep results):

| Test File | Test Name | Symptom | Root Cause | Fix |
|-----------|-----------|---------|------------|-----|
| `mesh_relay_flow_test.dart` | Line 19, 20 | Hangs indefinitely | Async operation never completes | Add proper async/await + timeout |
| `chat_lifecycle_persistence_test.dart` | 3 tests skipped | Unknown | Needs investigation | Re-enable and fix |
| `chats_repository_sqlite_test.dart` | UserPreferences setup | Skipped | FlutterSecureStorage mock missing | Use TestSetup.dart harness |
| `contact_repository_sqlite_test.dart` | Security upgrade test | Skipped | FlutterSecureStorage mock missing | Use TestSetup.dart harness |

**Execution Plan** (3 hours):

**Step 1: Reproduce Failures** (30 min)
```bash
# Run with verbose logging
flutter test test/mesh_relay_flow_test.dart --reporter=expanded 2>&1 | tee flaky_test_output.log
```

**Step 2: Fix mesh_relay_flow_test.dart** (1 hour)
```dart
// BEFORE (Hangs):
test('relay flow completes', () {
  // Missing await?
  meshService.processMessage(msg); // ❌ Async not awaited
});

// AFTER (Fixed):
test('relay flow completes', () async {
  await meshService.processMessage(msg); // ✅ Properly awaited
}, timeout: Timeout(Duration(seconds: 10))); // ✅ Add timeout
```

**Step 3: Fix FlutterSecureStorage mocks** (1 hour)
```dart
// Add to setUpAll in failing tests:
setUpAll(() async {
  await TestSetup.initializeTestEnvironment(); // ✅ Initializes InMemorySecureStorage
});
```

**Step 4: Re-enable and verify** (30 min)
```bash
# Re-run all previously flaky tests
flutter test test/mesh_relay_flow_test.dart test/chat_lifecycle_persistence_test.dart test/chats_repository_sqlite_test.dart test/contact_repository_sqlite_test.dart
```

**Expected Outcomes**:
- **BEFORE**: 11 tests skipped/hanging
- **AFTER**: 11 tests passing with proper timeouts

**Validation Criteria**:
```
✅ PASS: All 11 previously flaky tests now passing
✅ PASS: No test hangs (all complete in <60 seconds)
✅ PASS: Proper async/await usage
✅ PASS: TestSetup.dart harness used for secure storage
```

---

### CG-006: Database Optimization Benchmarks (P1 - HIGH)

**Confidence Gap**: Missing indexes, LIKE query wildcards prevent index usage

**Location**: `/home/abubakar/dev/pak_connect/lib/data/database/database_helper.dart`

**Test File**: `test/performance/database_benchmarks_test.dart` (NEW)

**Test Command**:
```bash
flutter test test/performance/database_benchmarks_test.dart --reporter=compact
```

**Test Cases** (5 benchmarks, ~2 hours to write):

```dart
// BENCHMARK 1: Chat loading performance
test('getAllChats loads 100 chats in <100ms', () async {
  await _seedDatabase(contactCount: 100, messagesPerContact: 10);

  final stopwatch = Stopwatch()..start();
  final chats = await ChatsRepository().getAllChats(nearbyDevices: []);
  stopwatch.stop();

  print('⏱️  getAllChats(100): ${stopwatch.elapsedMilliseconds}ms');
  expect(stopwatch.elapsedMilliseconds, lessThan(100));
});

// BENCHMARK 2: FTS5 search performance
test('FTS5 archive search handles 10k messages in <50ms', () async {
  await _seedArchivedMessages(count: 10000);

  final stopwatch = Stopwatch()..start();
  final results = await ArchiveRepository().search(query: 'test');
  stopwatch.stop();

  print('⏱️  FTS5 search(10k messages): ${stopwatch.elapsedMilliseconds}ms');
  expect(stopwatch.elapsedMilliseconds, lessThan(50));
});

// BENCHMARK 3: Index usage validation
test('queries use indexes (EXPLAIN QUERY PLAN)', () async {
  final db = await DatabaseHelper().database;

  // Query that SHOULD use index
  final plan = await db.rawQuery('''
    EXPLAIN QUERY PLAN
    SELECT * FROM contacts WHERE public_key = ?
  ''', ['test_key']);

  final planText = plan.toString();
  expect(planText.contains('SEARCH') || planText.contains('INDEX'),
    isTrue, reason: 'Query should use index on public_key');
});

// BENCHMARK 4: Message insertion batch performance
test('batch insert 1000 messages in <500ms', () async {
  final db = await DatabaseHelper().database;
  final messages = List.generate(1000, (i) => {
    'id': 'msg_$i',
    'chat_id': 'chat_1',
    'content': 'Message $i',
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'is_from_me': i % 2,
  });

  final stopwatch = Stopwatch()..start();
  await db.transaction((txn) async {
    for (final msg in messages) {
      await txn.insert('messages', msg);
    }
  });
  stopwatch.stop();

  print('⏱️  Batch insert(1000): ${stopwatch.elapsedMilliseconds}ms');
  expect(stopwatch.elapsedMilliseconds, lessThan(500));
});

// BENCHMARK 5: Seen messages cleanup performance
test('seen_messages cleanup removes 5k entries in <100ms', () async {
  final db = await DatabaseHelper().database;

  // Insert 5000 old entries
  final cutoff = DateTime.now().subtract(Duration(minutes: 10));
  await db.transaction((txn) async {
    for (int i = 0; i < 5000; i++) {
      await txn.insert('seen_messages', {
        'message_hash': 'hash_$i',
        'message_type': 0,
        'seen_at': cutoff.millisecondsSinceEpoch,
      });
    }
  });

  // Benchmark cleanup
  final stopwatch = Stopwatch()..start();
  final deleted = await db.delete(
    'seen_messages',
    where: 'seen_at < ?',
    whereArgs: [DateTime.now().millisecondsSinceEpoch],
  );
  stopwatch.stop();

  print('⏱️  Cleanup(5k entries): ${stopwatch.elapsedMilliseconds}ms');
  expect(stopwatch.elapsedMilliseconds, lessThan(100));
  expect(deleted, equals(5000));
});
```

**Expected Outcomes**:
- **getAllChats**: <100ms for 100 chats (after FIX-006)
- **FTS5 search**: <50ms for 10k messages
- **Index usage**: All queries use indexes (no table scans)
- **Batch insert**: <500ms for 1000 messages
- **Cleanup**: <100ms for 5k entries

**Execution Time**: ~20 minutes (database operations + seeding)

**Validation Criteria**:
```
✅ PASS: All queries under performance targets
✅ PASS: EXPLAIN QUERY PLAN shows index usage
✅ PASS: No full table scans on large tables
✅ PASS: Batch operations use transactions
```

---

### CG-008: StreamProvider Memory Leak Test (P0 - CRITICAL)

**Confidence Gap**: FIX-007 - 8 StreamProviders without autoDispose

**Location**: `/home/abubakar/dev/pak_connect/lib/presentation/providers/`

**Test File**: `test/presentation/providers/provider_lifecycle_test.dart` (NEW)

**Test Command**:
```bash
flutter test test/presentation/providers/provider_lifecycle_test.dart --reporter=expanded
```

**Test Cases** (3 tests, ~1 hour to write):

```dart
// TEST 1: StreamProviders dispose when widget disposed
test('StreamProviders dispose when widget disposed', () async {
  final container = ProviderContainer();

  // Watch provider
  final subscription = container.listen(
    meshNetworkStatusProvider,
    (prev, next) {},
  );

  // Provider is active
  expect(container.exists(meshNetworkStatusProvider), isTrue);

  // Dispose
  subscription.close();
  await Future.delayed(Duration(milliseconds: 100)); // Allow async cleanup

  // Provider is disposed (BEFORE FIX: still exists)
  expect(container.exists(meshNetworkStatusProvider), isFalse,
    reason: 'autoDispose should cleanup when no longer watched');

  container.dispose();
});

// TEST 2: Multiple StreamProviders cleanup
test('multiple StreamProviders cleanup correctly', () async {
  final container = ProviderContainer();

  final providers = [
    bluetoothStateProvider,
    bluetoothStatusMessageProvider,
    relayStatisticsProvider,
    queueSyncStatisticsProvider,
    meshDemoEventsProvider,
    autoRefreshContactsProvider,
  ];

  final subscriptions = providers.map((p) =>
    container.listen(p, (prev, next) {})
  ).toList();

  // All active
  for (final provider in providers) {
    expect(container.exists(provider), isTrue);
  }

  // Dispose all
  for (final sub in subscriptions) {
    sub.close();
  }
  await Future.delayed(Duration(milliseconds: 200));

  // All cleaned up
  for (final provider in providers) {
    expect(container.exists(provider), isFalse,
      reason: '${provider} should be disposed');
  }

  container.dispose();
});

// TEST 3: Memory leak detection (heap growth)
test('no memory leak after 100 provider create/dispose cycles', () async {
  final initialMemory = ProcessInfo.currentRss; // Rough estimate

  for (int i = 0; i < 100; i++) {
    final container = ProviderContainer();
    final sub = container.listen(
      meshNetworkStatusProvider,
      (prev, next) {},
    );
    await Future.delayed(Duration(milliseconds: 10));
    sub.close();
    container.dispose();
  }

  // Force GC (not guaranteed in Dart, but helps)
  await Future.delayed(Duration(seconds: 1));

  final finalMemory = ProcessInfo.currentRss;
  final growth = finalMemory - initialMemory;

  print('📊 Memory growth after 100 cycles: ${growth} bytes');

  // Allow 10MB growth max (BEFORE FIX: may grow unbounded)
  expect(growth, lessThan(10 * 1024 * 1024),
    reason: 'Memory should not leak after provider disposal');
});
```

**Expected Outcomes**:
- **BEFORE FIX-007**: Tests 1, 2 FAIL (providers not disposed), Test 3 shows unbounded growth
- **AFTER FIX-007**: All tests PASS (autoDispose works correctly)

**Execution Time**: ~5 minutes (100 cycles × 50ms)

**Validation Criteria**:
```
✅ PASS: Providers dispose when unwatched
✅ PASS: Multiple providers cleanup correctly
✅ PASS: No memory leak (<10MB growth in 100 cycles)
```

---

### CG-009: Private Key Memory Leak Test (P0 - CRITICAL)

**Confidence Gap**: FIX-001 - NoiseSession copies keys, destroy() only zeros copy

**Location**: `/home/abubakar/dev/pak_connect/lib/core/security/noise/noise_session.dart:105, 617`

**Test File**: `test/core/security/secure_key_test.dart` (NEW)

**Test Command**:
```bash
flutter test test/core/security/secure_key_test.dart --reporter=expanded
```

**Test Cases** (4 tests, ~30 minutes to write):

```dart
// TEST 1: SecureKey zeros original immediately
test('SecureKey zeros original immediately', () {
  final original = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
  final originalCopy = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]); // For comparison

  final secureKey = SecureKey(original);

  // ASSERT: Original is zeroed
  expect(original, equals(Uint8List(8)), // All zeros
    reason: 'Original should be zeroed immediately');

  // ASSERT: SecureKey.data still has original value
  expect(secureKey.data, equals(originalCopy),
    reason: 'SecureKey should preserve value');
});

// TEST 2: SecureKey.destroy() zeros internal copy
test('SecureKey.destroy() zeros internal copy', () {
  final original = Uint8List.fromList([1, 2, 3, 4]);
  final secureKey = SecureKey(original);

  // Before destroy
  expect(secureKey.data, isNot(equals(Uint8List(4))));

  // Destroy
  secureKey.destroy();

  // After destroy, data should throw
  expect(() => secureKey.data, throwsStateError,
    reason: 'Accessing destroyed key should throw');
});

// TEST 3: NoiseSession uses SecureKey wrapper
test('NoiseSession zeros keys on destroy', () {
  final privateKey = Uint8List.fromList(List.generate(32, (i) => i));
  final privateKeyCopy = Uint8List.fromList(List.generate(32, (i) => i));

  final session = NoiseSession(
    localStaticPrivateKey: privateKey,
    // ... other params
  );

  // Original should be zeroed
  expect(privateKey, equals(Uint8List(32)),
    reason: 'Original key should be zeroed by SecureKey wrapper');

  // Session can still use key
  // (Implementation detail - internal test)

  // Destroy session
  session.destroy();

  // Verify internal key is zeroed (white-box test)
  // Note: This requires making _localStaticPrivateKey accessible for testing
  // or using reflection (not ideal in production)
});

// TEST 4: Memory inspection (heap dump validation)
test('destroyed keys not in memory dump', () {
  // This test would require memory dump analysis tools
  // For now, document expected behavior

  final privateKey = Uint8List.fromList([0xFF] * 32);
  final secureKey = SecureKey(privateKey);

  // Before destroy: key exists in memory
  expect(secureKey.data, contains(0xFF));

  // Destroy
  secureKey.destroy();

  // After destroy: key should not be in memory
  // (In production, verify with memory profiler)

  // MANUAL VALIDATION STEP:
  // 1. Run app in debug mode
  // 2. Take heap snapshot before key creation
  // 3. Create key, take snapshot
  // 4. Destroy key, force GC, take snapshot
  // 5. Search for key bytes in snapshots
  // 6. Verify key bytes only in snapshot #2, not #3
}, skip: 'Requires manual memory dump analysis');
```

**Expected Outcomes**:
- **BEFORE FIX-001**: Test 1, 2 FAIL (original not zeroed), Test 3 FAIL (key still in memory)
- **AFTER FIX-001**: Tests 1, 2, 3 PASS

**Execution Time**: ~5 minutes (fast unit tests)

**Validation Criteria**:
```
✅ PASS: Original keys zeroed immediately
✅ PASS: Destroyed keys throw StateError on access
✅ PASS: NoiseSession integrates SecureKey wrapper
❌ MANUAL: Heap dump shows no key bytes after destroy
```

---

### CG-010: BLEService Unit Tests (P1 - HIGH)

**Confidence Gap**: FIX-010 - ZERO unit tests for 3,426 LOC critical component

**Location**: `/home/abubakar/dev/pak_connect/lib/data/services/ble_service.dart`

**Test File**: `test/data/services/ble_service_test.dart` (NEW)

**Test Command**:
```bash
flutter test test/data/services/ble_service_test.dart --coverage
```

**Test Cases** (25 tests, ~2 days to write):

```dart
group('BLEService - Initialization', () {
  // TEST 1: Initialization without BLE permission
  test('initialization fails without BLE permission', () async {
    final mockBLE = MockBLEAdapter();
    when(mockBLE.hasPermission()).thenReturn(false);

    final service = BLEService(bleAdapter: mockBLE);

    expect(() => service.initialize(),
      throwsA(isA<BLEPermissionException>()));
  });

  // TEST 2: Initialization with BLE disabled
  test('initialization warns when BLE disabled', () async {
    final mockBLE = MockBLEAdapter();
    when(mockBLE.hasPermission()).thenReturn(true);
    when(mockBLE.isEnabled()).thenReturn(false);

    final service = BLEService(bleAdapter: mockBLE);

    // Should initialize but log warning
    await service.initialize();

    expect(service.state, equals(BLEServiceState.disabled));
  });

  // ... 23 more tests covering:
  // - Advertisement setup
  // - Scanning configuration
  // - Connection management
  // - Message queuing
  // - Error handling
});
```

**Expected Outcomes**:
- **Coverage**: 60%+ line coverage for BLEService (excluding BLE platform code)
- **Pass Rate**: 25/25 tests passing

**Execution Time**: ~10 minutes (25 tests × 24 seconds)

**Validation Criteria**:
```
✅ PASS: 25/25 unit tests passing
✅ PASS: 60%+ coverage (excluding platform channels)
✅ PASS: All critical paths tested (init, scan, advertise, connect)
✅ PASS: Error handling verified
```

---

## 📱 Part 2: TWO-DEVICE TESTS (Physical Phones Required)

### CG-004: Handshake Phase Timing Test (P0 - CRITICAL)

**Confidence Gap**: FIX-008 - Phase 2 can start before Phase 1.5 (Noise) completes

**Location**: `/home/abubakar/dev/pak_connect/lib/core/bluetooth/handshake_coordinator.dart:689-699`

**Test Type**: Integration test with 2 physical Android/iOS devices

**Test Setup**:
1. Device A (Pixel 6, Android 13)
2. Device B (iPhone 12, iOS 16)
3. BLE enabled, location permissions granted
4. Both devices on test APK build with debug logging

**Test Command** (on-device):
```bash
# Build test APK with instrumentation
flutter build apk --debug --flavor integration_test
adb install build/app/outputs/flutter-apk/app-debug.apk

# Run instrumented test (on Device A)
adb shell am instrument -w -e class com.pakconnect.HandshakeTimingTest \
  com.pakconnect.test/androidx.test.runner.AndroidJUnitRunner
```

**Manual Test Procedure** (15 minutes):

**Step 1: Setup** (2 min)
```
1. Install test APK on both devices
2. Enable debug logging: Settings → Developer → Verbose BLE Logs
3. Clear app data to reset state
```

**Step 2: Test Scenario - Normal Handshake** (5 min)
```
1. Device A: Start advertising
2. Device B: Start scanning
3. Wait for connection
4. OBSERVE LOG OUTPUT:
   - Phase 0: CONNECTION_READY (MTU negotiated)
   - Phase 1: IDENTITY_EXCHANGE (ephemeral IDs exchanged)
   - Phase 1.5: NOISE_HANDSHAKE (XX pattern - 3 messages)
   - Phase 2: CONTACT_STATUS_SYNC (only AFTER Phase 1.5 complete)

PASS CRITERIA:
✅ Phase 1.5 completes before Phase 2 starts
✅ No "Noise session not ready" errors in logs
✅ Message encryption uses Noise (not global AES fallback)
```

**Step 3: Test Scenario - Race Condition Trigger** (5 min)
```
1. Device A: Start advertising
2. Device B: Start scanning
3. Immediately after connection, send message from B → A
4. OBSERVE: Does Phase 2 wait for Noise session?

BEFORE FIX-008:
❌ Phase 2 starts immediately after Phase 1
❌ "Noise session not found, using global encryption" warning
❌ Message encrypted with weak global AES

AFTER FIX-008:
✅ Phase 2 waits for Noise session establishment
✅ All messages use Noise encryption
✅ No global AES fallback warnings
```

**Step 4: Log Collection** (3 min)
```bash
# Collect logs from both devices
adb logcat -d | grep -E "Phase|Noise|Handshake" > device_a_handshake.log
# (Repeat for Device B)

# Verify log sequence:
grep "Phase 1.5.*complete" device_a_handshake.log
grep "Phase 2.*starting" device_a_handshake.log

# Ensure Phase 1.5 timestamp < Phase 2 timestamp
```

**Expected Log Output (AFTER FIX-008)**:
```
11:23:45.123 INFO HandshakeCoordinator: Phase 0 → CONNECTION_READY
11:23:45.234 INFO HandshakeCoordinator: Phase 1 → IDENTITY_EXCHANGE
11:23:45.456 INFO HandshakeCoordinator: Phase 1.5 → NOISE_HANDSHAKE (message 1/3)
11:23:45.567 INFO HandshakeCoordinator: Phase 1.5 → NOISE_HANDSHAKE (message 2/3)
11:23:45.678 INFO HandshakeCoordinator: Phase 1.5 → NOISE_HANDSHAKE (message 3/3)
11:23:45.789 INFO NoiseSession: Session established (state=established)
11:23:45.890 INFO HandshakeCoordinator: ⏳ Waiting for Noise session ready...
11:23:45.891 INFO HandshakeCoordinator: ✅ Noise session ready, advancing to Phase 2
11:23:45.900 INFO HandshakeCoordinator: Phase 2 → CONTACT_STATUS_SYNC
```

**Validation Criteria**:
```
✅ PASS: Phase 1.5 completes before Phase 2 (timestamp order)
✅ PASS: "Waiting for Noise session" log present
✅ PASS: No global AES fallback used
✅ PASS: Both devices complete handshake successfully
✅ PASS: First message after handshake uses Noise encryption
```

**Execution Time**: ~15 minutes (setup + 2 scenarios + log analysis)

---

### CG-007: Self-Connection Prevention Test (P1 - HIGH)

**Confidence Gap**: Device A can connect to itself (ephemeral hint collision)

**Location**: `/home/abubakar/dev/pak_connect/lib/core/bluetooth/peripheral_initializer.dart`

**Test Type**: Single-device BLE test

**Test Setup**:
1. Device A (Pixel 6, Android 13) - acts as both central AND peripheral
2. BLE enabled, location permissions granted
3. Debug build with verbose logging

**Test Command** (manual):
```bash
# Build debug APK
flutter build apk --debug
adb install build/app/outputs/flutter-apk/app-debug.apk

# Enable verbose logs
adb shell setprop log.tag.PakConnect VERBOSE
```

**Manual Test Procedure** (10 minutes):

**Step 1: Enable Dual-Role BLE** (2 min)
```
1. Open PakConnect app on Device A
2. Navigate to Settings → Developer Mode → Enable Dual-Role BLE
3. Verify both advertising AND scanning are active
```

**Step 2: Trigger Self-Connection Attempt** (5 min)
```
1. Device A starts advertising with ephemeral ID: "ABC123"
2. Device A starts scanning
3. OBSERVE: Does Device A discover itself?

BEFORE FIX:
❌ Device A sees own advertisement in scan results
❌ Device A attempts to connect to itself
❌ Connection succeeds, handshake starts
❌ Duplicate contact created ("Me" appears in contact list)

AFTER FIX:
✅ Device A filters out own advertisement
✅ Scan results exclude own MAC address / ephemeral ID
✅ No self-connection attempt
```

**Step 3: Log Analysis** (3 min)
```bash
adb logcat -d | grep -E "ScanResult|Connection|ephemeralId" > self_connection_test.log

# Check for self-filtering
grep "Ignoring own advertisement" self_connection_test.log
# Should see: "🚫 Ignoring own advertisement (MAC: XX:XX:XX:XX, ID: ABC123)"

# Verify no self-connection
grep "Connecting to.*ABC123" self_connection_test.log
# Should be EMPTY (no connection to own ID)
```

**Expected Log Output (AFTER FIX)**:
```
11:30:01.123 INFO BLEScanner: Scan result: MAC=AA:BB:CC:DD, ephemeralId=ABC123
11:30:01.124 INFO BLEScanner: 🚫 Ignoring own advertisement (matches local ID)
11:30:01.125 INFO BLEScanner: Scan result: MAC=EE:FF:00:11, ephemeralId=XYZ789
11:30:01.126 INFO BLEScanner: ✅ Valid peer discovered: XYZ789
```

**Validation Criteria**:
```
✅ PASS: Own advertisement filtered from scan results
✅ PASS: No self-connection attempt in logs
✅ PASS: Contact list does not show "Me" as contact
✅ PASS: Handshake coordinator never invoked for self
```

**Execution Time**: ~10 minutes (setup + trigger + log analysis)

---

## 📊 Part 3: Test Execution Summary

### Single-Device Tests (VM-Compatible)

| Test ID | Category | File | Tests | Time | Status |
|---------|----------|------|-------|------|--------|
| CG-001 | Unit | `noise_session_concurrency_test.dart` | 5 | 5 min | ⏳ TODO |
| CG-002 | Benchmark | `chats_repository_benchmark_test.dart` | 3 | 10 min | ⏳ TODO |
| CG-003 | Unit | `message_fragmenter_test.dart` | 15 | 15 min | ⏳ TODO |
| CG-005 | Fix | (Multiple files) | 11 | 3 hrs | ⏳ TODO |
| CG-006 | Benchmark | `database_benchmarks_test.dart` | 5 | 20 min | ⏳ TODO |
| CG-008 | Integration | `provider_lifecycle_test.dart` | 3 | 5 min | ⏳ TODO |
| CG-009 | Unit | `secure_key_test.dart` | 4 | 5 min | ⏳ TODO |
| CG-010 | Unit | `ble_service_test.dart` | 25 | 10 min | ⏳ TODO |

**Total Single-Device**: 71 tests, ~4.1 hours (including 3 hours for flaky test fixes)

### Two-Device Tests (Physical Phones Required)

| Test ID | Category | Procedure | Devices | Time | Status |
|---------|----------|-----------|---------|------|--------|
| CG-004 | Integration | Handshake timing (manual) | 2 | 15 min | ⏳ TODO |
| CG-007 | Device | Self-connection (manual) | 1 | 10 min | ⏳ TODO |

**Total Two-Device**: 2 manual procedures, ~25 minutes

---

## 🚀 Part 4: Execution Plan

### Phase 1: Single-Device Tests (Week 1)

**Day 1 (2 hours)**:
```bash
# Morning: Critical security tests
flutter test test/core/security/noise/noise_session_concurrency_test.dart  # CG-001
flutter test test/core/security/secure_key_test.dart                        # CG-009

# Afternoon: Performance benchmarks
flutter test test/performance/chats_repository_benchmark_test.dart          # CG-002
flutter test test/performance/database_benchmarks_test.dart                 # CG-006
```

**Day 2 (3 hours)**:
```bash
# Morning: MessageFragmenter (large test suite)
flutter test test/core/utils/message_fragmenter_test.dart                   # CG-003

# Afternoon: Provider lifecycle
flutter test test/presentation/providers/provider_lifecycle_test.dart       # CG-008
```

**Day 3 (3 hours)**:
```bash
# Full day: Flaky test fixes
timeout 60 flutter test test/mesh_relay_flow_test.dart                      # CG-005
timeout 60 flutter test test/chat_lifecycle_persistence_test.dart           # CG-005
# ... (Fix and re-run all 11 flaky tests)
```

**Day 4-5 (2 days)**:
```bash
# BLEService unit tests (largest test suite)
flutter test test/data/services/ble_service_test.dart                       # CG-010
```

### Phase 2: Two-Device Tests (Week 2)

**Prerequisites**:
- 2 physical Android devices (or 1 Android + 1 iOS)
- BLE enabled, permissions granted
- Debug build installed on both

**Day 1 (30 minutes)**:
```
1. Setup devices with debug builds
2. Run CG-004 (Handshake timing test) - 15 min
3. Run CG-007 (Self-connection test) - 10 min
4. Collect and analyze logs
```

---

## 📋 Part 5: Progress Tracking Template

```markdown
## Test Execution Progress

### Week 1: Single-Device Tests
- [ ] CG-001: Nonce race condition (5 tests) - Estimated: 5 min | Actual: ____ min
- [ ] CG-002: N+1 query benchmark (3 tests) - Estimated: 10 min | Actual: ____ min
- [ ] CG-003: MessageFragmenter (15 tests) - Estimated: 15 min | Actual: ____ min
- [ ] CG-005: Flaky tests (11 fixes) - Estimated: 3 hrs | Actual: ____ hrs
- [ ] CG-006: Database benchmarks (5 tests) - Estimated: 20 min | Actual: ____ min
- [ ] CG-008: Provider lifecycle (3 tests) - Estimated: 5 min | Actual: ____ min
- [ ] CG-009: Secure key (4 tests) - Estimated: 5 min | Actual: ____ min
- [ ] CG-010: BLEService (25 tests) - Estimated: 10 min | Actual: ____ min

**Week 1 Total**: [ ] 71 tests | Estimated: 4.1 hrs | Actual: ____ hrs

### Week 2: Two-Device Tests
- [ ] CG-004: Handshake timing (manual) - Estimated: 15 min | Actual: ____ min
- [ ] CG-007: Self-connection (manual) - Estimated: 10 min | Actual: ____ min

**Week 2 Total**: [ ] 2 procedures | Estimated: 25 min | Actual: ____ min

---

## Overall Progress: ___% Complete (73 tests total)
```

---

## 🎯 Part 6: Success Criteria

### Critical Tests (Must Pass Before Production)

**P0 Tests** (Block production):
- ✅ CG-001: Nonce race condition → All 5 tests passing (no nonce collisions)
- ✅ CG-002: N+1 query → <100ms for 100 chats (20x improvement)
- ✅ CG-004: Handshake timing → Phase 2 waits for Phase 1.5 (device test)
- ✅ CG-008: StreamProvider leaks → All providers dispose correctly
- ✅ CG-009: Private key leak → Keys zeroed on destroy

**P1 Tests** (High priority):
- ✅ CG-003: MessageFragmenter → 100% coverage, all 15 tests passing
- ✅ CG-005: Flaky tests → 11/11 previously flaky tests now stable
- ✅ CG-006: Database benchmarks → All queries under performance targets
- ✅ CG-007: Self-connection → Device filters own advertisements
- ✅ CG-010: BLEService → 60%+ coverage, 25/25 tests passing

### Overall Targets

**Coverage**:
- MessageFragmenter: 100% (currently 0%)
- NoiseSession: 95% (currently ~70%)
- BLEService: 60% (currently 0%)
- ChatsRepository: 85% (currently ~60%)

**Performance**:
- getAllChats (100 contacts): <100ms (currently ~1000ms)
- FTS5 search (10k messages): <50ms
- Database cleanup (5k entries): <100ms

**Reliability**:
- Test pass rate: 100% (currently ~96% due to 11 flaky tests)
- No test hangs (all complete in <60 seconds)
- No memory leaks (provider lifecycle tests pass)

---

## 📝 Part 7: Test Output Format

### Successful Test Run Example

```bash
$ flutter test test/core/security/noise/noise_session_concurrency_test.dart --reporter=expanded

00:01 +0: concurrent encrypt operations use unique nonces
⏱️  Concurrent encrypt (100 ops): 234ms
✅ All nonces unique: 100/100
00:02 +1: concurrent encrypt operations use unique nonces

00:02 +1: nonce counter increments sequentially
✅ Message counter accurate: 50
00:02 +2: nonce counter increments sequentially

00:02 +2: enforces rekey after 10k messages
✅ Rekey enforced at message 10,001
00:03 +3: enforces rekey after 10k messages

00:03 +3: decrypt rejects replayed nonces
✅ Replay attack detected and blocked
00:03 +4: decrypt rejects replayed nonces

00:03 +4: handles mixed concurrent encrypt and decrypt
⏱️  Mixed operations (100 ops): 312ms
✅ All operations completed successfully
00:04 +5: handles mixed concurrent encrypt and decrypt

00:04 +5: All tests passed!

SUCCESS: 5 tests passed, 0 failed
```

### Failed Test Run Example (BEFORE FIX)

```bash
$ flutter test test/core/security/noise/noise_session_concurrency_test.dart --reporter=expanded

00:01 +0: concurrent encrypt operations use unique nonces
⏱️  Concurrent encrypt (100 ops): 245ms
❌ Nonce collision detected! 98/100 unique (2 duplicates)
00:02 +0 -1: concurrent encrypt operations use unique nonces [E]
  Expected: 100
    Actual: 98
     Which: is not 100

FAILURE: 1 test passed, 1 failed, 3 skipped
```

---

## 🔧 Part 8: Troubleshooting Guide

### Common Test Failures

**Issue**: "NoiseSession not established"
```dart
// CAUSE: Session state check missing
// FIX: Add state validation before encrypt/decrypt
if (_state != NoiseSessionState.established) {
  throw StateError('Session not established');
}
```

**Issue**: "Database is locked"
```dart
// CAUSE: Missing await or concurrent access
// FIX: Use transactions and proper async/await
await db.transaction((txn) async {
  await txn.insert('table', data);
});
```

**Issue**: "Test hangs indefinitely"
```dart
// CAUSE: Missing await or infinite loop
// FIX: Add timeout to test
test('my test', () async {
  // ...
}, timeout: Timeout(Duration(seconds: 10)));
```

**Issue**: "FlutterSecureStorage MissingPluginException"
```dart
// CAUSE: Not using TestSetup harness
// FIX: Add to setUpAll
setUpAll(() async {
  await TestSetup.initializeTestEnvironment();
});
```

---

## 📚 Part 9: References

- **CLAUDE.md**: `/home/abubakar/dev/pak_connect/CLAUDE.md` (Architecture overview)
- **TESTING_STRATEGY.md**: `/home/abubakar/dev/pak_connect/TESTING_STRATEGY.md` (Test fundamentals)
- **EXECUTIVE_SUMMARY.md**: `/home/abubakar/dev/pak_connect/docs/review/EXECUTIVE_SUMMARY.md` (FYP review)
- **RECOMMENDED_FIXES.md**: `/home/abubakar/dev/pak_connect/docs/review/RECOMMENDED_FIXES.md` (Fix roadmap)

---

**Document Version**: 1.0
**Created**: 2025-11-11
**Next Review**: After Phase 1 completion
**Status**: Ready for execution

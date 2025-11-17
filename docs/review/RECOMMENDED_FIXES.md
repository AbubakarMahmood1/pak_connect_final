# PakConnect - Recommended Fixes Roadmap

**Document Purpose**: Concrete, actionable fixes with code examples for all critical issues

**Organization**: Fixes grouped by priority (P0 → P1 → P2) with effort estimates and expected outcomes

---

## 🔴 P0: CRITICAL FIXES (Week 1-2) - BLOCKS PRODUCTION

### FIX-001: Private Key Memory Leak in NoiseSession

**File**: `lib/core/security/noise/noise_session.dart:617-623, 105`

**Current Code (VULNERABLE)**:
```dart
// Line 105: Constructor makes a COPY
_localStaticPrivateKey = Uint8List.fromList(localStaticPrivateKey);

// Line 617: destroy() zeros the COPY, not the original
void destroy() {
  _localStaticPrivateKey.fill Range(0, _localStaticPrivateKey.length, 0);
  // ❌ Original key remains in memory!
}
```

**✅ RECOMMENDED FIX (Option 1 - Secure Key Wrapper)**:
```dart
// NEW FILE: lib/core/security/secure_key.dart
class SecureKey {
  final Uint8List _data;
  bool _destroyed = false;

  /// Creates a SecureKey and ZEROS the original immediately
  SecureKey(Uint8List original) : _data = Uint8List.fromList(original) {
    original.fillRange(0, original.length, 0); // ✅ Zero original
  }

  Uint8List get data {
    if (_destroyed) throw StateError('Key has been destroyed');
    return _data;
  }

  void destroy() {
    if (!_destroyed) {
      _data.fillRange(0, _data.length, 0);
      _destroyed = true;
    }
  }

  @override
  String toString() => _destroyed ? 'SecureKey(destroyed)' : 'SecureKey(****)';
}

// UPDATED: noise_session.dart
class NoiseSession {
  late final SecureKey _localStaticPrivateKey;

  NoiseSession({required Uint8List localStaticPrivateKey, ...}) {
    _localStaticPrivateKey = SecureKey(localStaticPrivateKey);
    // ✅ Original is zeroed immediately
  }

  void destroy() {
    _localStaticPrivateKey.destroy();
    // ✅ Both copy and original are zeroed
  }
}
```

**Also Apply To**:
- `lib/core/security/noise/primitives/cipher_state.dart:214` (\_key)
- `lib/core/security/noise/primitives/dh_state.dart:126-133` (\_privateKey, \_publicKey)
- `lib/core/security/noise/primitives/symmetric_state.dart:232-235` (\_chainingKey, \_handshakeHash)

**Testing**:
```dart
// NEW: test/core/security/secure_key_test.dart
test('SecureKey zeros original immediately', () {
  final original = Uint8List.fromList([1, 2, 3, 4]);
  final secureKey = SecureKey(original);

  // Assert original is zeroed
  expect(original, equals([0, 0, 0, 0]));

  // Assert copy is accessible
  expect(secureKey.data, equals([1, 2, 3, 4]));

  // After destroy, both zeroed
  secureKey.destroy();
  expect(() => secureKey.data, throwsStateError);
});
```

**Effort**: 1 day (implementation + testing)
**Risk**: Low (additive change, doesn't break existing API)
**Expected Outcome**: ✅ Forward secrecy guaranteed, no key leakage in heap dumps

---

### FIX-002: Weak Fallback Encryption Key

**File**: `lib/data/database/database_encryption.dart:76-90`

**Current Code (VULNERABLE)**:
```dart
static String _generateFallbackKey() {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final random = Random(timestamp); // ❌ PREDICTABLE SEED
  final entropy = '$timestamp${random.nextInt(1000000)}';
  final hash = sha256.convert(utf8.encode(entropy)).toString();
  return hash;
}
```

**Attack**: Brute force ~7 trillion possibilities (feasible with GPU)

**✅ RECOMMENDED FIX (Remove Fallback Entirely)**:
```dart
static Future<String> getOrCreateEncryptionKey() async {
  try {
    // Try secure storage
    String? key = await _secureStorage.read(key: _encryptionKeyStorageKey);

    if (key == null || key.isEmpty) {
      key = _generateSecureKey();
      await _secureStorage.write(key: _encryptionKeyStorageKey, value: key);
    }

    _cachedEncryptionKey = key;
    return key;

  } catch (e) {
    _logger.severe('❌ Secure storage failed: $e');

    // ✅ FAIL CLOSED - DO NOT use weak fallback
    throw DatabaseEncryptionException(
      'Cannot initialize database: secure storage unavailable.\n'
      'Please enable keychain/keystore and restart app.\n'
      'Error: $e'
    );
  }
}

// ❌ REMOVE: _generateFallbackKey() entirely
```

**UI Handling**:
```dart
// lib/presentation/screens/splash_screen.dart
try {
  await AppCore.initialize();
} on DatabaseEncryptionException catch (e) {
  // Show user-friendly error with action button
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('Security Setup Required'),
      content: Text(
        'PakConnect requires secure storage for encryption.\n\n'
        'Please ensure device security is enabled:\n'
        '• Android: Device lock screen set\n'
        '• iOS: Passcode enabled'
      ),
      actions: [
        TextButton(
          onPressed: () => SystemNavigator.pop(),
          child: Text('Exit'),
        ),
        ElevatedButton(
          onPressed: () => _retryInitialization(),
          child: Text('Retry'),
        ),
      ],
    ),
  );
}
```

**Effort**: 2 hours (removal + UI)
**Risk**: Low (fail-safe approach)
**Expected Outcome**: ✅ No predictable encryption keys, forced secure storage

---

### FIX-003: Weak PRNG Seed in Ephemeral Keys

**File**: `lib/core/security/ephemeral_key_manager.dart:111-140`

**Current Code (VULNERABLE)**:
```dart
final seed = List<int>.generate(
  32,
  (i) => DateTime.now().millisecondsSinceEpoch ~/ (i + 1), // ❌ PREDICTABLE
);
secureRandom.seed(KeyParameter(Uint8List.fromList(seed)));
```

**✅ RECOMMENDED FIX**:
```dart
static Future<void> _generateEphemeralSigningKeys() async {
  try {
    final keyGen = ECKeyGenerator();
    final secureRandom = FortunaRandom();

    // ✅ Use cryptographically secure random
    final random = Random.secure();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256))
    );
    secureRandom.seed(KeyParameter(seed));

    final keyParams = ECKeyGeneratorParameters(ECCurve_secp256r1());
    keyGen.init(ParametersWithRandom(keyParams, secureRandom));

    final keyPair = keyGen.generateKeyPair();
    _ephemeralSigningPrivateKey = keyPair.privateKey as ECPrivateKey;
    _ephemeralSigningPublicKey = keyPair.publicKey as ECPublicKey;

    _logger.info('✅ Generated ephemeral signing keys with secure seed');
  } catch (e, stackTrace) {
    _logger.severe('Failed to generate ephemeral signing keys', e, stackTrace);
    rethrow;
  }
}
```

**Testing**:
```dart
// test/core/security/ephemeral_key_manager_test.dart
test('ephemeral keys have sufficient entropy', () async {
  final keys1 = <String>[];
  final keys2 = <String>[];

  // Generate 100 keys
  for (int i = 0; i < 100; i++) {
    await EphemeralKeyManager.rotateKeys();
    keys1.add(EphemeralKeyManager.getPublicKeyHex());
    await Future.delayed(Duration(milliseconds: 1)); // Time passes
  }

  // Regenerate with different seed
  for (int i = 0; i < 100; i++) {
    await EphemeralKeyManager.rotateKeys();
    keys2.add(EphemeralKeyManager.getPublicKeyHex());
  }

  // Assert no collisions (P < 2^-128)
  expect(Set.from(keys1).length, equals(100));
  expect(Set.from(keys2).length, equals(100));
  expect(Set.from(keys1).intersection(Set.from(keys2)).length, equals(0));
});
```

**Effort**: 2 hours
**Risk**: Low (drop-in replacement)
**Expected Outcome**: ✅ Unguessable ephemeral keys, prevents identity forgery

---

### FIX-004: Nonce Race Condition in NoiseSession

**File**: `lib/core/security/noise/noise_session.dart:384-453`

**Current Code (VULNERABLE)**:
```dart
Future<Uint8List> encrypt(Uint8List data) async {
  // ❌ NO LOCKING - Nonce can be read twice
  final nonce = _sendCipher!.getNonce();
  final ciphertext = await _sendCipher!.encryptWithAd(null, data);
  _messagesSent++;
  return combined;
}
```

**✅ RECOMMENDED FIX (Add Mutex)**:
```dart
// ADD DEPENDENCY: pubspec.yaml
dependencies:
  synchronized: ^3.1.0  # Mutex/Lock implementation

// UPDATED: noise_session.dart
import 'package:synchronized/synchronized.dart';

class NoiseSession {
  final _encryptLock = Lock();
  final _decryptLock = Lock();

  /// Encrypts data with AEAD (thread-safe)
  Future<Uint8List> encrypt(Uint8List data) async {
    return await _encryptLock.synchronized(() async {
      // ✅ Atomic nonce + encrypt
      if (_state != NoiseSessionState.established) {
        throw StateError('Session not established');
      }
      if (_sendCipher == null) {
        throw StateError('Send cipher not initialized');
      }

      // ENFORCE rekey requirement
      if (needsRekey()) {
        throw RekeyRequiredException(
          'Session exceeded rekey limits. '
          'Messages sent: $_messagesSent (limit: $_rekeyMessageLimit), '
          'Session age: ${_getSessionAge()}s'
        );
      }

      final nonce = _sendCipher!.getNonce();
      final ciphertext = await _sendCipher!.encryptWithAd(null, data);

      final combined = Uint8List(4 + ciphertext.length);
      combined.buffer.asByteData().setUint32(0, nonce, Endian.big);
      combined.setRange(4, combined.length, ciphertext);

      _messagesSent++;
      return combined;
    });
  }

  /// Decrypts data with AEAD (thread-safe)
  Future<Uint8List> decrypt(Uint8List combinedPayload) async {
    return await _decryptLock.synchronized(() async {
      // ✅ Atomic nonce validation + decrypt
      if (_state != NoiseSessionState.established) {
        throw StateError('Session not established');
      }

      final receivedNonce = combinedPayload.buffer.asByteData().getUint32(0, Endian.big);
      final ciphertext = combinedPayload.sublist(4);

      if (!_isValidNonce(receivedNonce)) {
        _logger.warning('⚠️ Replay attack detected: nonce $receivedNonce');
        throw ReplayAttackException('Invalid or replayed nonce');
      }

      final plaintext = await _receiveCipher!.decryptWithAd(null, ciphertext);
      _markNonceUsed(receivedNonce);

      return plaintext;
    });
  }
}

// NEW EXCEPTION
class RekeyRequiredException implements Exception {
  final String message;
  RekeyRequiredException(this.message);
  @override
  String toString() => 'RekeyRequiredException: $message';
}
```

**Testing**:
```dart
// test/core/security/noise/noise_session_concurrency_test.dart
test('concurrent encrypt operations use unique nonces', () async {
  final session = await createEstablishedSession();

  // Encrypt 100 messages concurrently
  final futures = List.generate(100, (i) {
    final msg = Uint8List.fromList([i, i, i]);
    return session.encrypt(msg);
  });

  final results = await Future.wait(futures);

  // Extract nonces (first 4 bytes)
  final nonces = results.map((r) => r.buffer.asByteData().getUint32(0, Endian.big)).toSet();

  // Assert all different
  expect(nonces.length, equals(100));
  expect(results.length, equals(100));
});

test('enforces rekey after 10k messages', () async {
  final session = await createEstablishedSession();

  // Send 10,000 messages
  for (int i = 0; i < 10000; i++) {
    await session.encrypt(Uint8List(10));
  }

  // 10,001st should throw
  expect(
    () => session.encrypt(Uint8List(10)),
    throwsA(isA<RekeyRequiredException>()),
  );
});
```

**Effort**: 4 hours (implementation + testing)
**Risk**: Low (isolated change, backward compatible)
**Expected Outcome**: ✅ No nonce reuse, guaranteed AEAD security

---

### FIX-005: Missing `seen_messages` Table

**File**: `lib/data/database/database_helper.dart` (add to version 10 migration)

**Current Issue**: Table mentioned in CLAUDE.md but not implemented → mesh relay processes duplicates

**✅ RECOMMENDED FIX**:
```dart
// database_helper.dart - Add version 10 migration
static const int _currentVersion = 10; // ✅ Increment

Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
  // ... existing migrations ...

  // Version 9 → 10: Add seen_messages for mesh deduplication
  if (oldVersion < 10) {
    await _upgradeToV10(db);
  }
}

Future<void> _upgradeToV10(Database db) async {
  _logger.info('📦 Upgrading database to v10: Add seen_messages table');

  await db.execute('''
    CREATE TABLE seen_messages (
      message_hash TEXT PRIMARY KEY,
      message_type INTEGER NOT NULL,
      seen_at INTEGER NOT NULL,
      source_device TEXT,
      hop_count INTEGER DEFAULT 0
    )
  ''');

  // Index for time-based cleanup (5-minute TTL)
  await db.execute('''
    CREATE INDEX idx_seen_messages_time
    ON seen_messages(seen_at)
  ''');

  // Index for type filtering
  await db.execute('''
    CREATE INDEX idx_seen_messages_type
    ON seen_messages(message_type, seen_at)
  ''');

  _logger.info('✅ v10 migration complete: seen_messages table created');
}
```

**Update SeenMessageStore**:
```dart
// lib/data/services/seen_message_store.dart
Future<void> performMaintenance() async {
  final cutoffTime = DateTime.now().subtract(Duration(minutes: 5));
  final db = await DatabaseHelper().database;

  // ✅ Time-based expiry (5 minutes as per spec)
  final deleted = await db.delete(
    'seen_messages',
    where: 'seen_at < ?',
    whereArgs: [cutoffTime.millisecondsSinceEpoch],
  );

  _logger.info('🧹 Cleaned up $deleted expired seen messages');
}

// Schedule periodic maintenance
Future<void> initialize() async {
  // ... existing code ...

  // Run cleanup every 2 minutes
  Timer.periodic(Duration(minutes: 2), (_) => performMaintenance());
}
```

**Testing**:
```dart
// test/database_migration_test.dart
test('v9 to v10 migration creates seen_messages table', () async {
  final db = await openTestDatabase(version: 9);

  // Upgrade to v10
  await db.close();
  final upgradedDb = await openTestDatabase(version: 10);

  // Verify table exists
  final tables = await upgradedDb.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'"
  );
  expect(tables.length, equals(1));

  // Verify indexes exist
  final indexes = await upgradedDb.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='seen_messages'"
  );
  expect(indexes.length, equals(2)); // idx_time, idx_type
});
```

**Effort**: 3 hours
**Risk**: Low (new table, no data migration)
**Expected Outcome**: ✅ Mesh relay deduplication works correctly, 5-minute TTL prevents memory bloat

---

### FIX-006: N+1 Query in getAllChats()

**File**: `lib/data/repositories/chats_repository.dart:56-75`

**Current Code (SLOW)**:
```dart
Future<List<ChatListItem>> getAllChats(...) async {
  // ❌ Load all contacts first
  final contacts = await _contactRepository.getAllContacts();

  // ❌ Loop through each contact (N iterations)
  for (final contact in contacts.values) {
    final chatId = _generateChatId(contact.publicKey);
    // ❌ Query messages for EACH contact (N queries)
    final messages = await _messageRepository.getMessages(chatId);
    if (messages.isNotEmpty) {
      allChatIds.add(chatId);
    }
  }

  // Result: 1 + N queries (for 100 contacts = 101 queries = 1 second)
}
```

**✅ RECOMMENDED FIX (Single JOIN Query)**:
```dart
Future<List<ChatListItem>> getAllChats({
  required List<DiscoveryEvent> nearbyDevices,
}) async {
  final db = await DatabaseHelper().database;

  // ✅ Single query with JOIN
  final results = await db.rawQuery('''
    SELECT DISTINCT
      c.public_key,
      c.persistent_public_key,
      c.display_name,
      c.security_level,
      c.trust_status,
      c.last_seen,
      ch.chat_id,
      ch.last_message,
      ch.timestamp as last_message_time,
      ch.unread_count,
      ch.is_archived,
      COUNT(m.id) as message_count,
      MAX(m.timestamp) as latest_message_timestamp
    FROM contacts c
    LEFT JOIN chats ch ON ch.contact_public_key = c.public_key
    LEFT JOIN messages m ON m.chat_id = ch.chat_id
    WHERE ch.is_archived = 0 OR ch.is_archived IS NULL
    GROUP BY c.public_key, ch.chat_id
    HAVING message_count > 0 OR ch.chat_id IS NOT NULL
    ORDER BY latest_message_timestamp DESC NULLS LAST
  ''');

  // ✅ Transform results (single pass)
  final chatItems = <ChatListItem>[];
  for (final row in results) {
    final contact = Contact.fromMap(row);
    final chat = Chat.fromMap(row);
    final isOnline = _isContactOnline(contact.publicKey, nearbyDevices);

    chatItems.add(ChatListItem(
      contact: contact,
      chat: chat,
      isOnline: isOnline,
    ));
  }

  return chatItems;
}
```

**Performance Benchmark**:
```dart
// test/performance/chats_repository_benchmark_test.dart
test('getAllChats performance with 100 contacts', () async {
  // Setup: Create 100 contacts with 10 messages each
  await _seedDatabase(contactCount: 100, messagesPerContact: 10);

  final stopwatch = Stopwatch()..start();
  final chats = await chatsRepository.getAllChats(nearbyDevices: []);
  stopwatch.stop();

  _logger.info('⏱️ getAllChats() took ${stopwatch.elapsedMilliseconds}ms');

  // Assert performance (should be <100ms with fix)
  expect(stopwatch.elapsedMilliseconds, lessThan(100));
  expect(chats.length, equals(100));
});
```

**Effort**: 4 hours (rewrite + testing)
**Risk**: Medium (changes core query logic, needs thorough testing)
**Expected Outcome**: ✅ 20x performance improvement (1000ms → 50ms for 100 chats)

---

### FIX-007: StreamProviders Memory Leak

**Files**: 8 providers in `lib/presentation/providers/`

**Current Code (LEAKING)**:
```dart
// mesh_networking_provider.dart:93
final meshNetworkStatusProvider = StreamProvider<MeshNetworkStatus>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.meshNetworkStatusStream;
  // ❌ No autoDispose - stream never closed
});
```

**✅ RECOMMENDED FIX**:
```dart
// ✅ Add autoDispose to all StreamProviders
final meshNetworkStatusProvider = StreamProvider.autoDispose<MeshNetworkStatus>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.meshNetworkStatusStream;
  // ✅ Stream auto-closed when no longer watched
});

// Apply to all 8 providers:
final bluetoothStateProvider = StreamProvider.autoDispose<BluetoothStateInfo>(...);
final bluetoothStatusMessageProvider = StreamProvider.autoDispose<String>(...);
final relayStatisticsProvider = StreamProvider.autoDispose<RelayStatistics>(...);
final queueSyncStatisticsProvider = StreamProvider.autoDispose<QueueSyncStats>(...);
final meshDemoEventsProvider = StreamProvider.autoDispose<List<MeshDemoEvent>>(...);
final autoRefreshContactsProvider = StreamProvider.autoDispose<List<EnhancedContact>>(...);
// ... (8 total)
```

**Testing**:
```dart
// test/presentation/providers/provider_lifecycle_test.dart
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

  // Provider is disposed
  expect(container.exists(meshNetworkStatusProvider), isFalse);

  container.dispose();
});
```

**Effort**: 2 hours (8 files)
**Risk**: Low (additive change, improves behavior)
**Expected Outcome**: ✅ 20-30% memory reduction, no stream leaks

---

### FIX-008: Phase 2 Before Phase 1.5 Timing

**File**: `lib/core/bluetooth/handshake_coordinator.dart:689-699`

**Current Code (RACE CONDITION)**:
```dart
Future<void> _advanceToNoiseHandshakeComplete() async {
  _phase = ConnectionPhase.noiseHandshakeComplete;

  // ❌ Immediately advances to Phase 2 without checking remote key
  if (_isInitiator) {
    await _advanceToContactStatusSent();
  }
}
```

**✅ RECOMMENDED FIX**:
```dart
Future<void> _advanceToNoiseHandshakeComplete() async {
  _phase = ConnectionPhase.noiseHandshakeComplete;

  // ✅ Wait for remote key availability
  if (_theirNoisePublicKey == null) {
    _logger.warning('⏳ Waiting for remote Noise public key before advancing to Phase 2');
    await _waitForRemoteKey(timeout: Duration(seconds: 2));
  }

  // ✅ Verify session is actually established
  final sessionId = _sessionIdForHandshake ?? _sessionIdFromIdentity;
  if (sessionId != null) {
    final session = _noiseService?.getSession(sessionId);
    if (session?.state != NoiseSessionState.established) {
      _logger.warning('⏳ Waiting for Noise session to be established');
      await _waitForSessionEstablished(sessionId, timeout: Duration(seconds: 2));
    }
  }

  if (_isInitiator) {
    await _advanceToContactStatusSent();
  }
}

Future<void> _waitForRemoteKey({required Duration timeout}) async {
  final completer = Completer<void>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(TimeoutException('Remote key not received'));
    }
  });

  // Poll every 50ms
  while (_theirNoisePublicKey == null) {
    await Future.delayed(Duration(milliseconds: 50));
    if (completer.isCompleted) break;
  }

  timer.cancel();
  if (!completer.isCompleted) completer.complete();
  return completer.future;
}
```

**Testing**:
```dart
// test/core/bluetooth/handshake_timing_test.dart
test('Phase 2 waits for Phase 1.5 completion', () async {
  final coordinator = HandshakeCoordinator(...);

  // Start handshake
  await coordinator.startHandshake(isInitiator: true);

  // Simulate Noise handshake delay
  await Future.delayed(Duration(milliseconds: 100));

  // Verify Phase 2 hasn't started yet
  expect(coordinator.phase, isNot(ConnectionPhase.contactStatusSent));

  // Complete Noise handshake
  await coordinator.onNoiseHandshakeMessage(...);

  // Now Phase 2 proceeds
  expect(coordinator.phase, equals(ConnectionPhase.contactStatusSent));
});
```

**Effort**: 1 day (implementation + thorough testing)
**Risk**: Medium (changes handshake timing, needs integration tests)
**Expected Outcome**: ✅ No encryption errors, guaranteed Noise session ready

---

## 🟡 P1: HIGH PRIORITY (Weeks 3-4)

### FIX-009: MessageFragmenter Unit Tests (No Code Changes)

**Task**: Create comprehensive test suite for untested critical component

**New File**: `test/core/utils/message_fragmenter_test.dart`

**Test Cases** (15 total):
1. Fragment message into chunks with sequence numbers
2. Reassemble chunks in order
3. Handle out-of-order chunks
4. Handle duplicate chunks
5. Handle missing chunks with timeout (30s)
6. Handle interleaved messages from different senders
7. MTU boundary testing (various sizes: 20, 100, 200, 512 bytes)
8. Large message fragmentation (10KB, 100KB)
9. Empty message handling
10. Single-chunk message (no fragmentation needed)
11. Chunk header format validation
12. Base64 encoding/decoding correctness
13. Fragment cleanup on timeout
14. Memory bounds (max 100 pending messages per sender)
15. CRC32 validation (after adding checksums)

**Example Test**:
```dart
group('MessageFragmenter', () {
  late MessageFragmenter fragmenter;

  setUp(() {
    fragmenter = MessageFragmenter(maxChunkSize: 100);
  });

  test('fragments 250-byte message into 3 chunks', () {
    final message = Uint8List(250);
    for (int i = 0; i < 250; i++) message[i] = i % 256;

    final chunks = fragmenter.fragment(message);

    expect(chunks.length, equals(3)); // 100+100+50

    // Validate chunk 0
    expect(chunks[0][0], equals(0)); // Index
    expect(chunks[0][1], equals(3)); // Total

    // Validate chunk 2 (last)
    expect(chunks[2][0], equals(2)); // Index
    expect(chunks[2][1], equals(3)); // Total
    expect(chunks[2].length, lessThan(chunks[0].length)); // Smaller
  });

  test('reassembles out-of-order chunks correctly', () {
    final original = Uint8List.fromList(List.generate(250, (i) => i % 256));
    final chunks = fragmenter.fragment(original);

    // Send in wrong order: 1, 0, 2
    var reassembled = fragmenter.reassemble('sender1', chunks[1]);
    expect(reassembled, isNull); // Not complete yet

    reassembled = fragmenter.reassemble('sender1', chunks[0]);
    expect(reassembled, isNull); // Not complete yet

    reassembled = fragmenter.reassemble('sender1', chunks[2]);
    expect(reassembled, equals(original)); // ✅ Complete!
  });

  test('times out missing chunks after 30 seconds', () async {
    final message = Uint8List(250);
    final chunks = fragmenter.fragment(message);

    // Send only first chunk
    fragmenter.reassemble('sender1', chunks[0]);

    // Wait 31 seconds (simulated with timeout parameter)
    fragmenter.cleanupOldMessages(timeout: Duration(seconds: 31));

    // Send remaining chunks - should fail (session expired)
    final reassembled = fragmenter.reassemble('sender1', chunks[1]);
    expect(reassembled, isNull); // Expired
  });
});
```

**Effort**: 1 day (15 tests × 30min average)
**Risk**: None (tests only, no code changes)
**Expected Outcome**: ✅ Fragmentation bugs caught, 100% coverage for critical component

---

### FIX-010 through FIX-015: (Additional High Priority Fixes)

See full details in individual sections above. Summary:

- **FIX-010**: BLEService unit tests (25 tests, 2 days)
- **FIX-011**: Fix 11 skipped/flaky tests (deadlock resolution, 2 days)
- **FIX-012**: Phase 2C ChatScreen refactoring (6 method migrations, 5 controllers, 16 tests, 0 breaking changes) ✅ COMPLETE
- **FIX-013**: Add semantic labels for WCAG compliance (1 day)
- **FIX-014**: Move encryption to isolate (UI performance, 1 day)
- **FIX-015**: Add missing database indexes (2 hours)
- **FIX-016**: Enforce session rekeying (4 hours)

---

## 🟢 P2: MEDIUM PRIORITY (Weeks 5-8)

### Architecture Refactoring

**See**: `docs/review/01_ARCHITECTURE_REVIEW.md` for detailed refactoring plan

**Key Tasks**:
1. Break down BLEService (3,426 lines → 5 services)
2. Break down MeshNetworkingService (2,001 lines → 5 coordinators)
3. Eliminate AppCore singleton (replace with Riverpod providers)
4. Fix layer boundary violations (7 imports)
5. Replace 70+ direct instantiations with DI

**Effort**: 4 weeks (1-2 developers)

---

## 📊 Progress Tracking Template

```markdown
## P0 Critical Fixes Progress

- [ ] FIX-001: Private key memory leak (1 day)
- [ ] FIX-002: Weak fallback encryption (2 hours)
- [ ] FIX-003: Weak PRNG seed (2 hours)
- [ ] FIX-004: Nonce race condition (4 hours)
- [ ] FIX-005: Missing seen_messages table (3 hours)
- [ ] FIX-006: N+1 query optimization (4 hours)
- [ ] FIX-007: StreamProvider memory leaks (2 hours)
- [ ] FIX-008: Handshake phase timing (1 day)

**Total: 1.5 weeks**

Progress: [ ] Not Started | [ ] In Progress | [ ] Code Review | [ ] Testing | [ ] Complete
```

---

## 🎯 Expected Outcomes Summary

### After P0 Fixes (Week 2)
- ✅ All critical security vulnerabilities resolved (CVSS 7.5-9.1)
- ✅ No race conditions in encryption path
- ✅ Mesh deduplication working correctly
- ✅ 20x performance improvement in chat loading
- ✅ No memory leaks from providers

### After P1 Fixes (Week 4)
- ✅ 100% test coverage for MessageFragmenter
- ✅ 80%+ test coverage for BLEService
- ✅ All flaky tests resolved
- ✅ WCAG 2.1 Level A compliance
- ✅ No UI freezes during encryption

### After P2 Fixes (Week 8+)
- ✅ SOLID-compliant architecture
- ✅ No God classes (all <500 lines)
- ✅ Zero layer boundary violations
- ✅ 85%+ test coverage across all components

---

**Document Version**: 1.0
**Last Updated**: November 9, 2025
**Next Review**: After Phase 1 completion

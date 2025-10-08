# pak_connect Testing Strategy & Roadmap
## Comprehensive Test Suite Overhaul - Future-Proof Investment Plan

**Status**: In Progress | **Target**: 100% Pass Rate + >80% Coverage | **Timeline**: 5 Days

---

## Executive Summary

### Current State
- **Test Pass Rate**: 46% (124 passing, 141 failing, 5 skipped)
- **File Coverage**: ~21% (26 test files / 123 production files)
- **Service Coverage**: ~44% (15 tested / 34 major services)
- **Critical Issue**: Logger conflicts causing cascading failures

### Target State
- **Test Pass Rate**: 100% (all tests green)
- **Coverage**: >80% for critical paths, >70% overall
- **Test Count**: ~300+ comprehensive tests
- **CI/CD Ready**: Fast, reliable, isolated tests

### Investment ROI
- **Time**: 3-5 days focused work
- **Value**: 10-20 hours/month saved in debugging
- **Benefit**: Confident refactoring, safe iterations, living documentation

---

## Testing Fundamentals: Quick Reference

### Types of Tests (Bottom to Top)

#### 1. Unit Tests (70% of your suite)
**What**: Test individual functions/methods in isolation
**Why**: Fast, precise, easy to debug
**Example**: Testing `MessageSecurity.encrypt()` with mocked dependencies

```dart
// GOOD Unit Test Example
test('encrypt should return encrypted message with valid key', () {
  // Arrange: Set up test data
  final security = MessageSecurity();
  final plaintext = 'Hello World';
  final key = 'test_key_32_bytes_long_string';

  // Act: Execute the function
  final result = security.encrypt(plaintext, key);

  // Assert: Verify expectations
  expect(result, isNotNull);
  expect(result, isNot(equals(plaintext)));
  expect(result.length, greaterThan(0));
});
```

#### 2. Integration Tests (20% of your suite)
**What**: Test multiple components working together
**Why**: Verify interactions between layers
**Example**: Testing message flow from Repository → Service → Database

```dart
// GOOD Integration Test Example
test('archiveChat should move chat and messages to archive tables', () async {
  // Arrange: Set up real dependencies working together
  final db = await DatabaseHelper.database;
  final chatsRepo = ChatsRepository();
  final archiveRepo = ArchiveRepository();
  final archiveService = ArchiveManagementService(
    chatsRepository: chatsRepo,
    archiveRepository: archiveRepo,
  );

  // Create test data
  await chatsRepo.createChat('test_chat', 'Test User');
  await chatsRepo.addMessage('test_chat', 'Hello', isFromMe: true);

  // Act: Execute the business flow
  await archiveService.archiveChat('test_chat');

  // Assert: Verify end-to-end behavior
  final archivedChat = await archiveRepo.getArchivedChat('test_chat');
  expect(archivedChat, isNotNull);
  expect(archivedChat!.chatId, equals('test_chat'));

  final activeChats = await chatsRepo.getAllChats();
  expect(activeChats.any((c) => c.chatId == 'test_chat'), isFalse);
});
```

#### 3. Widget Tests (10% of your suite)
**What**: Test UI components in isolation
**Why**: Verify user interactions and rendering
**Example**: Testing `ModernMessageBubble` renders correctly

```dart
// GOOD Widget Test Example
testWidgets('ModernMessageBubble displays message content', (tester) async {
  // Arrange
  final message = Message(
    id: 'msg1',
    content: 'Test message',
    timestamp: DateTime.now(),
    isFromMe: true,
  );

  // Act
  await tester.pumpWidget(
    MaterialApp(home: ModernMessageBubble(message: message)),
  );

  // Assert
  expect(find.text('Test message'), findsOneWidget);
  expect(find.byType(ModernMessageBubble), findsOneWidget);
});
```

### Test Isolation Principles

#### ✅ DO: Mock External Dependencies
```dart
// Mock SharedPreferences
SharedPreferences.setMockInitialValues({});

// Mock database with in-memory instance
sqfliteFfiInit();
databaseFactory = databaseFactoryFfi;

// Mock time for deterministic tests
final mockClock = Clock.fixed(DateTime(2024, 1, 1));
```

#### ❌ DON'T: Share State Between Tests
```dart
// BAD: Global state pollution
late DatabaseHelper db;
setUpAll(() async {
  db = await DatabaseHelper.database; // ❌ Shared across tests
});

// GOOD: Isolated state per test
setUp(() async {
  await DatabaseHelper.close();
  await DatabaseHelper.deleteDatabase(); // ✅ Clean slate
});
```

### AAA Pattern (Arrange-Act-Assert)

**Every test should follow this structure:**

```dart
test('descriptive name of what is being tested', () async {
  // ARRANGE: Set up test conditions
  final service = MyService();
  final input = 'test data';

  // ACT: Execute the behavior
  final result = await service.doSomething(input);

  // ASSERT: Verify expectations
  expect(result, equals(expectedOutput));
});
```

---

## Phase-by-Phase Implementation Plan

### Phase 1: Fix Foundation (Day 1) ⚡ CRITICAL

**Goal**: Achieve 100% pass rate on existing 270 tests

#### Issues to Fix

##### 1.1 Logger Stream Controller Conflicts
**Problem**: Logger firing events recursively during tests
**Location**: Affects 100+ tests in queue_sync, relay, routing tests
**Root Cause**: `Logger.root.onRecord.listen()` inside test groups

**Solution**:
```dart
// BEFORE (❌ Broken)
group('My Tests', () {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    testLogger.info('${record.message}'); // ❌ Creates loop
  });
});

// AFTER (✅ Fixed)
setUpAll(() {
  Logger.root.level = Level.WARNING; // Reduce noise
  // Remove recursive listener entirely OR
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.message}'); // ✅ Use print
  });
});
```

**Files to Fix**:
- `test/queue_sync_system_test.dart`
- `test/message_retry_coordination_test.dart`
- `test/mesh_relay_integration_test.dart`
- `test/ali_arshad_abubakar_relay_test.dart`
- All files with `Logger.root.onRecord.listen((record) => testLogger.*)`

##### 1.2 Plugin Mocking Standardization
**Problem**: Inconsistent sqflite setup, SharedPreferences failures
**Solution**: Create standard test setup file

**Create**: `test/test_helpers/test_setup.dart`
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Standard test environment setup for pak_connect tests
class TestSetup {
  static Future<void> initializeTestEnvironment() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Initialize sqflite_ffi for database tests
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // Initialize SharedPreferences with empty state
    SharedPreferences.setMockInitialValues({});
  }

  static Future<void> cleanupDatabase() async {
    await DatabaseHelper.close();
    await DatabaseHelper.deleteDatabase();
  }
}
```

**Usage**:
```dart
// In every test file
import 'test_helpers/test_setup.dart';

setUpAll(() async {
  await TestSetup.initializeTestEnvironment();
});

setUp(() async {
  await TestSetup.cleanupDatabase();
});
```

##### 1.3 Test Isolation & Timeouts
**Problem**: Tests hang, timeout at 3 minutes
**Solution**: Add proper async handling and cleanup

```dart
// BEFORE (❌ May hang)
test('my test', () async {
  final service = MyService();
  await service.initialize();
  // Missing cleanup!
});

// AFTER (✅ Properly isolated)
test('my test', () async {
  final service = MyService();
  await service.initialize();

  try {
    // Test logic
  } finally {
    service.dispose(); // ✅ Always cleanup
  }
});
```

#### Phase 1 Checklist

- [ ] Create `test/test_helpers/test_setup.dart`
- [ ] Fix logger conflicts in 10+ test files
- [ ] Standardize database setup across all tests
- [ ] Add proper teardown to all tests
- [ ] Run `flutter test` and verify 270/270 passing
- [ ] Document test setup patterns in this file

**Success Criteria**: `flutter test` shows 100% pass rate

---

### Phase 2: Core Business Logic (Days 2-3) 🎯 HIGH VALUE

**Goal**: Test untested critical services and repositories

#### Priority 1: Security & Encryption (Critical)

##### 2.1 SecurityManager Tests
**File**: `test/security_manager_test.dart` (NEW)
**Coverage Target**: >90%

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async => await TestSetup.initializeTestEnvironment());
  setUp(() async => await TestSetup.cleanupDatabase());

  group('SecurityManager', () {
    late SecurityManager securityManager;

    setUp(() {
      securityManager = SecurityManager();
    });

    tearDown(() {
      securityManager.dispose();
    });

    group('Key Generation', () {
      test('should generate unique keypair on initialization', () async {
        await securityManager.initialize();

        final publicKey = securityManager.getPublicKey();
        expect(publicKey, isNotNull);
        expect(publicKey.length, greaterThan(0));
      });

      test('should persist keypair across sessions', () async {
        await securityManager.initialize();
        final firstPublicKey = securityManager.getPublicKey();

        // Simulate app restart
        securityManager.dispose();
        final newManager = SecurityManager();
        await newManager.initialize();

        final secondPublicKey = newManager.getPublicKey();
        expect(secondPublicKey, equals(firstPublicKey));

        newManager.dispose();
      });

      test('should generate different keys for different devices', () async {
        final manager1 = SecurityManager();
        final manager2 = SecurityManager();

        await TestSetup.cleanupDatabase();
        await manager1.initialize();
        final key1 = manager1.getPublicKey();

        await TestSetup.cleanupDatabase();
        await manager2.initialize();
        final key2 = manager2.getPublicKey();

        expect(key1, isNot(equals(key2)));

        manager1.dispose();
        manager2.dispose();
      });
    });

    group('Message Encryption', () {
      test('should encrypt and decrypt message successfully', () async {
        await securityManager.initialize();

        final plaintext = 'Sensitive message content';
        final recipientKey = 'recipient_public_key_example';

        final encrypted = await securityManager.encryptMessage(
          plaintext,
          recipientKey,
        );

        expect(encrypted, isNot(equals(plaintext)));
        expect(encrypted.length, greaterThan(plaintext.length));
      });

      test('should fail decryption with wrong key', () async {
        // Implementation test
      });

      test('should handle large messages (>1MB)', () async {
        // Edge case test
      });
    });

    group('Key Rotation', () {
      test('should rotate ephemeral keys on schedule', () async {
        // Time-based test using Clock mock
      });
    });
  });
}
```

**What to Test**:
- ✅ Key generation (uniqueness, persistence)
- ✅ Encryption/decryption roundtrip
- ✅ Key storage and retrieval
- ✅ Error handling (invalid keys, corrupted data)
- ✅ Edge cases (empty messages, very large messages)

##### 2.2 EphemeralKeyManager Tests
**File**: `test/ephemeral_key_manager_test.dart` (NEW)
**Focus**: Key rotation, TTL, cleanup

##### 2.3 SpamPreventionManager Tests
**File**: Enhance existing `test/hint_system_test.dart`
**Focus**: Rate limiting, signature verification, blacklisting

#### Priority 2: Data Layer (Repositories)

##### 2.4 ChatsRepository Tests
**File**: Enhance `test/chats_repository_sqlite_test.dart`
**Current**: 15 tests | **Target**: 35+ tests

**Missing Coverage**:
```dart
group('ChatsRepository - Advanced', () {
  test('should handle concurrent chat creation safely', () async {
    // Test race conditions
    final futures = List.generate(10, (i) =>
      chatsRepo.createChat('chat_$i', 'User $i')
    );
    await Future.wait(futures);

    final chats = await chatsRepo.getAllChats();
    expect(chats.length, equals(10));
  });

  test('should update last_message_at when message added', () async {
    final chatId = 'test_chat';
    await chatsRepo.createChat(chatId, 'Test');

    final beforeTime = DateTime.now();
    await Future.delayed(Duration(milliseconds: 100));
    await chatsRepo.addMessage(chatId, 'New message', isFromMe: true);

    final chat = await chatsRepo.getChat(chatId);
    expect(chat!.lastMessageAt.isAfter(beforeTime), isTrue);
  });

  test('should paginate large chat lists efficiently', () async {
    // Create 100 chats
    for (int i = 0; i < 100; i++) {
      await chatsRepo.createChat('chat_$i', 'User $i');
    }

    // Test pagination
    final page1 = await chatsRepo.getChats(limit: 20, offset: 0);
    final page2 = await chatsRepo.getChats(limit: 20, offset: 20);

    expect(page1.length, equals(20));
    expect(page2.length, equals(20));
    expect(page1.first.chatId, isNot(equals(page2.first.chatId)));
  });
});
```

##### 2.5 ArchiveRepository Tests
**File**: Enhance `test/archive_repository_sqlite_test.dart`
**Focus**: FTS5 search, archive/restore, data migration

##### 2.6 MessageRepository Tests
**File**: Enhance `test/message_repository_sqlite_test.dart`
**Focus**: Enhanced message fields, reactions, threading

#### Priority 3: Domain Services

##### 2.7 ArchiveManagementService Tests
**File**: `test/archive_management_service_test.dart` (NEW)
**Integration Test**: Repository + Service layer

```dart
group('ArchiveManagementService', () {
  late ArchiveManagementService archiveService;
  late ChatsRepository chatsRepo;
  late ArchiveRepository archiveRepo;

  setUp(() async {
    chatsRepo = ChatsRepository();
    archiveRepo = ArchiveRepository();
    archiveService = ArchiveManagementService(
      chatsRepository: chatsRepo,
      archiveRepository: archiveRepo,
    );
  });

  test('archiveChat should move chat with all messages', () async {
    // Create chat with messages
    await chatsRepo.createChat('chat1', 'Test User');
    await chatsRepo.addMessage('chat1', 'Message 1', isFromMe: true);
    await chatsRepo.addMessage('chat1', 'Message 2', isFromMe: false);

    // Archive
    final result = await archiveService.archiveChat('chat1');
    expect(result.success, isTrue);

    // Verify moved
    final archivedChat = await archiveRepo.getArchivedChat('chat1');
    expect(archivedChat, isNotNull);
    expect(archivedChat!.messageCount, equals(2));

    // Verify removed from active
    final activeChat = await chatsRepo.getChat('chat1');
    expect(activeChat, isNull);
  });

  test('restoreChat should move chat back to active', () async {
    // Archive first
    await chatsRepo.createChat('chat1', 'Test User');
    await archiveService.archiveChat('chat1');

    // Restore
    final result = await archiveService.restoreChat('chat1');
    expect(result.success, isTrue);

    // Verify in active chats
    final activeChat = await chatsRepo.getChat('chat1');
    expect(activeChat, isNotNull);

    // Verify removed from archive
    final archivedChat = await archiveRepo.getArchivedChat('chat1');
    expect(archivedChat, isNull);
  });

  test('should handle archive of non-existent chat gracefully', () async {
    final result = await archiveService.archiveChat('nonexistent');
    expect(result.success, isFalse);
    expect(result.error, contains('not found'));
  });
});
```

##### 2.8 ContactManagementService Tests
**File**: `test/contact_management_service_test.dart` (NEW)
**Focus**: Contact verification, trust scoring, blocking

##### 2.9 ChatManagementService Tests
**File**: `test/chat_management_service_test.dart` (NEW)
**Focus**: Chat lifecycle, message handling, search

#### Phase 2 Checklist

**Security Tests**:
- [ ] SecurityManager (35+ tests)
- [ ] EphemeralKeyManager (25+ tests)
- [ ] SpamPreventionManager (enhanced)
- [ ] MessageSecurity (20+ tests)

**Repository Tests**:
- [ ] ChatsRepository (35+ tests total)
- [ ] ArchiveRepository (30+ tests)
- [ ] MessageRepository (40+ tests)
- [ ] ContactRepository (enhanced)

**Service Tests**:
- [ ] ArchiveManagementService (25+ tests)
- [ ] ContactManagementService (30+ tests)
- [ ] ChatManagementService (35+ tests)

**Success Criteria**: 200+ additional tests, >80% coverage on data/domain layers

---

### Phase 3: Integration & Critical Paths (Day 4) 🔗 HIGH CONFIDENCE

**Goal**: Verify complete workflows end-to-end

#### 3.1 End-to-End Message Flow
**File**: `test/integration/e2e_message_flow_test.dart` (NEW)

```dart
group('E2E Message Flow Integration', () {
  test('send message → relay → receive → persist complete flow', () async {
    // Simulate 3 nodes: Alice, Bob (relay), Charlie
    final alice = await createTestNode('alice');
    final bob = await createTestNode('bob');
    final charlie = await createTestNode('charlie');

    // Alice sends message to Charlie via Bob
    final messageId = await alice.sendMessage(
      recipientId: charlie.nodeId,
      content: 'Hello Charlie from Alice!',
    );

    // Verify message queued at Alice
    final aliceQueue = await alice.getQueuedMessages();
    expect(aliceQueue.any((m) => m.id == messageId), isTrue);

    // Simulate Alice → Bob transmission
    final relayMessage = await alice.getOutgoingMessage(messageId);
    await bob.receiveMessage(relayMessage, fromNode: alice.nodeId);

    // Verify Bob relays (doesn't process)
    final bobMessages = await bob.getReceivedMessages();
    expect(bobMessages, isEmpty); // Bob doesn't process

    final bobOutgoing = await bob.getOutgoingMessages();
    expect(bobOutgoing.length, equals(1)); // Bob relays

    // Simulate Bob → Charlie transmission
    final forwardedMessage = bobOutgoing.first;
    await charlie.receiveMessage(forwardedMessage, fromNode: bob.nodeId);

    // Verify Charlie receives and persists
    final charlieMessages = await charlie.getReceivedMessages();
    expect(charlieMessages.length, equals(1));
    expect(charlieMessages.first.content, equals('Hello Charlie from Alice!'));
    expect(charlieMessages.first.originalSender, equals(alice.nodeId));

    // Verify message persisted in database
    final db = await DatabaseHelper.database;
    final dbMessages = await db.query('messages',
      where: 'id = ?',
      whereArgs: [messageId]
    );
    expect(dbMessages, isNotEmpty);
  });
});
```

#### 3.2 Archive Lifecycle Integration
**File**: `test/integration/archive_lifecycle_test.dart` (NEW)

```dart
test('archive → search → restore complete lifecycle', () async {
  // Create chat with diverse content
  final chatId = 'lifecycle_test_chat';
  await createChatWithMessages(chatId, messageCount: 50);

  // Archive
  final archiveResult = await archiveService.archiveChat(chatId);
  expect(archiveResult.success, isTrue);

  // Search in archive
  final searchResults = await archiveSearchService.search(
    query: 'search term',
    chatId: chatId,
  );
  expect(searchResults, isNotEmpty);

  // Verify FTS5 index updated
  final ftsResults = await db.rawQuery('''
    SELECT * FROM archived_messages_fts
    WHERE archived_messages_fts MATCH ?
  ''', ['search term']);
  expect(ftsResults, isNotEmpty);

  // Restore
  final restoreResult = await archiveService.restoreChat(chatId);
  expect(restoreResult.success, isTrue);

  // Verify all messages restored
  final restoredMessages = await chatsRepo.getMessages(chatId);
  expect(restoredMessages.length, equals(50));
});
```

#### 3.3 Security Flow Integration
**File**: `test/integration/security_flow_test.dart` (NEW)

```dart
test('key generation → encryption → transmission → decryption flow', () async {
  // Node A generates keys
  final nodeA = SecurityManager();
  await nodeA.initialize();
  final publicKeyA = nodeA.getPublicKey();

  // Node B generates keys
  final nodeB = SecurityManager();
  await nodeB.initialize();
  final publicKeyB = nodeB.getPublicKey();

  // Node A encrypts message for Node B
  final plaintext = 'Confidential message';
  final encrypted = await nodeA.encryptMessage(plaintext, publicKeyB);

  // Simulate transmission (encrypted data only)
  // ...

  // Node B decrypts message
  final decrypted = await nodeB.decryptMessage(encrypted, publicKeyA);
  expect(decrypted, equals(plaintext));

  // Verify ephemeral keys rotated
  await Future.delayed(Duration(seconds: 61)); // TTL = 60s
  final rotated = await nodeA.checkKeyRotation();
  expect(rotated, isTrue);
});
```

#### 3.4 Database Migration Integration
**File**: Enhance `test/database_migration_test.dart`

```dart
test('v1 → v2 → v3 migration preserves all data', () async {
  // Create v1 database
  await createV1Database();
  await insertV1TestData();

  // Migrate to v2
  await DatabaseHelper.migrate(from: 1, to: 2);
  final v2Valid = await DatabaseHelper.verifyIntegrity();
  expect(v2Valid, isTrue);

  // Verify v2 features work
  await testV2Features();

  // Migrate to v3
  await DatabaseHelper.migrate(from: 2, to: 3);
  final v3Valid = await DatabaseHelper.verifyIntegrity();
  expect(v3Valid, isTrue);

  // Verify all original data intact
  final originalCount = await getV1DataCount();
  final finalCount = await getV3DataCount();
  expect(finalCount, equals(originalCount));
});
```

#### Phase 3 Checklist

- [ ] E2E message flow (send → relay → receive)
- [ ] Archive lifecycle (archive → search → restore)
- [ ] Security flow (encrypt → transmit → decrypt)
- [ ] Database migrations (v1 → v2 → v3)
- [ ] Queue synchronization across nodes
- [ ] Offline message delivery
- [ ] Contact verification flow

**Success Criteria**: 50+ integration tests, critical paths verified

---

### Phase 4: Coverage Completeness (Day 5) 📊 POLISH

**Goal**: Fill gaps, test edge cases, achieve >80% coverage

#### 4.1 Widget Tests (Critical UI)

**File**: `test/widgets/chat_screen_test.dart` (NEW)
```dart
testWidgets('ChatScreen displays messages correctly', (tester) async {
  final mockMessages = [
    Message(id: 'msg1', content: 'Hello', isFromMe: true, timestamp: DateTime.now()),
    Message(id: 'msg2', content: 'Hi there', isFromMe: false, timestamp: DateTime.now()),
  ];

  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(chatId: 'test_chat', messages: mockMessages),
    ),
  );

  expect(find.text('Hello'), findsOneWidget);
  expect(find.text('Hi there'), findsOneWidget);
  expect(find.byType(ModernMessageBubble), findsNWidgets(2));
});

testWidgets('ChatScreen sends message on submit', (tester) async {
  bool messageSent = false;

  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        chatId: 'test_chat',
        onSendMessage: (content) {
          messageSent = true;
          expect(content, equals('Test message'));
        },
      ),
    ),
  );

  await tester.enterText(find.byType(TextField), 'Test message');
  await tester.tap(find.byIcon(Icons.send));
  await tester.pump();

  expect(messageSent, isTrue);
});
```

**Widget Test Coverage**:
- [ ] ChatScreen (message display, input, send)
- [ ] ArchiveScreen (list, search, restore)
- [ ] ContactListScreen (display, filter, select)
- [ ] ModernMessageBubble (rendering, interactions)
- [ ] ArchivedChatTile (display, context menu)

#### 4.2 Edge Cases & Error Paths

```dart
group('Edge Cases', () {
  test('should handle empty database gracefully', () async {
    final chats = await chatsRepo.getAllChats();
    expect(chats, isEmpty);
    expect(chats, isA<List<Chat>>()); // Not null
  });

  test('should handle malformed message data', () async {
    final result = await messageRepo.saveMessage(
      Message(id: '', content: '', timestamp: null), // Invalid
    );
    expect(result.success, isFalse);
    expect(result.error, contains('validation'));
  });

  test('should handle database corruption gracefully', () async {
    // Corrupt database
    await corruptDatabase();

    final isValid = await DatabaseHelper.verifyIntegrity();
    expect(isValid, isFalse);

    // Should trigger recovery
    await DatabaseHelper.recover();
    final recoveredValid = await DatabaseHelper.verifyIntegrity();
    expect(recoveredValid, isTrue);
  });

  test('should handle concurrent access safely', () async {
    final futures = List.generate(100, (i) =>
      chatsRepo.addMessage('chat1', 'Message $i', isFromMe: true)
    );
    await Future.wait(futures);

    final messages = await chatsRepo.getMessages('chat1');
    expect(messages.length, equals(100));
  });
});
```

#### 4.3 Performance Benchmarks

**File**: `test/performance/benchmarks_test.dart` (NEW)
```dart
test('mesh routing should handle 1000 nodes in <100ms', () async {
  final router = SmartMeshRouter();
  final nodes = generateTestNodes(count: 1000);

  final stopwatch = Stopwatch()..start();
  final route = await router.findOptimalRoute(
    from: nodes.first.id,
    to: nodes.last.id,
    availableNodes: nodes,
  );
  stopwatch.stop();

  expect(route, isNotNull);
  expect(stopwatch.elapsedMilliseconds, lessThan(100));
});

test('FTS5 search should handle 10000 messages in <50ms', () async {
  // Insert 10000 archived messages
  await insertArchivedMessages(count: 10000);

  final stopwatch = Stopwatch()..start();
  final results = await archiveSearchService.search(query: 'test');
  stopwatch.stop();

  expect(stopwatch.elapsedMilliseconds, lessThan(50));
});
```

#### 4.4 Coverage Report Generation

```bash
# Generate coverage report
flutter test --coverage

# Generate HTML report (requires lcov)
genhtml coverage/lcov.info -o coverage/html

# Open in browser
open coverage/html/index.html
```

**Coverage Targets**:
- Core messaging: >90%
- Security: >95%
- Repositories: >85%
- Services: >85%
- UI widgets: >70%
- Overall: >80%

#### Phase 4 Checklist

- [ ] Widget tests (5+ critical screens)
- [ ] Edge case tests (50+ scenarios)
- [ ] Error handling tests (30+ scenarios)
- [ ] Performance benchmarks (10+ tests)
- [ ] Coverage report generated
- [ ] Coverage targets met

**Success Criteria**: >80% overall coverage, all critical paths >90%

---

## Testing Patterns & Best Practices

### ✅ DO: Test Patterns

#### 1. Use Descriptive Test Names
```dart
// ✅ GOOD: Clear, specific, describes expected behavior
test('should queue message for offline recipient and deliver when online', () {});

// ❌ BAD: Vague, doesn't explain what or why
test('test message queue', () {});
```

#### 2. One Assertion Per Concept
```dart
// ✅ GOOD: Multiple related assertions for one concept
test('should create valid chat with all required fields', () {
  final chat = await chatsRepo.createChat('chat1', 'User');

  expect(chat.chatId, equals('chat1'));
  expect(chat.contactName, equals('User'));
  expect(chat.createdAt, isNotNull);
  expect(chat.lastMessageAt, isNotNull);
});

// ❌ BAD: Testing multiple unrelated concepts
test('chat operations', () {
  final chat = await chatsRepo.createChat('chat1', 'User');
  expect(chat.chatId, equals('chat1'));

  await chatsRepo.deleteChat('chat1'); // Different concept
  expect(await chatsRepo.getChat('chat1'), isNull);
});
```

#### 3. Test Both Happy and Sad Paths
```dart
group('deleteChat', () {
  test('should delete existing chat successfully', () {
    // Happy path
  });

  test('should return error when deleting non-existent chat', () {
    // Sad path
  });

  test('should cascade delete all messages', () {
    // Happy path with side effects
  });
});
```

#### 4. Use Test Factories for Complex Objects
```dart
// test/test_helpers/factories.dart
class TestFactories {
  static Message createMessage({
    String? id,
    String? content,
    bool isFromMe = true,
    DateTime? timestamp,
  }) {
    return Message(
      id: id ?? 'msg_${DateTime.now().millisecondsSinceEpoch}',
      content: content ?? 'Test message',
      isFromMe: isFromMe,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  static Chat createChat({
    String? chatId,
    String? contactName,
  }) {
    return Chat(
      chatId: chatId ?? 'chat_${DateTime.now().millisecondsSinceEpoch}',
      contactName: contactName ?? 'Test User',
      createdAt: DateTime.now(),
      lastMessageAt: DateTime.now(),
    );
  }
}

// Usage in tests
test('example', () {
  final message = TestFactories.createMessage(content: 'Custom content');
  // ...
});
```

#### 5. Mock External Dependencies, Test Real Logic
```dart
// ✅ GOOD: Mock BLE, test business logic
test('should queue message when BLE unavailable', () async {
  final mockBLE = MockBLEService();
  when(mockBLE.isConnected()).thenReturn(false);

  final service = MessagingService(bleService: mockBLE);
  await service.sendMessage('Hello');

  verify(mockBLE.queueForLater(any)).called(1);
});

// ❌ BAD: Mocking the logic you're trying to test
test('should send message', () async {
  final mockService = MockMessagingService();
  when(mockService.sendMessage(any)).thenReturn(true);

  final result = await mockService.sendMessage('Hello');
  expect(result, isTrue); // ❌ You're testing the mock!
});
```

### ❌ DON'T: Anti-Patterns

#### 1. Don't Test Implementation Details
```dart
// ❌ BAD: Testing private method implementation
test('_calculateHash should use SHA256', () {
  // Don't test HOW it works
});

// ✅ GOOD: Test public contract and behavior
test('calculateQueueHash should return consistent hash for same queue', () {
  // Test WHAT it does
});
```

#### 2. Don't Share State Between Tests
```dart
// ❌ BAD: Shared mutable state
late List<Message> messages;
setUpAll(() {
  messages = []; // ❌ Shared across tests
});

test('test 1', () {
  messages.add(TestFactories.createMessage());
  expect(messages.length, equals(1)); // ❌ May be 2 if test 2 ran first
});

// ✅ GOOD: Isolated state
setUp(() {
  // Fresh state for each test
});
```

#### 3. Don't Use Real Timers
```dart
// ❌ BAD: Slow, flaky tests
test('should expire after 60 seconds', () async {
  final service = MyService();
  await Future.delayed(Duration(seconds: 60)); // ❌ Slow!
  expect(service.isExpired, isTrue);
});

// ✅ GOOD: Mock time
test('should expire after TTL', () async {
  final clock = Clock.fixed(DateTime(2024, 1, 1));
  final service = MyService(clock: clock);

  clock.advance(Duration(seconds: 60));
  expect(service.isExpired, isTrue);
});
```

#### 4. Don't Test Third-Party Libraries
```dart
// ❌ BAD: Testing Flutter/Dart SDK
test('List.add should add item', () {
  final list = <int>[];
  list.add(1);
  expect(list.length, equals(1)); // ❌ Testing Dart SDK
});

// ✅ GOOD: Test your logic that uses libraries
test('ChatRepository.addMessage should persist to database', () {
  // Test YOUR code, not SQLite
});
```

---

## Quality Gates & Success Criteria

### Definition of Done for Each Phase

#### Phase 1: Foundation
- [ ] All existing tests pass (270/270)
- [ ] No test timeouts or hangs
- [ ] Standard test setup documented
- [ ] All tests use proper isolation

#### Phase 2: Business Logic
- [ ] 200+ new unit tests written
- [ ] All critical services have >80% coverage
- [ ] All repositories have comprehensive tests
- [ ] Documentation updated with examples

#### Phase 3: Integration
- [ ] 50+ integration tests written
- [ ] All critical paths verified end-to-end
- [ ] Database migrations tested
- [ ] Security flows validated

#### Phase 4: Completeness
- [ ] >80% overall code coverage
- [ ] >90% coverage on critical paths
- [ ] Widget tests for main screens
- [ ] Performance benchmarks established
- [ ] Edge cases covered

### Overall Success Criteria

**Quantitative**:
- ✅ 100% test pass rate (0 failures)
- ✅ >80% code coverage overall
- ✅ >90% coverage on core/security/messaging
- ✅ 400+ total tests
- ✅ <5 minute total test suite runtime

**Qualitative**:
- ✅ Every major service has comprehensive tests
- ✅ Every critical path has integration test
- ✅ Edge cases and error paths covered
- ✅ Tests serve as living documentation
- ✅ New developers can understand app from tests

---

## Progress Tracking

### Daily Standup Template

**Day X - Date: ____**

**Completed**:
- [ ] Task 1
- [ ] Task 2

**In Progress**:
- [ ] Task 3

**Blockers**:
- None / Description

**Coverage**: ___% (target: 80%+)
**Pass Rate**: ___% (target: 100%)

---

### Weekly Summary

**Week 1 (5 Days)**

| Phase | Target | Actual | Status |
|-------|--------|--------|--------|
| Phase 1: Foundation | 100% pass | __% | 🟡 |
| Phase 2: Business Logic | 200 tests | __ | 🟡 |
| Phase 3: Integration | 50 tests | __ | 🟡 |
| Phase 4: Completeness | 80% cov | __% | 🟡 |

**Overall Progress**: ___/400 tests | ___% coverage

---

## Common Issues & Solutions

### Issue: "MissingPluginException" in Tests

**Solution**: Add to `setUpAll()`:
```dart
TestWidgetsFlutterBinding.ensureInitialized();
SharedPreferences.setMockInitialValues({});
```

### Issue: "Database is locked"

**Solution**: Ensure proper cleanup:
```dart
tearDown(() async {
  await DatabaseHelper.close();
});
```

### Issue: "Bad state: Cannot fire new event"

**Solution**: Remove recursive logger:
```dart
// Remove:
Logger.root.onRecord.listen((record) => testLogger.info(...));

// Use:
Logger.root.level = Level.WARNING;
```

### Issue: Tests are slow

**Solution**:
- Use `flutter test --no-pub` to skip dependency resolution
- Run specific test files: `flutter test test/my_test.dart`
- Use test tags: `flutter test --tags=fast`

### Issue: Flaky tests (pass sometimes, fail sometimes)

**Solution**:
- Remove shared state between tests
- Mock time instead of using delays
- Ensure proper async handling with `await`
- Clean database between tests

---

## Resources & References

### Flutter Testing Documentation
- [Official Testing Guide](https://docs.flutter.dev/testing)
- [Widget Testing](https://docs.flutter.dev/cookbook/testing/widget/introduction)
- [Integration Testing](https://docs.flutter.dev/testing/integration-tests)

### Testing Best Practices
- [Test-Driven Development (TDD)](https://en.wikipedia.org/wiki/Test-driven_development)
- [AAA Pattern](https://medium.com/@pjbgf/title-testing-code-ocd-and-the-aaa-pattern-df453975ab80)
- [Test Doubles (Mocks, Stubs, Fakes)](https://martinfowler.com/articles/mocksArentStubs.html)

### pak_connect Specific
- `CLAUDE.md` - Project overview and architecture
- `lib/*/` - Production code to be tested
- `test/` - Existing test suite

---

## Final Checklist: Test Suite Complete ✅

**Foundation**:
- [ ] All 270 existing tests passing
- [ ] Test infrastructure standardized
- [ ] Documentation complete

**Coverage**:
- [ ] Core/messaging: >90%
- [ ] Security: >95%
- [ ] Data layer: >85%
- [ ] Domain layer: >85%
- [ ] Overall: >80%

**Quality**:
- [ ] No flaky tests
- [ ] No test pollution (isolation verified)
- [ ] Fast execution (<5 min total)
- [ ] Comprehensive edge cases

**Deliverables**:
- [ ] 400+ tests written
- [ ] Coverage report generated
- [ ] Test helpers/factories created
- [ ] Documentation updated
- [ ] CI/CD ready

---

**Status**: Ready to begin Phase 1
**Next Action**: Fix logger conflicts in existing test suite
**Estimated Completion**: 5 days from start

---

*This is a living document. Update progress daily and adjust strategy as needed.*

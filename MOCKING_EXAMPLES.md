# CONCRETE EXAMPLES: Mocking AppCore Dependencies

## Example 1: Basic Unit Test with Mocked Repositories

``dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/di/service_locator.dart';
import 'package:pak_connect/test_helpers/test_setup.dart';
import 'package:pak_connect/test_helpers/mocks/mock_contact_repository.dart';
import 'package:pak_connect/test_helpers/mocks/mock_message_repository.dart';

void main() {
  group('MyService', () {
    late MyService service;
    late MockContactRepository mockContacts;
    late MockMessageRepository mockMessages;

    setUp(() async {
      mockContacts = MockContactRepository();
      mockMessages = MockMessageRepository();
      
      // Initialize test environment with mocks
      await TestSetup.initializeTestEnvironment(
        dbLabel: 'my_service_test',
        configureDiWithMocks: true,
        contactRepository: mockContacts,
        messageRepository: mockMessages,
      );

      // Now get the service (it will use mocked repos from DI)
      service = MyService(
        repositoryProvider: getIt.get<IRepositoryProvider>(),
      );
    });

    test('saves contact and retrieves it', () async {
      // Arrange
      await mockContacts.saveContact('pubkey123', 'Alice');

      // Act
      final result = await mockContacts.getContact('pubkey123');

      // Assert
      expect(result?.displayName, equals('Alice'));
    });

    test('service uses injected repository', () async {
      // Arrange
      await mockContacts.saveContact('pubkey456', 'Bob');

      // Act
      final result = await service.getContactName('pubkey456');

      // Assert
      expect(result, equals('Bob'));
    });
  });
}
``

---

## Example 2: Testing Offline Queue

``dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/messaging/offline_queue_facade.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  group('OfflineQueueFacade', () {
    late OfflineQueueFacade facade;
    late List<QueuedMessage> queuedMessages;

    setUp(() {
      queuedMessages = [];
      // Create in-memory queue - NO DI NEEDED
      final inMemoryQueue = InMemoryOfflineMessageQueue();
      facade = OfflineQueueFacade(queue: inMemoryQueue);
    });

    test('queues message and fires callback', () async {
      // Arrange
      facade.onMessageQueued = (msg) {
        queuedMessages.add(msg);
      };

      await facade.initialize();

      // Act
      final msgId = await facade.queueMessage(
        chatId: 'chat-123',
        content: 'Hello',
        recipientPublicKey: 'bob-key',
        senderPublicKey: 'alice-key',
        priority: MessagePriority.normal,
      );

      // Assert
      expect(queuedMessages, hasLength(1));
      expect(queuedMessages[0].id, equals(msgId));
      expect(queuedMessages[0].content, equals('Hello'));
    });
  });
}
``

---

## Example 3: Testing BLE Communication with Mocked Connection

``dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/test_helpers/test_setup.dart';
import 'package:pak_connect/test_helpers/mocks/mock_connection_service.dart';

void main() {
  group('BLE Communication', () {
    late MockConnectionService mockConnection;
    late MyBleHandler bleHandler;

    setUp(() async {
      mockConnection = MockConnectionService();
      
      await TestSetup.initializeTestEnvironment(
        dbLabel: 'ble_test',
        configureDiWithMocks: true,
        connectionService: mockConnection,
      );

      bleHandler = MyBleHandler(
        connectionService: getIt.get<IConnectionService>(),
      );
    });

    test('processes incoming message from peer', () async {
      // Arrange
      final receivedMessages = <String>[];
      bleHandler.onMessageReceived = (msg) {
        receivedMessages.add(msg);
      };

      final jsonPayload = jsonEncode({
        'type': 'chat_message',
        'content': 'Hello from peer',
      });

      // Act
      mockConnection.emitIncomingMessage(jsonPayload);
      await Future.delayed(Duration(milliseconds: 100));

      // Assert
      expect(receivedMessages, contains(jsonPayload));
    });

    test('sends message to peer', () async {
      // Act
      await bleHandler.sendMessage('Hello peer');

      // Assert
      expect(mockConnection.sentMessages, hasLength(1));
      expect(mockConnection.sentMessages[0]['content'], equals('Hello peer'));
    });

    test('handles device discovery', () async {
      // Arrange
      final discoveredDevices = <Peripheral>[];
      bleHandler.onDevicesDiscovered = (devices) {
        discoveredDevices.addAll(devices);
      };

      final fakePeripherals = [
        // Create fake peripheral devices
      ];

      // Act
      mockConnection.emitDiscoveredDevices(fakePeripherals);
      await Future.delayed(Duration(milliseconds: 100));

      // Assert
      expect(discoveredDevices, hasLength(greaterThan(0)));
    });
  });
}
``

---

## Example 4: Testing Performance Monitor (Standalone)

``dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/performance_monitor.dart';

void main() {
  group('PerformanceMonitor', () {
    late PerformanceMonitor monitor;

    setUp(() async {
      monitor = PerformanceMonitor();
      await monitor.initialize();
    });

    test('tracks operation timing', () async {
      // Arrange
      monitor.startMonitoring();
      
      // Act
      monitor.startOperation('slow_operation');
      await Future.delayed(Duration(milliseconds: 100));
      monitor.endOperation('slow_operation', success: true);

      // Assert
      final stats = monitor.getOperationStats();
      expect(stats['slow_operation'], isNotNull);
      expect(stats['slow_operation'].isNotEmpty, isTrue);
    });

    test('counts successful and failed operations', () async {
      // Arrange
      monitor.startMonitoring();

      // Act
      monitor.startOperation('op1');
      monitor.endOperation('op1', success: true);
      
      monitor.startOperation('op2');
      monitor.endOperation('op2', success: false);

      // Assert
      final stats = monitor.getStatistics();
      expect(stats.totalOperations, equals(2));
      expect(stats.successfulOperations, equals(1));
      expect(stats.failedOperations, equals(1));
    });
  });
}
``

---

## Example 5: Testing Battery Optimizer (Standalone)

``dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/battery_optimizer.dart';

void main() {
  group('BatteryOptimizer', () {
    late BatteryOptimizer optimizer;
    late List<BatteryPowerMode> powerModes;

    setUpAll(() {
      // IMPORTANT: Disable native plugin calls in test
      BatteryOptimizer.disableForTests();
    });

    setUp(() async {
      powerModes = [];
      optimizer = BatteryOptimizer();
      
      optimizer.onPowerModeChanged = (mode) {
        powerModes.add(mode);
      };

      await optimizer.initialize();
    });

    tearDownAll(() {
      BatteryOptimizer.enableForRuntime();
    });

    test('tracks battery info', () async {
      // Arrange
      final info = optimizer.getCurrentInfo();

      // Assert
      expect(info.level, isA<int>());
      expect(info.powerMode, isNotNull);
    });

    test('callbacks disabled in test mode', () {
      // In test mode, native calls are skipped
      expect(optimizer.isEnabled, isFalse);
    });
  });
}
``

---

## Example 6: Creating Custom Mock with Hand-Written Fake

``dart
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';

/// Simple in-memory mock for testing
class TestMessageRepository implements IMessageRepository {
  final Map<String, Message> _messages = {};
  
  // Call tracking for verification
  int saveCallCount = 0;
  int getCallCount = 0;

  @override
  Future<void> saveMessage(Message message) async {
    saveCallCount++;
    _messages[message.id.value] = message;
  }

  @override
  Future<List<Message>> getMessages(ChatId chatId) async {
    getCallCount++;
    return _messages.values
        .where((m) => m.chatId == chatId)
        .toList();
  }

  @override
  Future<Message?> getMessageById(MessageId messageId) async {
    return _messages[messageId.value];
  }

  // ... other interface methods

  // Test helper methods
  void reset() {
    _messages.clear();
    saveCallCount = 0;
    getCallCount = 0;
  }

  Message? getLastSavedMessage() {
    return _messages.values.lastOrNull;
  }
}

// Usage in test:
test('saves messages', () async {
  final repo = TestMessageRepository();
  await repo.saveMessage(message1);
  await repo.saveMessage(message2);
  
  expect(repo.saveCallCount, equals(2));
  expect(repo.getLastSavedMessage().id, equals(message2.id));
});
``

---

## Example 7: Using Repository Provider

``dart
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/di/service_locator.dart';

void main() {
  group('MyService with RepositoryProvider', () {
    late MyService service;

    setUp(() async {
      await TestSetup.initializeTestEnvironment(
        dbLabel: 'repo_provider_test',
        configureDiWithMocks: true,
      );

      // Get the repository provider from DI
      final provider = getIt.get<IRepositoryProvider>();

      service = MyService(repositoryProvider: provider);
    });

    test('accesses both repositories through provider', () async {
      // Arrange
      final provider = getIt.get<IRepositoryProvider>();

      // Act
      await provider.contactRepository.saveContact('key1', 'Alice');
      await provider.messageRepository.saveMessage(message1);

      // Assert
      final contact = await provider.contactRepository.getContact('key1');
      expect(contact?.displayName, equals('Alice'));
    });
  });
}
``

---

## Example 8: Full Integration Test

``dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/app_core.dart';
import 'package:pak_connect/test_helpers/test_setup.dart';
import 'package:pak_connect/test_helpers/mocks/mock_connection_service.dart';

void main() {
  group('AppCore Integration', () {
    late MockConnectionService mockConnection;

    setUp(() async {
      mockConnection = MockConnectionService();
      
      await TestSetup.initializeTestEnvironment(
        dbLabel: 'integration_test',
        configureDiWithMocks: true,
        connectionService: mockConnection,
      );
    });

    test('app initializes with mocked dependencies', () async {
      // Arrange & Act
      await AppCore.initialize();

      // Assert
      expect(getIt.isRegistered<IRepositoryProvider>(), isTrue);
      expect(getIt.isRegistered<IConnectionService>(), isTrue);
      expect(getIt.isRegistered<IMeshNetworkingService>(), isTrue);
      
      // Verify we're using the mock
      final connService = getIt.get<IConnectionService>();
      expect(connService, equals(mockConnection));
    });

    test('offline queue is available', () async {
      // Arrange
      await AppCore.initialize();

      // Act
      final queue = getIt.get<OfflineQueueFacade>();

      // Assert
      expect(queue, isNotNull);
    });
  });
}
``


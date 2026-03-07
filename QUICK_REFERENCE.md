# QUICK REFERENCE: AppCore Dependency Injection & Mocking

## Critical DI Flow for Tests

### Step 1: Initialize Test Environment
``dart
setUp(() async {
  await TestSetup.initializeTestEnvironment(
    dbLabel: 'my_test',
    configureDiWithMocks: true,
    contactRepository: mockContactRepo, // optional, uses default if null
    connectionService: mockConnectionService,
  );
});
``

### Step 2: What This Does
1. Resets GetIt service locator
2. Calls configureDataLayerRegistrar(registerDataLayerServices)
3. Calls setupServiceLocator() - registers all core interfaces
4. Registers mock repositories (or defaults if not provided)
5. Initializes test database with mock storage

---

## The 4 Core Services You Need to Mock

### 1. IContactRepository
Mock: MockContactRepository (extends ContactRepository)

### 2. IMessageRepository
Mock: MockMessageRepository (extends MessageRepository)

### 3. IConnectionService
Mock: MockConnectionService (implements IConnectionService)

### 4. ISeenMessageStore
Mock: TestSeenMessageStore or default SeenMessageStore

---

## Mocking Strategy Summary

### PREFERRED: Hand-Written Fakes
- Location: test/test_helpers/mocks/
- Examples: MockContactRepository, MockConnectionService
- Advantages: Simple, readable, no code generation

### ALTERNATIVE: Mockito
- Already in pubspec.yaml: mockito: ^5.4.4
- Use when: Complex argument matching needed
- Pattern: @GenerateNiceMocks, when(), verify()

---

## Offline Queue Components - NO DI REQUIRED

OfflineQueueFacade and OfflineMessageQueue work standalone:

``dart
final queue = OfflineQueueFacade();
await queue.initialize(
  onMessageQueued: (msg) => print('Queued'),
);
``

Can optionally inject repositories:
``dart
final queue = OfflineQueueFacade(
  queue: OfflineMessageQueue(
    queueRepository: myRepository,
    queuePersistenceManager: myPersistenceManager,
  ),
);
``

---

## PerformanceMonitor & BatteryOptimizer - NO DI NEEDED

Both are standalone services:

``dart
// PerformanceMonitor
final monitor = PerformanceMonitor();
await monitor.initialize();
monitor.startMonitoring();

// BatteryOptimizer
BatteryOptimizer.disableForTests(); // Call in setUp
final optimizer = BatteryOptimizer();
await optimizer.initialize();
``

---

## QueuedMessage Fields

Constructor parameters:
- id, chatId, content
- recipientPublicKey, senderPublicKey
- priority (MessagePriority - mutable!)
- queuedAt, maxRetries
- status (QueuedMessageStatus - mutable!)
- attempts (int - mutable!)
- Relay-specific: isRelayMessage, relayMetadata, originalMessageId, relayNodeId, messageHash

TTL auto-calculated: urgent=24h, high=12h, normal=6h, low=3h

---

## EnhancedMessage & MessageStatus

MessageStatus enum:
- sending, sent, delivered, failed, read

EnhancedMessage adds:
- replyToMessageId, threadId, metadata
- deliveryReceipt, readReceipt
- reactions, isStarred, isForwarded, priority
- editedAt, originalContent, attachments
- encryptionInfo

---

## Key getIt Interfaces

- IRepositoryProvider - unified repo access
- IContactRepository, IMessageRepository - data
- IConnectionService - BLE comms
- ISharedMessageQueueProvider - offline queue
- IBLEServiceFacade - BLE interface
- IMeshNetworkingService - mesh routing
- IDatabaseProvider - database access


import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/services/message_router.dart';
import 'package:pak_connect/domain/services/message_security.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/chat_session_lifecycle.dart';
import 'package:pak_connect/presentation/models/chat_ui_state.dart';
import 'package:pak_connect/presentation/viewmodels/chat_session_view_model.dart';

import '../../helpers/ble/ble_fakes.dart';
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';
import '../../test_helpers/mocks/mock_connection_service.dart';

class _MockViewModel extends Mock implements ChatSessionViewModel {}

class _MockMessageSecurity extends Mock implements MessageSecurity {}

class _MockMessageRepository extends Mock implements IMessageRepository {}

class _MockMessageRouter extends Mock implements MessageRouter {
  @override
  Future<MessageRouteResult> sendMessage({
    required String content,
    required String recipientId,
    String? messageId,
    String? recipientName,
  }) => super.noSuchMethod(
    Invocation.method(#sendMessage, [], {
      #content: content,
      #recipientId: recipientId,
      #messageId: messageId,
      #recipientName: recipientName,
    }),
    returnValue: Future<MessageRouteResult>.value(
      MessageRouteResult.failed(messageId ?? 'mock-id', 'not-stubbed'),
    ),
    returnValueForMissingStub: Future<MessageRouteResult>.value(
      MessageRouteResult.failed(messageId ?? 'mock-id', 'not-stubbed'),
    ),
  ) as Future<MessageRouteResult>;
}

class _ConfigurableConnectionService extends MockConnectionService {
  bool nextSendMessageResult = true;
  bool nextSendPeripheralMessageResult = true;
  bool startMonitoringCalled = false;
  Peripheral? scanResult;
  Object? scanError;
  Object? connectError;
  Peripheral? forcedConnectedDevice;

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    sentMessages.add({
      'content': message,
      'messageId': messageId,
      'recipient': originalIntendedRecipient,
    });
    return nextSendMessageResult;
  }

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async {
    sentPeripheralMessages.add({'content': message, 'messageId': messageId});
    return nextSendPeripheralMessageResult;
  }

  @override
  void startConnectionMonitoring() {
    startMonitoringCalled = true;
  }

  @override
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) async {
    if (scanError != null) {
      throw scanError!;
    }
    return scanResult;
  }

  @override
  Future<void> connectToDevice(Peripheral device) async {
    if (connectError != null) {
      throw connectError!;
    }
    await super.connectToDevice(device);
    forcedConnectedDevice = device;
  }

  @override
  Peripheral? get connectedDevice => forcedConnectedDevice ?? super.connectedDevice;
}

class _FakeMeshService implements IMeshNetworkingService {
  final StreamController<MeshNetworkStatus> statusController =
      StreamController<MeshNetworkStatus>.broadcast();
  final StreamController<String> deliveryController =
      StreamController<String>.broadcast();

  MeshSendResult nextSendResult = MeshSendResult.direct('mesh-direct');
  final List<QueuedMessage> queuedMessages = <QueuedMessage>[];
  int refreshCount = 0;

  @override
  Future<void> dispose() async {
    await statusController.close();
    await deliveryController.close();
  }

  @override
  Future<void> initialize({String? nodeId}) async {}

  @override
  Stream<MeshNetworkStatus> get meshStatus => statusController.stream;

  @override
  Stream<RelayStatistics> get relayStats => const Stream.empty();

  @override
  Stream<QueueSyncManagerStats> get queueStats => const Stream.empty();

  @override
  Stream<String> get messageDeliveryStream => deliveryController.stream;

  @override
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    return nextSendResult;
  }

  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async =>
      <String, QueueSyncResult>{};

  @override
  Future<bool> retryMessage(String messageId) async => true;

  @override
  Future<bool> removeMessage(String messageId) async => true;

  @override
  Future<bool> setPriority(String messageId, MessagePriority priority) async =>
      true;

  @override
  Future<int> retryAllMessages() async => 0;

  @override
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) =>
      queuedMessages.where((m) => m.chatId == chatId).toList();

  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream => const Stream.empty();

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = BinaryPayloadType.media,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  }) async => 'transfer-$recipientId';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async => true;

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => const [];

  @override
  MeshNetworkStatistics getNetworkStatistics() => const MeshNetworkStatistics(
    nodeId: 'node',
    isInitialized: true,
    relayStatistics: null,
    queueStatistics: null,
    syncStatistics: null,
    spamStatistics: null,
    spamPreventionActive: false,
    queueSyncActive: false,
  );

  @override
  void refreshMeshStatus() {
    refreshCount++;
  }
}

class _ThrowingQueue extends InMemoryOfflineMessageQueue {
  @override
  List<QueuedMessage> getPendingMessages() {
    throw StateError('queue access failed');
  }
}

MeshNetworkStatus _readyStatus({bool isInitialized = true}) => MeshNetworkStatus(
  isInitialized: isInitialized,
  currentNodeId: 'node-a',
  isConnected: true,
  statistics: const MeshNetworkStatistics(
    nodeId: 'node-a',
    isInitialized: true,
    relayStatistics: null,
    queueStatistics: null,
    syncStatistics: null,
    spamStatistics: null,
    spamPreventionActive: false,
    queueSyncActive: false,
  ),
  queueMessages: const <QueuedMessage>[],
);

Message _message(String id, {String content = 'hello'}) => Message(
  id: MessageId(id),
  chatId: const ChatId('chat-a'),
  content: content,
  timestamp: DateTime.fromMillisecondsSinceEpoch(1),
  isFromMe: true,
  status: MessageStatus.sending,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatSessionLifecycle', () {
    late _ConfigurableConnectionService connectionService;
    late _FakeMeshService meshService;
    late _MockViewModel viewModel;
    late _MockMessageSecurity messageSecurity;
    late _MockMessageRepository messageRepository;
    late InMemoryOfflineMessageQueue offlineQueue;
    late ChatSessionLifecycle lifecycle;

    setUp(() async {
      Logger.root.level = Level.OFF;
      connectionService = _ConfigurableConnectionService();
      meshService = _FakeMeshService();
      viewModel = _MockViewModel();
      messageSecurity = _MockMessageSecurity();
      messageRepository = _MockMessageRepository();
      offlineQueue = InMemoryOfflineMessageQueue();
      await offlineQueue.initialize();

      lifecycle = ChatSessionLifecycle(
        viewModel: viewModel,
        connectionService: connectionService,
        meshService: meshService,
        messageSecurity: messageSecurity,
        messageRepository: messageRepository,
        offlineQueue: offlineQueue,
        logger: Logger('ChatSessionLifecycleTest'),
      );
    });

    tearDown(() async {
      lifecycle.dispose();
      await meshService.dispose();
      await connectionService.dispose();
    });

    test('setupDeliveryListener forwards mesh delivery IDs', () async {
      MessageId? delivered;
      lifecycle.setupDeliveryListener(onDelivered: (id) => delivered = id);

      meshService.deliveryController.add('msg-123');
      await Future<void>.delayed(Duration.zero);

      expect(delivered, const MessageId('msg-123'));
    });

    test('activateMessageListener buffers stream events once', () async {
      final controller = StreamController<String>.broadcast();
      lifecycle.activateMessageListener(controller.stream);
      lifecycle.activateMessageListener(controller.stream);

      controller.add('one');
      await Future<void>.delayed(Duration.zero);

      expect(lifecycle.messageBuffer, ['one']);
      await controller.close();
    });

    test('attachMessageStream dispatches live events and buffers disposed events', () async {
      final stream = StreamController<String>.broadcast();
      final handled = <String>[];
      var disposed = false;

      lifecycle.attachMessageStream(
        stream: stream.stream,
        disposed: () => disposed,
        isActive: () => true,
        onMessage: (content) async => handled.add(content),
      );

      stream.add('live');
      await Future<void>.delayed(Duration.zero);
      disposed = true;
      stream.add('buffered');
      await Future<void>.delayed(Duration.zero);

      expect(handled, ['live']);
      expect(lifecycle.messageBuffer, ['buffered']);
      await stream.close();
    });

    test('processBufferedMessages flushes and clears buffer in order', () async {
      lifecycle.messageBuffer.addAll(['a', 'b']);
      final processed = <String>[];

      await lifecycle.processBufferedMessages((content) async {
        processed.add(content);
      });

      expect(processed, ['a', 'b']);
      expect(lifecycle.messageBuffer, isEmpty);
    });

    test('handleMeshStatus updates state for data/loading/error branches', () {
      ChatUIState current = const ChatUIState(meshInitializing: true);
      final successMessages = <String>[];
      final warningMessages = <String>[];

      lifecycle.handleMeshStatus(
        statusAsync: AsyncValue.data(_readyStatus(isInitialized: true)),
        isCurrentlyInitializing: true,
        updateState: (updater) => current = updater(current),
        onSuccessMessage: successMessages.add,
        onWarningMessage: warningMessages.add,
      );
      expect(current.meshInitializing, isFalse);
      expect(current.initializationStatus, 'Ready');
      expect(successMessages, ['Mesh networking ready']);

      lifecycle.handleMeshStatus(
        statusAsync: AsyncValue.loading(),
        isCurrentlyInitializing: false,
        updateState: (updater) => current = updater(current),
        onSuccessMessage: successMessages.add,
      );
      expect(current.meshInitializing, isTrue);
      expect(current.initializationStatus, 'Initializing mesh network...');

      lifecycle.handleMeshStatus(
        statusAsync: AsyncValue.error('boom', StackTrace.current),
        isCurrentlyInitializing: true,
        updateState: (updater) => current = updater(current),
        onSuccessMessage: successMessages.add,
        onWarningMessage: warningMessages.add,
      );
      expect(current.meshInitializing, isFalse);
      expect(current.initializationStatus, 'Initialization failed');
      expect(warningMessages.last, contains('Mesh status error'));
    });

    test('startInitializationTimeout flips state after delay', () {
      ChatUIState current = const ChatUIState(meshInitializing: true);
      final success = <String>[];

      fakeAsync((async) {
        lifecycle.startInitializationTimeout(
          isCheckingStatus: true,
          disposed: () => false,
          stillInitializing: () => current.meshInitializing,
          updateState: (updater) => current = updater(current),
          onSuccessMessage: success.add,
        );

        async.elapse(const Duration(seconds: 4));
      });

      expect(current.meshInitializing, isFalse);
      expect(current.initializationStatus, 'Ready (timeout fallback)');
      expect(success, ['Mesh networking ready (fallback mode)']);
    });

    test('scheduleAutoRetry respects disposal flag', () {
      var retries = 0;
      fakeAsync((async) {
        lifecycle.scheduleAutoRetry(
          delay: const Duration(seconds: 1),
          disposed: () => false,
          onRetry: () async => retries++,
        );
        async.elapse(const Duration(seconds: 1));
      });
      expect(retries, 1);

      fakeAsync((async) {
        lifecycle.scheduleAutoRetry(
          delay: const Duration(seconds: 1),
          disposed: () => true,
          onRetry: () async => retries++,
        );
        async.elapse(const Duration(seconds: 1));
      });
      expect(retries, 1);
    });

    test('hasMessagesQueuedForRelay and getQueuedMessagesForChat use queue', () async {
      expect(lifecycle.hasMessagesQueuedForRelay(null), isFalse);
      expect(lifecycle.hasMessagesQueuedForRelay('peer-a'), isFalse);

      offlineQueue.setOffline();
      await offlineQueue.queueMessage(
        chatId: 'chat-a',
        content: 'queued',
        recipientPublicKey: 'peer-a',
        senderPublicKey: 'me',
      );

      expect(lifecycle.hasMessagesQueuedForRelay('peer-a'), isTrue);
      expect(lifecycle.getQueuedMessagesForChat(), isNotEmpty);
    });

    test('sendRepositoryMessage returns direct success and queued info from router', () async {
      final router = _MockMessageRouter();
      lifecycle = ChatSessionLifecycle(
        viewModel: viewModel,
        connectionService: connectionService,
        meshService: meshService,
        messageRouter: router,
        messageSecurity: messageSecurity,
        messageRepository: messageRepository,
        offlineQueue: offlineQueue,
      );

      when(
        router.sendMessage(
          content: 'hello',
          recipientId: 'peer-a',
          messageId: 'm1',
          recipientName: 'Peer',
        ),
      ).thenAnswer((_) async => MessageRouteResult.sentDirectly('m1'));

      final direct = await lifecycle.sendRepositoryMessage(
        message: _message('m1', content: 'hello'),
        fallbackRecipientId: 'peer-a',
        displayContactName: 'Peer',
        contactPublicKey: 'peer-a',
      );
      expect(direct, isTrue);

      when(
        router.sendMessage(
          content: 'queued',
          recipientId: 'peer-a',
          messageId: 'm2',
          recipientName: 'Peer',
        ),
      ).thenAnswer((_) async => MessageRouteResult.queued('m2'));

      String? info;
      final queued = await lifecycle.sendRepositoryMessage(
        message: _message('m2', content: 'queued'),
        fallbackRecipientId: 'peer-a',
        displayContactName: 'Peer',
        contactPublicKey: null,
        onInfoMessage: (msg) => info = msg,
      );
      expect(queued, isFalse);
      expect(info, contains('queued'));
    });

    test('sendRepositoryMessage falls back to direct/peripheral and mesh send', () async {
      final router = _MockMessageRouter();
      lifecycle = ChatSessionLifecycle(
        viewModel: viewModel,
        connectionService: connectionService,
        meshService: meshService,
        messageRouter: router,
        messageSecurity: messageSecurity,
        messageRepository: messageRepository,
        offlineQueue: offlineQueue,
      );

      when(
        router.sendMessage(
          content: 'direct',
          recipientId: 'peer-a',
          messageId: 'm3',
          recipientName: 'Peer',
        ),
      ).thenAnswer((_) async => MessageRouteResult.failed('m3', 'router fail'));

      connectionService.emitConnectionInfo(
        const ConnectionInfo(isConnected: true, isReady: true, statusMessage: 'ready'),
      );
      connectionService.nextSendMessageResult = true;
      final direct = await lifecycle.sendRepositoryMessage(
        message: _message('m3', content: 'direct'),
        fallbackRecipientId: 'peer-a',
        displayContactName: 'Peer',
        contactPublicKey: 'peer-a',
      );
      expect(direct, isTrue);
      expect(connectionService.sentMessages, isNotEmpty);

      when(
        router.sendMessage(
          content: 'peripheral',
          recipientId: 'peer-b',
          messageId: 'm4',
          recipientName: 'PeerB',
        ),
      ).thenAnswer((_) async => MessageRouteResult.failed('m4', 'router fail'));

      connectionService.isPeripheralMode = true;
      connectionService.nextSendMessageResult = false;
      connectionService.nextSendPeripheralMessageResult = true;
      final peripheral = await lifecycle.sendRepositoryMessage(
        message: _message('m4', content: 'peripheral'),
        fallbackRecipientId: 'peer-b',
        displayContactName: 'PeerB',
        contactPublicKey: 'peer-b',
      );
      expect(peripheral, isTrue);
      expect(connectionService.sentPeripheralMessages, isNotEmpty);

      when(
        router.sendMessage(
          content: 'mesh',
          recipientId: 'peer-c',
          messageId: 'm5',
          recipientName: 'PeerC',
        ),
      ).thenAnswer((_) async => MessageRouteResult.failed('m5', 'router fail'));
      connectionService.nextSendPeripheralMessageResult = false;
      meshService.nextSendResult = MeshSendResult.direct('mesh-ok');

      final mesh = await lifecycle.sendRepositoryMessage(
        message: _message('m5', content: 'mesh'),
        fallbackRecipientId: 'peer-c',
        displayContactName: 'PeerC',
        contactPublicKey: 'peer-c',
      );
      expect(mesh, isTrue);
    });

    test('handleConnectionChange emits lifecycle messages and monitoring behavior', () async {
      final success = <String>[];
      final error = <String>[];
      final info = <String>[];
      var identityRefreshes = 0;

      offlineQueue.setOffline();
      await offlineQueue.queueMessage(
        chatId: 'chat-a',
        content: 'queued',
        recipientPublicKey: 'peer-a',
        senderPublicKey: 'me',
      );

      lifecycle.handleConnectionChange(
        previous: const ConnectionInfo(isConnected: false, isReady: false),
        current: const ConnectionInfo(isConnected: true, isReady: false),
        disposed: () => false,
        onIdentityReceived: () async => identityRefreshes++,
        onSuccessMessage: success.add,
        onErrorMessage: error.add,
        contactPublicKey: 'peer-a',
        onInfoMessage: info.add,
      );
      expect(success.last, contains('Connected'));

      lifecycle.handleConnectionChange(
        previous: const ConnectionInfo(isConnected: true, isReady: false),
        current: const ConnectionInfo(
          isConnected: true,
          isReady: true,
          otherUserName: 'Peer',
        ),
        disposed: () => false,
        onIdentityReceived: () async => identityRefreshes++,
        onSuccessMessage: success.add,
        onErrorMessage: error.add,
        contactPublicKey: 'peer-a',
        onInfoMessage: info.add,
      );
      expect(success.last, contains('Identity exchange complete'));
      expect(identityRefreshes, 1);

      connectionService.isPeripheralMode = false;
      lifecycle.handleConnectionChange(
        previous: const ConnectionInfo(isConnected: true, isReady: true),
        current: const ConnectionInfo(isConnected: false, isReady: false),
        disposed: () => false,
        onIdentityReceived: () async => identityRefreshes++,
        onSuccessMessage: success.add,
        onErrorMessage: error.add,
        contactPublicKey: 'peer-a',
        onInfoMessage: info.add,
      );
      expect(error.last, contains('disconnected'));
      expect(info.last, contains('queued for relay'));

      final emptyQueue = InMemoryOfflineMessageQueue();
      await emptyQueue.initialize();
      lifecycle = ChatSessionLifecycle(
        viewModel: viewModel,
        connectionService: connectionService,
        meshService: meshService,
        messageSecurity: messageSecurity,
        messageRepository: messageRepository,
        offlineQueue: emptyQueue,
      );

      lifecycle.handleConnectionChange(
        previous: const ConnectionInfo(isConnected: true, isReady: true),
        current: const ConnectionInfo(isConnected: false, isReady: false),
        disposed: () => false,
        onIdentityReceived: () async => identityRefreshes++,
        onSuccessMessage: success.add,
        onErrorMessage: error.add,
        contactPublicKey: 'peer-a',
      );
      expect(connectionService.startMonitoringCalled, isTrue);
    });

    test('manualReconnection handles already-connected, found/missing device, and errors', () async {
      final success = <String>[];
      final errors = <String>[];

      connectionService.scanResult = fakePeripheralFromString('00000000-0000-0000-0000-000000000001');
      await connectionService.connectToDevice(connectionService.scanResult!);
      await lifecycle.manualReconnection(
        disposed: () => false,
        onSuccessMessage: success.add,
        onErrorMessage: errors.add,
      );
      expect(success.last, contains('Already connected'));

      await connectionService.disconnect();
      connectionService.forcedConnectedDevice = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000002',
      );
      connectionService.scanResult = connectionService.forcedConnectedDevice;
      await lifecycle.manualReconnection(
        disposed: () => false,
        onSuccessMessage: success.add,
        onErrorMessage: errors.add,
      );
      expect(success.last, contains('Already connected to this device'));

      connectionService.scanResult = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000003',
      );
      connectionService.forcedConnectedDevice = null;
      await lifecycle.manualReconnection(
        disposed: () => false,
        onSuccessMessage: success.add,
        onErrorMessage: errors.add,
      );
      expect(success.last, contains('successful'));

      await connectionService.disconnect();
      connectionService.scanResult = null;
      await lifecycle.manualReconnection(
        disposed: () => false,
        onSuccessMessage: success.add,
        onErrorMessage: errors.add,
      );
      expect(errors.last, contains('not found'));

      connectionService.scanResult = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000004',
      );
      await connectionService.disconnect();
      connectionService.connectError = Exception('1049 already connected');
      await lifecycle.manualReconnection(
        disposed: () => false,
        onSuccessMessage: success.add,
        onErrorMessage: errors.add,
      );
      expect(success.last, contains('Already connected'));

      connectionService.connectError = Exception('transport failure');
      await connectionService.disconnect();
      await lifecycle.manualReconnection(
        disposed: () => false,
        onSuccessMessage: success.add,
        onErrorMessage: errors.add,
      );
      expect(errors.last, contains('transport failure'));
    });

    test('requestPairing validates connection and controller availability', () async {
      String? error;

      await lifecycle.requestPairing(
        connectionInfo: null,
        onErrorMessage: (msg) => error = msg,
      );
      expect(error, contains('Not connected'));

      await lifecycle.requestPairing(
        connectionInfo: const ConnectionInfo(isConnected: false, isReady: false),
        onErrorMessage: (msg) => error = msg,
      );
      expect(error, contains('Not connected'));

      await lifecycle.requestPairing(
        connectionInfo: const ConnectionInfo(isConnected: true, isReady: true),
        onErrorMessage: (msg) => error = msg,
      );
      expect(error, contains('controller not attached'));
    });

    test('resolveOfflineQueue and buildFallbackOfflineQueue provide a usable fallback', () async {
      final fallbackLifecycle = ChatSessionLifecycle(
        viewModel: viewModel,
        connectionService: connectionService,
        meshService: meshService,
        messageSecurity: messageSecurity,
        messageRepository: messageRepository,
        offlineQueue: null,
      );

      final queue = fallbackLifecycle.resolveOfflineQueue();
      expect(queue, isNotNull);

      final initializedQueue = await fallbackLifecycle.buildFallbackOfflineQueue();
      expect(initializedQueue, isA<OfflineMessageQueueContract>());
      fallbackLifecycle.dispose();
    });

    test('hasMessagesQueuedForRelay returns false when queue lookup throws', () {
      final throwingLifecycle = ChatSessionLifecycle(
        viewModel: viewModel,
        connectionService: connectionService,
        meshService: meshService,
        messageSecurity: messageSecurity,
        messageRepository: messageRepository,
        offlineQueue: _ThrowingQueue(),
      );

      expect(throwingLifecycle.hasMessagesQueuedForRelay('peer-z'), isFalse);
      expect(throwingLifecycle.getQueuedMessagesForChat(), isEmpty);
      throwingLifecycle.dispose();
    });

    testWidgets('setupContactRequestHandling shows dialog and executes accept/reject actions', (
      tester,
    ) async {
      var invalidations = 0;
      late BuildContext context;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              lifecycle.setupContactRequestHandling(
                context: context,
                onSecurityStateInvalidate: () => invalidations++,
                mounted: () => true,
              );
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );

      connectionService.emitContactRequest('pk-1', 'Alice');
      await tester.pumpAndSettle();
      expect(find.text('Contact Request'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(invalidations, greaterThanOrEqualTo(1));

      connectionService.emitContactRequest('pk-2', 'Bob');
      await tester.pumpAndSettle();
      expect(find.text('Contact Request'), findsOneWidget);

      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();

      connectionService.emitAsymmetricContact('pk-3', 'Carol');
      await tester.pump();
    });
  });
}

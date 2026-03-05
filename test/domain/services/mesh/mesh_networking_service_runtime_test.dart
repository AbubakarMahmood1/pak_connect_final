import 'dart:async';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/binary_payload.dart';
import 'package:pak_connect/domain/models/bluetooth_state_models.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  group('MeshNetworkingService runtime helper', () {
    test(
      'initialize uses provided node id and falls back to minimal BLE integration when BLE setup fails',
      () async {
        final ble = _FakeRuntimeConnectionService(isBluetoothReadyValue: true);
        final facade = _FakeRuntimeMessageHandlerFacade(
          throwOnInitialize: true,
        );
        final repoProvider = _StubRepositoryProvider();
        final sharedQueueProvider = _FakeSharedQueueProvider(
          initialized: false,
        );

        final service = _buildService(
          ble: ble,
          facade: facade,
          repoProvider: repoProvider,
          sharedQueueProvider: sharedQueueProvider,
        );
        addTearDown(service.dispose);

        await service.initialize(nodeId: 'manual-node');

        final stats = service.getNetworkStatistics();
        expect(stats.isInitialized, isTrue);
        expect(stats.nodeId, 'manual-node');
        expect(facade.initializeCalls, 1);
        expect(sharedQueueProvider.initializeCalls, 1);

        // Idempotent re-entry should no-op.
        await service.initialize(nodeId: 'ignored-node');
        expect(facade.initializeCalls, 1);
      },
    );

    test(
      'initialize falls back to generated node id when BLE ephemeral id is unavailable and schedules initial sync peers',
      () async {
        final ble = _FakeRuntimeConnectionService(
          isBluetoothReadyValue: true,
          currentSessionIdValue: 'peer-session-a',
          getMyEphemeralIdOverride: () async => throw StateError('no id'),
        );
        final facade = _FakeRuntimeMessageHandlerFacade();
        final repoProvider = _StubRepositoryProvider();
        final sharedQueueProvider = _FakeSharedQueueProvider(initialized: true);

        final service = _buildService(
          ble: ble,
          facade: facade,
          repoProvider: repoProvider,
          sharedQueueProvider: sharedQueueProvider,
        );
        addTearDown(service.dispose);

        await service.initialize();

        final stats = service.getNetworkStatistics();
        expect(stats.nodeId, startsWith('fallback_'));
        expect(stats.isInitialized, isTrue);
        expect(facade.initializeCalls, 1);

        ble.emitConnection(
          const ConnectionInfo(
            isConnected: true,
            isReady: true,
            awaitingHandshake: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(service.debugHasInitialSyncScheduled('peer-session-a'), isTrue);

        ble.emitIdentity('peer-identity-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(service.debugHasInitialSyncScheduled('peer-identity-a'), isTrue);
      },
    );

    test('initialize rethrows when core component setup fails', () async {
      final ble = _FakeRuntimeConnectionService(isBluetoothReadyValue: true);
      final facade = _FakeRuntimeMessageHandlerFacade();
      final repoProvider = _StubRepositoryProvider();
      final sharedQueueProvider = _FakeSharedQueueProvider(
        initialized: false,
        throwOnInitialize: true,
      );

      final service = _buildService(
        ble: ble,
        facade: facade,
        repoProvider: repoProvider,
        sharedQueueProvider: sharedQueueProvider,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.initialize(nodeId: 'failing-node'),
        throwsA(isA<StateError>()),
      );
      expect(service.getNetworkStatistics().isInitialized, isFalse);
    });
  });
}

MeshNetworkingService _buildService({
  required _FakeRuntimeConnectionService ble,
  required _FakeRuntimeMessageHandlerFacade facade,
  required _StubRepositoryProvider repoProvider,
  required _FakeSharedQueueProvider sharedQueueProvider,
}) {
  final archiveRepo = _NoopArchiveRepository();
  final archiveManagement = ArchiveManagementService.withDependencies(
    archiveRepository: archiveRepo,
  );
  final archiveSearch = ArchiveSearchService.withDependencies(
    archiveRepository: archiveRepo,
  );

  final chatManagement = ChatManagementService.withDependencies(
    chatsRepository: _NoopChatsRepository(),
    messageRepository: repoProvider.messageRepository,
    archiveRepository: archiveRepo,
    archiveManagementService: archiveManagement,
    archiveSearchService: archiveSearch,
  );

  return MeshNetworkingService(
    bleService: ble,
    messageHandler: facade,
    chatManagementService: chatManagement,
    repositoryProvider: repoProvider,
    sharedQueueProvider: sharedQueueProvider,
    relayEngineFactory: (_, _) => _FakeMeshRelayEngine(),
  );
}

class _FakeRuntimeMessageHandlerFacade implements IBLEMessageHandlerFacade {
  _FakeRuntimeMessageHandlerFacade({this.throwOnInitialize = false});

  final bool throwOnInitialize;
  int initializeCalls = 0;

  @override
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
    List<String> Function()? nextHopsProvider,
  }) async {
    initializeCalls++;
    if (throwOnInitialize) {
      throw StateError('message handler init failure');
    }
  }

  @override
  set onRelayDecisionMade(Function(RelayDecision decision)? callback) {}

  @override
  set onRelayStatsUpdated(Function(RelayStatistics stats)? callback) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRuntimeConnectionService implements IConnectionService {
  _FakeRuntimeConnectionService({
    required this.isBluetoothReadyValue,
    this.currentSessionIdValue = 'peer-default',
    this.getMyEphemeralIdOverride,
  });

  final bool isBluetoothReadyValue;
  String? currentSessionIdValue;
  Future<String> Function()? getMyEphemeralIdOverride;

  bool isConnectedValue = false;
  bool canSendMessagesValue = true;
  bool hasPeripheralConnectionValue = false;
  bool canAcceptMoreConnectionsValue = true;
  int activeConnectionCountValue = 0;
  int maxCentralConnectionsValue = 1;
  List<String> activeConnectionDeviceIdsValue = const <String>[];
  List<BLEServerConnection> serverConnectionsValue =
      const <BLEServerConnection>[];

  int registerQueueSyncHandlerCalls = 0;
  int sendQueueSyncMessageCalls = 0;

  final StreamController<ConnectionInfo> _connectionController =
      StreamController<ConnectionInfo>.broadcast();
  final StreamController<String> _identityController =
      StreamController<String>.broadcast();
  final StreamController<BinaryPayload> _binaryController =
      StreamController<BinaryPayload>.broadcast();
  final StreamController<BluetoothStateInfo> _bluetoothController =
      StreamController<BluetoothStateInfo>.broadcast();
  final StreamController<String> _receivedMessagesController =
      StreamController<String>.broadcast();

  void emitConnection(ConnectionInfo info) {
    isConnectedValue = info.isConnected;
    _connectionController.add(info);
  }

  void emitIdentity(String peerId) {
    _identityController.add(peerId);
  }

  @override
  Future<String> getMyEphemeralId() async {
    final override = getMyEphemeralIdOverride;
    if (override != null) {
      return override();
    }
    return 'ephemeral-node-id';
  }

  @override
  bool get isBluetoothReady => isBluetoothReadyValue;

  @override
  Stream<BluetoothStateInfo> get bluetoothStateStream =>
      _bluetoothController.stream;

  @override
  Stream<ConnectionInfo> get connectionInfo => _connectionController.stream;

  @override
  ConnectionInfo get currentConnectionInfo => ConnectionInfo(
    isConnected: isConnectedValue,
    isReady: isConnectedValue,
    awaitingHandshake: false,
  );

  @override
  Stream<String> get identityRevealed => _identityController.stream;

  @override
  Stream<BinaryPayload> get receivedBinaryStream => _binaryController.stream;

  @override
  Stream<String> get receivedMessages => _receivedMessagesController.stream;

  @override
  String? get currentSessionId => currentSessionIdValue;

  @override
  bool get isConnected => isConnectedValue;

  @override
  bool get canSendMessages => canSendMessagesValue;

  @override
  bool get hasPeripheralConnection => hasPeripheralConnectionValue;

  @override
  bool get canAcceptMoreConnections => canAcceptMoreConnectionsValue;

  @override
  int get activeConnectionCount => activeConnectionCountValue;

  @override
  int get maxCentralConnections => maxCentralConnectionsValue;

  @override
  List<String> get activeConnectionDeviceIds => activeConnectionDeviceIdsValue;

  @override
  List<BLEServerConnection> get serverConnections => serverConnectionsValue;

  @override
  Future<void> registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) async {
    registerQueueSyncHandlerCalls++;
  }

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage message) async {
    sendQueueSyncMessageCalls++;
  }

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSharedQueueProvider implements ISharedMessageQueueProvider {
  _FakeSharedQueueProvider({
    required bool initialized,
    this.throwOnInitialize = false,
  }) : _initialized = initialized;

  bool _initialized;
  final bool throwOnInitialize;
  int initializeCalls = 0;
  final InMemoryOfflineMessageQueue _queue = InMemoryOfflineMessageQueue();

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isInitializing => false;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (throwOnInitialize) {
      throw StateError('shared queue init failed');
    }
    _initialized = true;
  }

  @override
  OfflineMessageQueueContract get messageQueue => _queue;
}

class _FakeMeshRelayEngine implements MeshRelayEngine {
  @override
  Future<void> initialize({
    required String currentNodeId,
    Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage,
    Function(String originalMessageId, String content, String originalSender)?
    onDeliverToSelf,
    Function(RelayDecision decision)? onRelayDecision,
    Function(RelayStatistics stats)? onStatsUpdated,
  }) async {}

  @override
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? encryptedPayload,
    ProtocolMessageType? originalMessageType,
  }) async => null;

  @override
  RelayStatistics getStatistics() => const RelayStatistics(
    totalRelayed: 0,
    totalDropped: 0,
    totalDeliveredToSelf: 0,
    totalBlocked: 0,
    totalProbabilisticSkip: 0,
    spamScore: 0,
    relayEfficiency: 0,
    activeRelayMessages: 0,
    networkSize: 0,
    currentRelayProbability: 0,
  );

  @override
  Future<RelayProcessingResult> processIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    List<String> availableNextHops = const [],
    ProtocolMessageType? messageType,
  }) async => RelayProcessingResult.dropped('not used in runtime-helper tests');

  @override
  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  }) async => false;
}

class _StubRepositoryProvider implements IRepositoryProvider {
  _StubRepositoryProvider()
    : messageRepository = _InMemoryMessageRepository(),
      contactRepository = _NoopContactRepository();

  @override
  final IContactRepository contactRepository;

  @override
  final IMessageRepository messageRepository;
}

class _InMemoryMessageRepository implements IMessageRepository {
  final Map<String, Message> _store = <String, Message>{};

  @override
  Future<void> clearMessages(ChatId chatId) async {
    _store.removeWhere((_, message) => message.chatId.value == chatId.value);
  }

  @override
  Future<bool> deleteMessage(MessageId messageId) async =>
      _store.remove(messageId.value) != null;

  @override
  Future<List<Message>> getAllMessages() async =>
      _store.values.toList(growable: false);

  @override
  Future<Message?> getMessageById(MessageId messageId) async =>
      _store[messageId.value];

  @override
  Future<List<Message>> getMessages(ChatId chatId) async {
    return _store.values
        .where((message) => message.chatId.value == chatId.value)
        .toList(growable: false);
  }

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async {
    return _store.values
        .where((message) => message.chatId.value.contains(publicKey))
        .toList(growable: false);
  }

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {
    final matches = _store.values
        .where((message) => message.chatId.value == oldChatId.value)
        .toList(growable: false);
    for (final message in matches) {
      _store[message.id.value] = message.copyWith(
        chatId: newChatId,
        id: message.id,
      );
    }
  }

  @override
  Future<void> saveMessage(Message message) async {
    _store[message.id.value] = message;
  }

  @override
  Future<void> updateMessage(Message message) async {
    _store[message.id.value] = message;
  }
}

class _NoopChatsRepository implements IChatsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopArchiveRepository implements IArchiveRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopContactRepository implements IContactRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  final String _docsDir = Directory.systemTemp
      .createTempSync('mesh_runtime_helper_test')
      .path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsDir;
}

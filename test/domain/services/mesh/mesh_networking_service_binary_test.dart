import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/core/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/core/interfaces/i_connection_service.dart';
import 'package:pak_connect/core/interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/interfaces/i_message_repository.dart';
import 'package:pak_connect/core/interfaces/i_contact_repository.dart';
import 'package:pak_connect/core/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/ble_server_connection.dart';
import 'package:pak_connect/core/models/spy_mode_info.dart';
import 'package:pak_connect/core/bluetooth/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = _FakePathProviderPlatform();
    // Minimal repo provider registration for ChatManagementService singleton.
    if (GetIt.instance.isRegistered<IRepositoryProvider>()) {
      GetIt.instance.unregister<IRepositoryProvider>();
    }
    if (GetIt.instance.isRegistered<_StubRepositoryProvider>()) {
      GetIt.instance.unregister<_StubRepositoryProvider>();
    }
    final provider = _StubRepositoryProvider();
    GetIt.instance
      ..registerSingleton<_StubRepositoryProvider>(provider)
      ..registerSingleton<IRepositoryProvider>(provider);
  });

  setUp(() {
    final repoProvider = GetIt.instance<_StubRepositoryProvider>();
    (repoProvider.messageRepository as _InMemoryMessageRepository).reset();
  });

  group('MeshNetworkingService binary handling', () {
    test('propagates ttl/recipient through ReceivedBinaryEvent', () async {
      final ble = _FakeConnectionService();
      final svc = MeshNetworkingService(
        bleService: ble,
        messageHandler: _NoopFacade(),
        chatManagementService: ChatManagementService.instance,
      );

      ReceivedBinaryEvent? event;
      svc.setBinaryPayloadHandler((e) => event = e);

      final payload = BinaryPayload(
        data: Uint8List.fromList([1, 2, 3]),
        originalType: 0x90,
        fragmentId: 'frag-123',
        ttl: 4,
        recipient: 'node-b',
      );

      await svc.debugHandleBinaryPayload(payload);

      expect(event, isNotNull);
      expect(event!.ttl, 4);
      expect(event!.recipient, 'node-b');
      expect(event!.transferId, isNotEmpty);
    });

    test('queues offline binary sends and retries when connected', () async {
      final ble = _FakeConnectionService(canSend: false, connected: false);
      final svc = MeshNetworkingService(
        bleService: ble,
        messageHandler: _NoopFacade(),
        chatManagementService: ChatManagementService.instance,
      );

      final transferId = await svc.sendBinaryMedia(
        data: Uint8List.fromList([9, 9, 9]),
        recipientId: 'peer-1',
      );
      expect(transferId, isNotEmpty);
      expect(svc.pendingBinarySendCount, 1);

      ble.setConnected(true);
      ble.setCanSend(true);
      await svc.debugFlushPendingBinarySends();

      expect(ble.retryCalls, contains(transferId));
      expect(svc.pendingBinarySendCount, 0);
    });

    test('stores outbound binary messages with transferId metadata', () async {
      final ble = _FakeConnectionService();
      final svc = MeshNetworkingService(
        bleService: ble,
        messageHandler: _NoopFacade(),
        chatManagementService: ChatManagementService.instance,
      );

      final transferId = await svc.sendBinaryMedia(
        data: Uint8List.fromList([1, 2, 3, 4]),
        recipientId: 'peer-out',
      );

      final repo =
          GetIt.instance<_StubRepositoryProvider>().messageRepository
              as _InMemoryMessageRepository;
      final stored =
          await repo.getMessageById(MessageId(transferId)) as EnhancedMessage?;
      expect(stored, isNotNull);
      expect(stored!.isFromMe, isTrue);
      expect(stored.attachments.length, 1);
      expect(stored.attachments.first.id, transferId);
    });

    test('tracks initial sync peers when identity is revealed', () async {
      final ble = _FakeConnectionService();
      final svc = MeshNetworkingService(
        bleService: ble,
        messageHandler: _NoopFacade(),
        chatManagementService: ChatManagementService.instance,
      );

      expect(svc.debugHasInitialSyncScheduled('peer-sync'), isFalse);
      svc.debugHandleIdentityForSync('peer-sync');
      expect(svc.debugHasInitialSyncScheduled('peer-sync'), isTrue);

      // Identity stream events should reuse the same guard (no duplicates).
      ble.emitIdentity('peer-sync');
      await Future.delayed(Duration.zero);
      expect(svc.debugHasInitialSyncScheduled('peer-sync'), isTrue);
    });

    test('schedules initial sync on direct announce', () async {
      final ble = _FakeConnectionService();
      final svc = MeshNetworkingService(
        bleService: ble,
        messageHandler: _NoopFacade(),
        chatManagementService: ChatManagementService.instance,
      );

      expect(svc.debugHasInitialSyncScheduled('peer-ann'), isFalse);
      svc.debugHandleAnnounceForSync('peer-ann');
      expect(svc.debugHasInitialSyncScheduled('peer-ann'), isTrue);

      // Guard against duplicates.
      svc.debugHandleAnnounceForSync('peer-ann');
      expect(svc.debugHasInitialSyncScheduled('peer-ann'), isTrue);
    });
  });
}

class _NoopFacade implements IBLEMessageHandlerFacade {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnectionService implements IConnectionService {
  _FakeConnectionService({bool canSend = true, bool connected = true})
    : _canSend = canSend,
      _connected = connected;

  final StreamController<ConnectionInfo> _conn =
      StreamController<ConnectionInfo>.broadcast();
  final StreamController<String> _identityController =
      StreamController<String>.broadcast();
  final List<String> retryCalls = [];
  bool _canSend;
  bool _connected;

  void setCanSend(bool value) => _canSend = value;
  void setConnected(bool value) {
    _connected = value;
    _conn.add(ConnectionInfo(isConnected: value, isReady: value));
  }

  @override
  Stream<ConnectionInfo> get connectionInfo => _conn.stream;

  @override
  ConnectionInfo get currentConnectionInfo =>
      ConnectionInfo(isConnected: _connected, isReady: _connected);

  @override
  String? get currentSessionId => 'peer-1';

  @override
  String? get otherUserName => 'Peer One';

  @override
  String? get theirEphemeralId => 'peer-1';

  @override
  String? get theirPersistentKey => 'peer-1';

  @override
  String? get myPersistentId => 'my-id';

  @override
  bool get canSendMessages => _canSend;

  @override
  bool get hasPeripheralConnection => false;

  @override
  bool get isPeripheralMode => false;

  @override
  bool get isConnected => _connected;

  @override
  bool get canAcceptMoreConnections => true;

  @override
  int get activeConnectionCount => _connected ? 1 : 0;

  @override
  int get maxCentralConnections => 1;

  @override
  List<String> get activeConnectionDeviceIds =>
      _connected ? ['peer-1'] : <String>[];

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData =>
      const Stream.empty();

  @override
  Stream<String> get receivedMessages => const Stream.empty();

  @override
  Stream<BinaryPayload> get receivedBinaryStream => const Stream.empty();

  @override
  Stream<CentralConnectionStateChangedEventArgs>
  get peripheralConnectionChanges => const Stream.empty();

  @override
  Future<String> getMyPublicKey() async => 'pub';

  @override
  Future<String> getMyEphemeralId() async => 'eph';

  @override
  String? get theirPersistentPublicKey => null;

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async => true;

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async => true;

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage message) async {}

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {}

  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.system,
  }) async {}

  @override
  Future<void> stopScanning() async {}

  @override
  Stream<List<Peripheral>> get discoveredDevices => const Stream.empty();

  @override
  Stream<String> get hintMatches => const Stream.empty();

  @override
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) async => null;

  @override
  Stream<SpyModeInfo> get spyModeDetected => const Stream.empty();

  @override
  Stream<String> get identityRevealed => _identityController.stream;

  void emitIdentity(String peerId) => _identityController.add(peerId);

  @override
  Central? get connectedCentral => null;

  @override
  Peripheral? get connectedDevice => null;

  @override
  Stream<BluetoothStateInfo> get bluetoothStateStream => const Stream.empty();

  @override
  Stream<BluetoothStatusMessage> get bluetoothMessageStream =>
      const Stream.empty();

  @override
  bool get isBluetoothReady => true;

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;

  @override
  Future<void> startAsPeripheral() async {}

  @override
  Future<void> startAsCentral() async {}

  @override
  Future<void> refreshAdvertising({bool? showOnlineStatus}) async {}

  @override
  bool get isAdvertising => false;

  @override
  bool get isPeripheralMTUReady => false;

  @override
  int? get peripheralNegotiatedMTU => null;

  @override
  Future<void> connectToDevice(Peripheral device) async {}

  @override
  Future<void> disconnect() async {}

  @override
  void startConnectionMonitoring() {}

  @override
  void stopConnectionMonitoring() {}

  @override
  bool get isActivelyReconnecting => false;

  @override
  void setPairingInProgress(bool isInProgress) {}

  @override
  Future<void> requestIdentityExchange() async {}

  @override
  Future<void> triggerIdentityReExchange() async {}

  @override
  Future<ProtocolMessage?> revealIdentityToFriend() async => null;

  @override
  Future<void> setMyUserName(String name) async {}

  @override
  Future<void> acceptContactRequest() async {}

  @override
  void rejectContactRequest() {}

  @override
  void setContactRequestCompletedListener(
    void Function(bool success) listener,
  ) {}

  @override
  void setContactRequestReceivedListener(
    void Function(String publicKey, String displayName) listener,
  ) {}

  @override
  void setAsymmetricContactListener(
    void Function(String publicKey, String displayName) listener,
  ) {}

  @override
  List<BLEServerConnection> get serverConnections => const [];

  @override
  int get clientConnectionCount => 0;

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  }) async => 'transfer-${DateTime.now().millisecondsSinceEpoch}';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async {
    retryCalls.add(transferId);
    return true;
  }
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
  final Map<String, Message> _store = {};

  void reset() => _store.clear();

  @override
  Future<void> clearMessages(ChatId chatId) async {
    _store.removeWhere((_, m) => m.chatId.value == chatId.value);
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
    final results = _store.values
        .where((m) => m.chatId.value == chatId.value)
        .toList();
    results.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return results;
  }

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      _store.values.where((m) => m.chatId.value.contains(publicKey)).toList();

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {
    final updates = _store.values
        .where((m) => m.chatId.value == oldChatId.value)
        .map((m) => m.copyWith(chatId: newChatId, id: m.id))
        .toList();
    for (final updated in updates) {
      _store[updated.id.value] = updated;
    }
  }

  @override
  Future<void> saveMessage(Message message) async {
    _store.putIfAbsent(message.id.value, () => message);
  }

  @override
  Future<void> updateMessage(Message message) async {
    _store[message.id.value] = message;
  }
}

class _NoopContactRepository implements IContactRepository {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  final String _docsDir = Directory.systemTemp
      .createTempSync('mesh_binary_test')
      .path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsDir;
}

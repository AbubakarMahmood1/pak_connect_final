import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/interfaces/i_chats_repository.dart';
import 'package:pak_connect/core/interfaces/i_connection_service.dart';
import 'package:pak_connect/core/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/messaging/queue_sync_manager.dart';
import 'package:pak_connect/core/models/ble_server_connection.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/spy_mode_info.dart';
import 'package:pak_connect/core/bluetooth/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/core/security/message_security.dart';
import 'package:pak_connect/core/services/message_retry_coordinator.dart';
import 'package:pak_connect/core/services/persistent_chat_state_manager.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/presentation/controllers/chat_pairing_dialog_controller.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import 'package:pak_connect/presentation/controllers/chat_session_lifecycle.dart';
import 'package:pak_connect/presentation/models/chat_screen_config.dart';
import 'package:pak_connect/presentation/providers/chat_messaging_view_model.dart';
import 'package:pak_connect/presentation/viewmodels/chat_session_view_model.dart';
import 'package:pak_connect/presentation/controllers/chat_search_controller.dart';
import 'package:pak_connect/core/utils/chat_utils.dart';
import 'package:pak_connect/presentation/notifiers/chat_session_state_notifier.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('ChatSessionViewModel retry pipeline', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    testWidgets('marks message delivered when lifecycle send succeeds', (
      tester,
    ) async {
      final messageRepo = _FakeMessageRepository();
      final viewModel = await _buildViewModel(
        tester: tester,
        messageRepository: messageRepo,
      );
      final lifecycle = _RecordingLifecycle(viewModel: viewModel);
      final stateStore = _FakeStateStore()..setMessages([_failedMessage]);
      viewModel.bindStateStore(stateStore);
      viewModel.sessionLifecycle = lifecycle;

      await viewModel.retryRepositoryMessage(_failedMessage);

      expect(
        messageRepo.messages[_failedMessage.id.value]!.status,
        MessageStatus.delivered,
      );
      expect(stateStore.current.messages.first.status, MessageStatus.delivered);
      expect(lifecycle.lastSendPayload?.message.id, _failedMessage.id);
    });

    testWidgets('keeps message failed when lifecycle send fails', (
      tester,
    ) async {
      final messageRepo = _FakeMessageRepository();
      final viewModel = await _buildViewModel(
        tester: tester,
        messageRepository: messageRepo,
      );
      final lifecycle = _RecordingLifecycle(
        viewModel: viewModel,
        sendSuccess: false,
      );
      final stateStore = _FakeStateStore()..setMessages([_failedMessage]);
      viewModel.bindStateStore(stateStore);
      viewModel.sessionLifecycle = lifecycle;

      await viewModel.retryRepositoryMessage(_failedMessage);

      expect(
        messageRepo.messages[_failedMessage.id.value]!.status,
        MessageStatus.failed,
      );
      expect(stateStore.current.messages.first.status, MessageStatus.failed);
    });
  });

  group('ChatSessionViewModel identity swap', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    testWidgets('migrates messages and re-registers persistent listener', (
      tester,
    ) async {
      final messageRepo = _FakeMessageRepository();
      final persistentManager = PersistentChatStateManager();
      persistentManager.cleanupAll();
      final connectionService = _FakeConnectionService(
        theirPersistentKey: 'persistent-key',
      );

      String? updatedChatId;
      String? updatedContactKey;

      final viewModel = await _buildViewModel(
        tester: tester,
        messageRepository: messageRepo,
        persistentManager: persistentManager,
        connectionService: connectionService,
        onChatIdUpdated: (id) => updatedChatId = id,
        onContactPublicKeyUpdated: (key) => updatedContactKey = key,
      );
      final lifecycle = _RecordingLifecycle(viewModel: viewModel);

      final stateStore = _FakeStateStore()..setMessages([_deliveredMessage]);
      viewModel.bindStateStore(stateStore);
      viewModel.sessionLifecycle = lifecycle;
      messageRepo.messages[_deliveredMessage.id.value] = _deliveredMessage;

      await viewModel.handleIdentityReceived();

      final newChatId = ChatUtils.generateChatId('persistent-key');
      expect(updatedChatId, newChatId);
      expect(updatedContactKey, 'persistent-key');
      expect(messageRepo.messages.values.first.chatId, newChatId);
    });
  });

  group('ChatSessionViewModel message listener activation', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    testWidgets('registers persistent listener when available', (tester) async {
      final persistentManager = PersistentChatStateManager();
      persistentManager.cleanupAll();
      final connectionService = _FakeConnectionService();
      final viewModel = await _buildViewModel(
        tester: tester,
        persistentManager: persistentManager,
        connectionService: connectionService,
      );
      final lifecycle = _RecordingLifecycle(viewModel: viewModel);
      viewModel.sessionLifecycle = lifecycle;

      await viewModel.activateMessageListener();

      expect(lifecycle.messageListenerActive, isTrue);
      expect(lifecycle.attachedStreams, isEmpty);
    });

    testWidgets('falls back to stream mode when no persistent manager', (
      tester,
    ) async {
      final connectionService = _FakeConnectionService();
      final viewModel = await _buildViewModel(
        tester: tester,
        connectionService: connectionService,
        persistentManager: null,
      );
      final lifecycle = _RecordingLifecycle(viewModel: viewModel);
      viewModel.sessionLifecycle = lifecycle;

      await viewModel.activateMessageListener();
      connectionService.messageController.add('hello');
      await tester.pump();

      expect(lifecycle.messageListenerActive, isTrue);
      expect(lifecycle.attachedStreams.length, 1);
      expect(lifecycle.messageBuffer.contains('hello'), isTrue);
    });
  });
}

Future<ChatSessionViewModel> _buildViewModel({
  required WidgetTester tester,
  MessageRepository? messageRepository,
  ContactRepository? contactRepository,
  ChatsRepository? chatsRepository,
  PersistentChatStateManager? persistentManager,
  IConnectionService? connectionService,
  String Function(String)? onChatIdUpdated,
  void Function(String?)? onContactPublicKeyUpdated,
}) async {
  final resolvedMessageRepo = messageRepository ?? _FakeMessageRepository();
  final resolvedContactRepo = contactRepository ?? _FakeContactRepository();
  final resolvedChatsRepo = chatsRepository ?? _FakeChatsRepository();
  late ChatSessionViewModel viewModel;

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          final scrollingController = chat_controller.ChatScrollingController(
            chatsRepository: resolvedChatsRepo,
            chatId: 'chat-1',
            onScrollToBottom: () {},
            onUnreadCountChanged: (_) {},
            onStateChanged: () {},
          );
          final searchController = ChatSearchController(
            onSearchModeToggled: (_) {},
            onSearchResultsChanged: (_, __) {},
            onNavigateToResult: (_) {},
            scrollController: scrollingController.scrollController,
          );

          viewModel = ChatSessionViewModel(
            config: ChatScreenConfig(chatId: 'chat-1', contactName: 'test'),
            messageRepository: resolvedMessageRepo,
            contactRepository: resolvedContactRepo,
            chatsRepository: resolvedChatsRepo,
            messagingViewModel: _StubMessagingViewModel(
              chatId: 'chat-1',
              contactPublicKey: 'contact-1',
              messageRepository: resolvedMessageRepo,
              contactRepository: resolvedContactRepo,
            ),
            scrollingController: scrollingController,
            searchController: searchController,
            pairingDialogController: _StubPairingController(context),
            retryCoordinator: null,
            sessionLifecycle: null,
            displayContactNameFn: () => 'Test Contact',
            getContactPublicKeyFn: () => 'contact-1',
            getChatIdFn: () => 'chat-1',
            getConnectionServiceFn: () =>
                connectionService ?? _FakeConnectionService(),
            getPersistentChatManagerFn: () => persistentManager,
            onChatIdUpdated: onChatIdUpdated,
            onContactPublicKeyUpdated: onContactPublicKeyUpdated,
          );

          return const SizedBox.shrink();
        },
      ),
    ),
  );

  return viewModel;
}

final _failedMessage = Message(
  id: MessageId('failed-1'),
  chatId: 'chat-1',
  content: 'fail me',
  timestamp: DateTime(2024, 1, 1),
  isFromMe: true,
  status: MessageStatus.failed,
);

final _deliveredMessage = Message(
  id: MessageId('delivered-1'),
  chatId: 'chat-1',
  content: 'hi',
  timestamp: DateTime(2024, 1, 1),
  isFromMe: true,
  status: MessageStatus.delivered,
);

class _RecordingLifecycle extends ChatSessionLifecycle {
  _RecordingLifecycle({
    required ChatSessionViewModel viewModel,
    this.sendSuccess = true,
  }) : super(
         viewModel: viewModel,
         connectionService: _FakeConnectionService(),
         meshService: _FakeMeshService(),
         messageSecurity: MessageSecurity(),
         messageRepository: _FakeMessageRepository(),
       );

  final bool sendSuccess;
  _SendPayload? lastSendPayload;
  final List<Stream<String>> attachedStreams = [];

  @override
  void registerPersistentListener({
    required String chatId,
    required Stream<String> Function() incomingStream,
    required Future<void> Function(String content) onMessage,
  }) {
    persistentChatManager ??= PersistentChatStateManager();
    persistentChatManager!.registerChatScreen(chatId, (content) {});
  }

  @override
  void attachMessageStream({
    required Stream<String> stream,
    required bool Function() disposed,
    required bool Function() isActive,
    required Future<void> Function(String content) onMessage,
  }) {
    attachedStreams.add(stream);
    stream.listen((content) {
      messageBuffer.add(content);
    });
  }

  @override
  void scheduleAutoRetry({
    required Duration delay,
    required bool Function() disposed,
    required Future<void> Function() onRetry,
  }) {
    // Disable timers in tests.
  }

  @override
  Future<bool> sendRepositoryMessage({
    required Message message,
    required String fallbackRecipientId,
    required String displayContactName,
    String? contactPublicKey,
    void Function(String message)? onInfoMessage,
  }) async {
    lastSendPayload = _SendPayload(
      message: message,
      fallbackRecipientId: fallbackRecipientId,
      contactPublicKey: contactPublicKey,
    );
    return sendSuccess;
  }
}

class _SendPayload {
  _SendPayload({
    required this.message,
    required this.fallbackRecipientId,
    required this.contactPublicKey,
  });

  final Message message;
  final String fallbackRecipientId;
  final String? contactPublicKey;
}

class _FakeMessageRepository extends MessageRepository {
  final Map<String, Message> messages = {};

  @override
  Future<void> saveMessage(Message message) async {
    messages[message.id.value] = message;
  }

  @override
  Future<void> updateMessage(Message message) async {
    messages[message.id.value] = message;
  }

  @override
  Future<List<Message>> getMessages(String chatId) async {
    return messages.values.where((m) => m.chatId == chatId).toList();
  }

  @override
  Future<Message?> getMessageById(MessageId id) async => messages[id.value];

  @override
  Future<void> clearMessages(String chatId) async {
    messages.removeWhere((_, msg) => msg.chatId == chatId);
  }
}

class _FakeContactRepository extends ContactRepository {}

class _FakeChatsRepository extends ChatsRepository implements IChatsRepository {
  final List<ChatListItem> _chats = [];

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async => _chats;

  @override
  Future<void> incrementUnreadCount(String chatId) async {}

  @override
  Future<void> markChatAsRead(String chatId) async {}

  @override
  Future<List<Contact>> getContactsWithoutChats() async => [];

  @override
  Future<void> updateContactLastSeen(String publicKey) async {}

  @override
  Future<int> getTotalUnreadCount() async => 0;

  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}

  @override
  Future<int> getChatCount() async => 0;

  @override
  Future<int> getArchivedChatCount() async => 0;

  @override
  Future<int> getTotalMessageCount() async => 0;

  @override
  Future<int> cleanupOrphanedEphemeralContacts() async => 0;
}

class _FakeConnectionService implements IConnectionService {
  _FakeConnectionService({this.theirPersistentKey});

  final String? theirPersistentKey;
  final StreamController<String> messageController =
      StreamController<String>.broadcast();

  @override
  String? get theirPersistentPublicKey => theirPersistentKey;

  @override
  Stream<String> get receivedMessages => messageController.stream;

  @override
  Stream<String> get identityRevealed => const Stream.empty();

  // Unused members
  @override
  Stream<List<Peripheral>> get discoveredDevices => const Stream.empty();
  @override
  Stream<String> get hintMatches => const Stream.empty();
  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData =>
      const Stream.empty();
  @override
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) async => null;
  @override
  Stream<SpyModeInfo> get spyModeDetected => const Stream.empty();
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
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.unknown;
  @override
  ConnectionInfo get currentConnectionInfo =>
      const ConnectionInfo(isConnected: true, isReady: true);
  @override
  Stream<ConnectionInfo> get connectionInfo =>
      Stream.value(const ConnectionInfo(isConnected: true, isReady: true));
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
  void setContactRequestCompletedListener(void Function(bool p1) listener) {}
  @override
  void setContactRequestReceivedListener(
    void Function(String p1, String p2) listener,
  ) {}
  @override
  void setAsymmetricContactListener(
    void Function(String p1, String p2) listener,
  ) {}
  @override
  void setPairingInProgress(bool isInProgress) {}
  @override
  List<BLEServerConnection> get serverConnections => [];
  @override
  int get clientConnectionCount => 0;
  @override
  int get maxCentralConnections => 0;
  @override
  Stream<CentralConnectionStateChangedEventArgs>
  get peripheralConnectionChanges => const Stream.empty();
  @override
  bool get canSendMessages => true;
  @override
  bool get hasPeripheralConnection => false;
  @override
  bool get isPeripheralMode => false;
  @override
  bool get isConnected => true;
  @override
  bool get canAcceptMoreConnections => true;
  @override
  int get activeConnectionCount => 0;
  @override
  List<String> get activeConnectionDeviceIds => [];
  @override
  Future<String> getMyPublicKey() async => 'me';
  @override
  String? get currentSessionId => 'chat-1';
  @override
  Future<String> getMyEphemeralId() async => 'eph';
  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage p1, String p2) handler,
  ) {}
  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async => true;
  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async => true;
  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage message) async {}
  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.system,
  }) async {}
  @override
  Future<void> stopScanning() async {}
}

class _FakeMeshService implements IMeshNetworkingService {
  @override
  Future<void> dispose() async {}
  @override
  Future<void> initialize({String? nodeId}) async {}
  @override
  Stream<MeshNetworkStatus> get meshStatus => const Stream.empty();
  @override
  Stream<RelayStatistics> get relayStats => const Stream.empty();
  @override
  Stream<QueueSyncManagerStats> get queueStats => const Stream.empty();
  @override
  Stream<String> get messageDeliveryStream => const Stream.empty();
  @override
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async => MeshSendResult.direct('id');
  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async => {};
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
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) => [];
  @override
  MeshNetworkStatistics getNetworkStatistics() => MeshNetworkStatistics(
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
  void refreshMeshStatus() {}
}

class _StubMessagingViewModel extends ChatMessagingViewModel {
  _StubMessagingViewModel({
    required super.chatId,
    required super.contactPublicKey,
    required super.messageRepository,
    required super.contactRepository,
  });

  @override
  Future<void> sendMessage({
    required String content,
    OnMessageAddedCallback? onMessageAdded,
    OnShowSuccessCallback? onShowSuccess,
    OnShowErrorCallback? onShowError,
    OnScrollToBottomCallback? onScrollToBottom,
    OnClearInputFieldCallback? onClearInputField,
  }) async {}
}

class _StubPairingController extends ChatPairingDialogController {
  _StubPairingController(BuildContext context, {NavigatorState? navigator})
    : super(
        stateManager: BLEStateManager(),
        connectionService: _FakeConnectionService(),
        contactRepository: ContactRepository(),
        context: context,
        navigator: navigator ?? _FakeNavigatorState(),
        getTheirPersistentKey: () => null,
      );
}

class _FakeStateStore extends ChatSessionStateStore {}

class _FakeNavigatorState extends NavigatorState {}

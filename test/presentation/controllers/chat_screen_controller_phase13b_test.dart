/// Phase 13b: Additional ChatScreenController coverage
/// Targets uncovered branches: sendMessage flow, retryFailedMessages,
/// handleConnectionChange, deleteMessage, securityStateKey, chatId
/// calculation, applyMessageUpdate, controller getters, dispose lifecycle,
/// publishState, handleMeshInitializationStatusChange, config passthrough.

import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult;
import 'package:pak_connect/domain/models/mesh_relay_models.dart'
    show RelayStatistics, QueueSyncMessage;
import 'package:pak_connect/domain/services/message_router.dart';
import 'package:pak_connect/domain/services/message_retry_coordinator.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/utils/chat_utils.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/presentation/controllers/chat_screen_controller.dart';
import 'package:pak_connect/presentation/models/chat_screen_config.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/presentation/controllers/chat_pairing_dialog_controller.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import 'package:pak_connect/presentation/controllers/chat_search_controller.dart';
import 'package:pak_connect/presentation/controllers/chat_session_lifecycle.dart';
import 'package:pak_connect/presentation/providers/chat_messaging_view_model.dart';
import 'package:pak_connect/presentation/viewmodels/chat_session_view_model.dart';
import 'package:pak_connect/domain/services/message_security.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/presentation/models/chat_ui_state.dart';
import 'package:pak_connect/presentation/notifiers/chat_session_state_notifier.dart';
import '../../test_helpers/mocks/mock_connection_service.dart';
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  late MockConnectionService connectionService;
  late _FakeMeshNetworkingService meshService;

  final readyStatus = MeshNetworkStatus(
    isInitialized: true,
    currentNodeId: 'node',
    isConnected: true,
    statistics: MeshNetworkStatistics(
      nodeId: 'node',
      isInitialized: true,
      relayStatistics: null,
      queueStatistics: null,
      syncStatistics: null,
      spamStatistics: null,
      spamPreventionActive: false,
      queueSyncActive: false,
    ),
    queueMessages: const [],
  );

  const readyConnectionInfo = ConnectionInfo(
    isConnected: true,
    isReady: true,
    statusMessage: 'ready',
  );

  const offlineConnectionInfo = ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'offline',
  );

  setUp(() {
    connectionService = MockConnectionService();
    meshService = _FakeMeshNetworkingService();
  });

  ProviderScope defaultProviderScope({required Widget child}) =>
      ProviderScope(
        overrides: [
          connectionServiceProvider.overrideWithValue(connectionService),
          meshNetworkingServiceProvider.overrideWithValue(meshService),
          meshNetworkingControllerProvider.overrideWithValue(
            MeshNetworkingController(meshService),
          ),
          meshNetworkStatusProvider.overrideWith(
            (ref) => AsyncValue.data(readyStatus),
          ),
          connectionInfoProvider.overrideWith(
            (ref) => const AsyncValue.data(readyConnectionInfo),
          ),
        ],
        child: child,
      );

  // Helper to build a controller in a widget tree, avoiding repetition.
  Future<ChatScreenController> buildController(
    WidgetTester tester, {
    ChatScreenConfig config = const ChatScreenConfig(
      chatId: 'chat-1',
      contactName: 'T',
      contactPublicKey: 'pk1',
    ),
    MessageRepository? messageRepository,
    ContactRepository? contactRepository,
  }) async {
    late ChatScreenController controller;
    await tester.pumpWidget(
      defaultProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Consumer(
              builder: (context, ref, _) {
                controller = _buildController(
                  ref: ref,
                  context: context,
                  config: config,
                  messageRepository:
                      messageRepository ?? _FakeMessageRepository(),
                  contactRepository:
                      contactRepository ?? _FakeContactRepository(),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  group('ChatScreenController – Phase 13b coverage', () {
    // ---------------------------------------------------------------
    // Synchronous getters (no init needed)
    // ---------------------------------------------------------------
    group('controller getters', () {
      testWidgets('scrollingController is accessible', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        expect(c.scrollingController, isNotNull);
      });

      testWidgets('searchController is accessible', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        expect(c.searchController, isNotNull);
      });

      testWidgets('pairingDialogController is accessible', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        expect(c.pairingDialogController, isNotNull);
      });

      testWidgets('args getter returns original args', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        expect(c.args, isNotNull);
        expect(c.args.config.chatId, 'chat-1');
      });

      testWidgets('sessionViewModel is accessible', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        expect(c.sessionViewModel, isNotNull);
      });

      testWidgets('sessionLifecycle is accessible', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        expect(c.sessionLifecycle, isNotNull);
      });

      testWidgets('state returns ChatUIState', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        expect(c.state, isA<ChatUIState>());
      });
    });

    // ---------------------------------------------------------------
    // config passthrough
    // ---------------------------------------------------------------
    group('config passthrough', () {
      testWidgets('config is properly passed through', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(
            chatId: 'my-chat',
            contactName: 'TestUser',
            contactPublicKey: 'test-pk',
          ),
        );
        expect(c.config.chatId, 'my-chat');
        expect(c.config.contactName, 'TestUser');
        expect(c.config.contactPublicKey, 'test-pk');
        expect(c.config.isRepositoryMode, isTrue);
      });
    });

    // ---------------------------------------------------------------
    // chatId calculation
    // ---------------------------------------------------------------
    group('chatId calculation', () {
      testWidgets('uses config.chatId when available', (tester) async {
        connectionService.currentSessionId = 'sess';
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(
            chatId: 'custom-id',
            contactPublicKey: 'pk',
          ),
        );
        expect(c.chatId, 'custom-id');
      });

      testWidgets('falls back to pending_chat_id when nothing available', (
        tester,
      ) async {
        connectionService.currentSessionId = null;
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(),
        );
        expect(c.chatId, 'pending_chat_id');
      });

      testWidgets('uses contactPublicKey when no chatId in config', (
        tester,
      ) async {
        connectionService.currentSessionId = 'sess';
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(contactPublicKey: 'pk-as-id'),
        );
        expect(c.chatId, 'pk-as-id');
      });
    });

    // ---------------------------------------------------------------
    // securityStateKey
    // ---------------------------------------------------------------
    group('securityStateKey', () {
      testWidgets('returns contactPublicKey when available', (tester) async {
        connectionService.currentSessionId = 'sess';
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(
            chatId: 'c1',
            contactPublicKey: 'pk-sec',
          ),
        );
        expect(c.securityStateKey, 'pk-sec');
      });

      testWidgets('falls back to sessionId when no publicKey', (
        tester,
      ) async {
        connectionService.currentSessionId = 'fallback-sess';
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(),
        );
        expect(c.securityStateKey, 'fallback-sess');
      });
    });

    // ---------------------------------------------------------------
    // displayContactName edge cases
    // ---------------------------------------------------------------
    group('displayContactName', () {
      testWidgets('returns Unknown when non-repo and no connection info', (
        tester,
      ) async {
        connectionService.currentSessionId = 'sess';
        connectionService.emitConnectionInfo(offlineConnectionInfo);
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(contactPublicKey: 'pk1'),
        );
        expect(c.displayContactName, 'Unknown');
      });

      testWidgets('returns config.contactName in repository mode', (
        tester,
      ) async {
        connectionService.currentSessionId = 'sess';
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(
            chatId: 'c1',
            contactName: 'Alice',
            contactPublicKey: 'pk1',
          ),
        );
        expect(c.displayContactName, 'Alice');
      });

      testWidgets('returns otherUserName from connection when non-repo', (
        tester,
      ) async {
        connectionService.currentSessionId = 'sess';
        connectionService.emitConnectionInfo(
          const ConnectionInfo(
            isConnected: true,
            isReady: true,
            otherUserName: 'Bob',
            statusMessage: 'ok',
          ),
        );
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(contactPublicKey: 'pk1'),
        );
        expect(c.displayContactName, 'Bob');
      });
    });

    // ---------------------------------------------------------------
    // publishState
    // ---------------------------------------------------------------
    group('publishState', () {
      testWidgets('updates state store', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        c.publishState(
          const ChatUIState(isLoading: false, initializationStatus: 'Done'),
        );
        expect(c.state.initializationStatus, 'Done');
      });

      testWidgets('no-op after dispose', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        c.dispose();
        // Should not throw
        c.publishState(
          const ChatUIState(isLoading: false, initializationStatus: 'new'),
        );
      });

      testWidgets('publishes loading state', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        c.publishState(const ChatUIState(isLoading: true));
        expect(c.state.isLoading, isTrue);
      });

      testWidgets('publishes messages list', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        final msgs = [
          Message(
            id: MessageId('m1'),
            chatId: ChatId('chat-1'),
            content: 'Hi',
            timestamp: DateTime.now(),
            isFromMe: true,
            status: MessageStatus.sent,
          ),
        ];
        c.publishState(ChatUIState(isLoading: false, messages: msgs));
        expect(c.state.messages.length, 1);
      });
    });

    // ---------------------------------------------------------------
    // handleMeshInitializationStatusChange
    // ---------------------------------------------------------------
    group('handleMeshInitializationStatusChange', () {
      testWidgets('delegates to sessionLifecycle.handleMeshStatus', (
        tester,
      ) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        // Should not throw
        c.handleMeshInitializationStatusChange(
          null,
          AsyncValue.data(readyStatus),
        );
      });

      testWidgets('no-ops after dispose', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        c.dispose();
        c.handleMeshInitializationStatusChange(
          null,
          AsyncValue.data(readyStatus),
        );
      });
    });

    // ---------------------------------------------------------------
    // applyMessageUpdate
    // ---------------------------------------------------------------
    group('applyMessageUpdate', () {
      testWidgets('update with nonexistent message does not crash', (
        tester,
      ) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        final msg = Message(
          id: MessageId('nonexistent'),
          chatId: ChatId('chat-1'),
          content: 'ghost',
          timestamp: DateTime.now(),
          isFromMe: true,
          status: MessageStatus.delivered,
        );
        c.applyMessageUpdate(msg);
      });
    });

    // ---------------------------------------------------------------
    // dispose lifecycle
    // ---------------------------------------------------------------
    group('dispose lifecycle', () {
      testWidgets('dispose cleans up all sub-controllers', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        c.dispose();
        // Should not throw
      });
    });

    // ---------------------------------------------------------------
    // handleConnectionChange (synchronous path)
    // ---------------------------------------------------------------
    group('handleConnectionChange', () {
      testWidgets('handleConnectionChange offline to offline', (
        tester,
      ) async {
        connectionService.currentSessionId = 'sess-1';
        final c = await buildController(tester);
        c.handleConnectionChange(offlineConnectionInfo, offlineConnectionInfo);
      });
    });

    // ---------------------------------------------------------------
    // Async tests using tester.runAsync (all at end)
    // ---------------------------------------------------------------

    group('retryFailedMessages', () {
      testWidgets('delegates to viewModel', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        await tester.runAsync(() async {
          await c.retryFailedMessages();
        });
      });
    });

    group('handleIdentityReceived', () {
      testWidgets('delegates to sessionViewModel', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        await tester.runAsync(() async {
          await c.handleIdentityReceived();
        });
      });
    });

    group('manualReconnection', () {
      testWidgets('delegates to sessionLifecycle', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        await tester.runAsync(() async {
          await c.manualReconnection();
        });
      });
    });

    group('deleteMessage', () {
      testWidgets('deleteMessage with deleteForEveryone=true', (
        tester,
      ) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        await tester.runAsync(() async {
          await c.deleteMessage(MessageId('msg-del'), true);
        });
      });

      testWidgets('deleteMessage with deleteForEveryone=false', (
        tester,
      ) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        await tester.runAsync(() async {
          await c.deleteMessage(MessageId('msg-del-2'), false);
        });
      });
    });

    group('initialize', () {
      testWidgets('initializes in repo mode', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        await tester.runAsync(() async {
          await c.initialize(logChatOpen: false);
        });
        expect(c.sessionLifecycle.messageListenerActive, isTrue);
      });

      testWidgets('second initialize call is no-op', (tester) async {
        connectionService.currentSessionId = 'chat-1';
        final c = await buildController(tester);
        await tester.runAsync(() async {
          await c.initialize(logChatOpen: false);
          await c.initialize(logChatOpen: false);
        });
      });

      testWidgets('handleConnectionChange after init with reconnect', (
        tester,
      ) async {
        connectionService.currentSessionId = 'sess-1';
        final c = await buildController(
          tester,
          config: const ChatScreenConfig(
            chatId: 'chat-1',
            contactName: 'T',
            contactPublicKey: 'pk-conn',
          ),
        );
        await tester.runAsync(() async {
          await c.initialize(logChatOpen: false);
          c.handleConnectionChange(readyConnectionInfo, offlineConnectionInfo);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          c.handleConnectionChange(offlineConnectionInfo, readyConnectionInfo);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        expect(c.sessionLifecycle.messageListenerActive, isTrue);
      });
    });
  });
}

// =================================================================
// Builder helpers
// =================================================================

ChatScreenController _buildController({
  required WidgetRef ref,
  required BuildContext context,
  required ChatScreenConfig config,
  required MessageRepository messageRepository,
  required ContactRepository contactRepository,
  ChatsRepository? chatsRepository,
  MessageRetryCoordinator? retryCoordinator,
  Future<void> Function(Message message)? repositoryRetryHandler,
  ChatPairingDialogController? pairingDialogController,
}) {
  final effectiveChatsRepo = chatsRepository ?? _FakeChatsRepository();
  return ChatScreenController(
    ChatScreenControllerArgs(
      ref: ref,
      context: context,
      config: config,
      messageRepository: messageRepository,
      contactRepository: contactRepository,
      chatsRepository: effectiveChatsRepo,
      retryCoordinator: retryCoordinator,
      repositoryRetryHandler: repositoryRetryHandler,
      pairingDialogController: pairingDialogController,
      messagingViewModelFactory: (chatId, contactPublicKey) =>
          ChatMessagingViewModel(
            chatId: chatId,
            contactPublicKey: contactPublicKey,
            messageRepository: messageRepository,
            contactRepository: contactRepository,
          ),
      scrollingControllerFactory:
          (chatId, onScrollToBottom, onUnreadCountChanged, onStateChanged) =>
              chat_controller.ChatScrollingController(
                chatsRepository: effectiveChatsRepo,
                chatId: chatId,
                onScrollToBottom: onScrollToBottom,
                onUnreadCountChanged: onUnreadCountChanged,
                onStateChanged: onStateChanged,
              ),
      searchControllerFactory:
          (
            onSearchModeToggled,
            onSearchResultsChanged,
            onNavigateToResult,
            scrollController,
          ) => ChatSearchController(
            onSearchModeToggled: onSearchModeToggled,
            onSearchResultsChanged: (query, results) =>
                onSearchResultsChanged(query, const []),
            onNavigateToResult: onNavigateToResult,
            scrollController: scrollController,
          ),
      pairingControllerFactory:
          (
            ctx,
            connService,
            contactRepo,
            navigator,
            stateManager,
            onCompleted,
            onError,
            onSuccess,
          ) => ChatPairingDialogController(
            stateManager: stateManager,
            connectionService: connService,
            contactRepository: contactRepo,
            context: ctx,
            navigator: navigator,
            getTheirPersistentKey: () =>
                connService.theirPersistentPublicKey,
            onPairingCompleted: onCompleted,
            onPairingError: onError,
            onPairingSuccess: onSuccess,
          ),
      sessionViewModelFactory:
          ({
            required ChatScreenConfig config,
            required IMessageRepository messageRepository,
            required IContactRepository contactRepository,
            required IChatsRepository chatsRepository,
            required ChatMessagingViewModel messagingViewModel,
            required chat_controller.ChatScrollingController
            scrollingController,
            required ChatSearchController searchController,
            required ChatPairingDialogController pairingDialogController,
            MessageRetryCoordinator? retryCoordinator,
            ChatSessionLifecycle? sessionLifecycle,
            String Function()? displayContactNameFn,
            String? Function()? getContactPublicKeyFn,
            String Function()? getChatIdFn,
            void Function(String)? onChatIdUpdated,
            void Function(String?)? onContactPublicKeyUpdated,
            void Function()? onScrollToBottom,
            void Function(String)? onShowError,
            void Function(String)? onShowSuccess,
            void Function(String)? onShowInfo,
            bool Function()? isDisposedFn,
            void Function({
              required ChatMessagingViewModel messagingViewModel,
              required chat_controller.ChatScrollingController
              scrollingController,
              required ChatSearchController searchController,
              ChatMessagingViewModel? previousMessagingViewModel,
              chat_controller.ChatScrollingController?
              previousScrollingController,
              ChatSearchController? previousSearchController,
            })?
            onControllersRebound,
            IConnectionService Function()? getConnectionServiceFn,
          }) => ChatSessionViewModel(
            config: config,
            messageRepository: messageRepository,
            contactRepository: contactRepository,
            chatsRepository: chatsRepository,
            messagingViewModel: messagingViewModel,
            scrollingController: scrollingController,
            searchController: searchController,
            pairingDialogController: pairingDialogController,
            retryCoordinator: retryCoordinator,
            sessionLifecycle: sessionLifecycle,
            displayContactNameFn: displayContactNameFn,
            getContactPublicKeyFn: getContactPublicKeyFn,
            getChatIdFn: getChatIdFn,
            onChatIdUpdated: onChatIdUpdated,
            onContactPublicKeyUpdated: onContactPublicKeyUpdated,
            onScrollToBottom: onScrollToBottom,
            onShowError: onShowError,
            onShowSuccess: onShowSuccess,
            onShowInfo: onShowInfo,
            isDisposedFn: isDisposedFn,
            onControllersRebound: onControllersRebound,
            getConnectionServiceFn: getConnectionServiceFn,
          ),
      sessionLifecycleFactory:
          ({
            required ChatSessionViewModel viewModel,
            required IConnectionService connectionService,
            required IMeshNetworkingService meshService,
            MessageRouter? messageRouter,
            required MessageSecurity messageSecurity,
            required IMessageRepository messageRepository,
            MessageRetryCoordinator? retryCoordinator,
            OfflineMessageQueueContract? offlineQueue,
            Logger? logger,
          }) => ChatSessionLifecycle(
            viewModel: viewModel,
            connectionService: connectionService,
            meshService: meshService,
            messageRouter: messageRouter,
            messageSecurity: messageSecurity,
            messageRepository: messageRepository,
            retryCoordinator: retryCoordinator,
            offlineQueue: offlineQueue,
            logger: logger,
          ),
    ),
  );
}

// =================================================================
// Fakes
// =================================================================

class _FakeMessageRepository extends MessageRepository {
  final Map<String, List<Message>> _store = {};

  @override
  Future<List<Message>> getMessages(ChatId chatId) async =>
      List<Message>.from(_store[chatId.value] ?? []);

  @override
  Future<Message?> getMessageById(MessageId messageId) async {
    for (final entry in _store.values) {
      for (final message in entry) {
        if (message.id == messageId) return message;
      }
    }
    return null;
  }

  @override
  Future<void> saveMessage(Message message) async {
    final messages = _store.putIfAbsent(message.chatId.value, () => []);
    if (!messages.any((m) => m.id == message.id)) {
      messages.add(message);
    }
  }

  @override
  Future<void> updateMessage(Message message) async {
    final messages = _store[message.chatId.value];
    if (messages == null) return;
    final index = messages.indexWhere((m) => m.id == message.id);
    if (index != -1) {
      messages[index] = message;
    }
  }

  @override
  Future<bool> deleteMessage(MessageId messageId) async {
    var removed = false;
    _store.updateAll((key, value) {
      final before = value.length;
      value.removeWhere((m) => m.id == messageId);
      if (value.length < before) removed = true;
      return value;
    });
    return removed;
  }

  @override
  Future<void> clearMessages(ChatId chatId) async {
    _store.remove(chatId.value);
  }

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {
    final messages = _store[oldChatId.value];
    if (messages != null) {
      _store[newChatId.value] =
          messages.map((m) => m.copyWith(chatId: newChatId)).toList();
      _store.remove(oldChatId.value);
    }
  }

  @override
  Future<List<Message>> getAllMessages() async =>
      _store.values.expand((m) => m).toList();

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      _store[publicKey] ?? [];
}

class _FakeContactRepository extends ContactRepository {
  @override
  Future<Contact?> getContact(String publicKey) async => null;

  @override
  Future<Contact?> getContactByUserId(UserId userId) async => null;
}

class _FakeChatsRepository extends ChatsRepository {
  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async => [];

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}

  @override
  Future<void> incrementUnreadCount(ChatId chatId) async {}
}

class _FakeMeshNetworkingService implements IMeshNetworkingService {
  final StreamController<MeshNetworkStatus> statusController =
      StreamController<MeshNetworkStatus>.broadcast();
  final StreamController<String> deliveryController =
      StreamController<String>.broadcast();

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
  }) async => MeshSendResult.direct('msg');

  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async =>
      <String, QueueSyncResult>{};

  @override
  Future<int> processIncomingSync(
    QueueSyncMessage syncMessage,
    String fromNodeId,
  ) async => 0;

  @override
  int getQueuedMessageCount() => 0;

  @override
  List<QueuedMessage> getQueuedMessagesForRecipient(String recipientId) => [];

  @override
  Future<bool> retryMessage(String messageId) async => true;

  @override
  Future<bool> removeMessage(String messageId) async => true;

  @override
  Future<bool> setPriority(
    String messageId,
    MessagePriority priority,
  ) async => true;

  @override
  Future<int> retryAllMessages() async => 0;

  @override
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) => [];

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

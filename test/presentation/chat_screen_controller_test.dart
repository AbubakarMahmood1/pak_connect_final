import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/core/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/queue_sync_manager.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/message_router.dart';
import 'package:pak_connect/core/services/message_retry_coordinator.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/utils/chat_utils.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/presentation/controllers/chat_screen_controller.dart';
import 'package:pak_connect/presentation/models/chat_screen_config.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/presentation/controllers/chat_pairing_dialog_controller.dart';
import 'package:pak_connect/core/interfaces/i_connection_service.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import 'package:pak_connect/presentation/controllers/chat_search_controller.dart';
import 'package:pak_connect/presentation/controllers/chat_session_lifecycle.dart';
import 'package:pak_connect/presentation/providers/chat_messaging_view_model.dart';
import 'package:pak_connect/presentation/viewmodels/chat_session_view_model.dart';
import 'package:pak_connect/core/security/message_security.dart';
import '../test_helpers/mocks/mock_connection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('ChatScreenController', () {
    late MockConnectionService connectionService;
    late _FakeMeshNetworkingService meshService;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      connectionService = MockConnectionService();
      meshService = _FakeMeshNetworkingService();
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

    final _readyStatus = MeshNetworkStatus(
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

    testWidgets('migrates messages to persistent chat ID on identity receive', (
      tester,
    ) async {
      final initialChatId = ChatUtils.generateChatId('ephemeral-key');
      final fakeMessageRepo = _FakeMessageRepository();
      await fakeMessageRepo.saveMessage(
        Message(
          id: MessageId('m1'),
          chatId: ChatId(initialChatId),
          content: 'hello',
          timestamp: DateTime.now(),
          isFromMe: true,
          status: MessageStatus.delivered,
        ),
      );

      connectionService.currentSessionId = 'ephemeral-key';
      connectionService.theirPersistentPublicKey = 'persistent-key';

      late ChatScreenController controller;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWithValue(connectionService),
            meshNetworkingServiceProvider.overrideWithValue(meshService),
            meshNetworkingControllerProvider.overrideWithValue(
              MeshNetworkingController(meshService),
            ),
            meshNetworkStatusProvider.overrideWith(
              (ref) => AsyncValue.data(
                MeshNetworkStatus(
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
                ),
              ),
            ),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(
                ConnectionInfo(
                  isConnected: true,
                  isReady: true,
                  statusMessage: 'ready',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _buildController(
                      ref: ref,
                      context: context,
                      config: ChatScreenConfig(
                        chatId: initialChatId,
                        contactName: 'Test',
                        contactPublicKey: 'ephemeral-key',
                      ),
                      messageRepository: fakeMessageRepo,
                      contactRepository: _FakeContactRepository(),
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await controller.handleIdentityReceived();
      });

      final expectedChatId = ChatUtils.generateChatId('persistent-key');
      expect(controller.chatId, expectedChatId);
      final migratedMessages = await fakeMessageRepo.getMessages(
        ChatId(expectedChatId),
      );
      expect(migratedMessages, isNotEmpty);
      final oldMessages = await fakeMessageRepo.getMessages(
        ChatId(initialChatId),
      );
      expect(oldMessages, isEmpty);
    });

    testWidgets('updates message status when delivery stream emits', (
      tester,
    ) async {
      final fakeMessageRepo = _FakeMessageRepository();
      await fakeMessageRepo.saveMessage(
        Message(
          id: MessageId('msg-1'),
          chatId: ChatId('chat-1'),
          content: 'pending',
          timestamp: DateTime.now(),
          isFromMe: true,
          status: MessageStatus.sending,
        ),
      );

      connectionService.currentSessionId = 'chat-1';

      late ChatScreenController controller;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWithValue(connectionService),
            meshNetworkingServiceProvider.overrideWithValue(meshService),
            meshNetworkingControllerProvider.overrideWithValue(
              MeshNetworkingController(meshService),
            ),
            meshNetworkStatusProvider.overrideWith(
              (ref) => AsyncValue.data(
                MeshNetworkStatus(
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
                ),
              ),
            ),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(
                ConnectionInfo(
                  isConnected: true,
                  isReady: true,
                  statusMessage: 'ready',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _buildController(
                      ref: ref,
                      context: context,
                      config: const ChatScreenConfig(
                        chatId: 'chat-1',
                        contactName: 'Test',
                        contactPublicKey: 'chat-1',
                      ),
                      messageRepository: fakeMessageRepo,
                      contactRepository: _FakeContactRepository(),
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await controller.initialize(logChatOpen: false);
        meshService.deliveryController.add('msg-1');
        await Future.delayed(const Duration(milliseconds: 20));
      });

      final updated = controller.state.messages
          .firstWhere((m) => m.id.value == 'msg-1')
          .status;
      expect(updated, MessageStatus.delivered);
    });

    testWidgets('retry orchestration updates failed messages', (tester) async {
      final fakeMessageRepo = _FakeMessageRepository();
      final failedMessage = Message(
        id: MessageId('failed-1'),
        chatId: ChatId('chat-1'),
        content: 'fail me',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.failed,
      );
      await fakeMessageRepo.saveMessage(failedMessage);

      connectionService.currentSessionId = 'chat-1';

      final retryStatus = MessageRetryStatus(
        repositoryFailedMessages: [failedMessage],
        queueFailedMessages: const [],
        totalFailed: 1,
      );
      final retryResult = MessageRetryResult(
        success: true,
        repositoryAttempted: 1,
        repositorySucceeded: 1,
        queueAttempted: 0,
        queueSucceeded: 0,
        message: 'delivered',
      );
      final fakeContactRepo = _FakeContactRepository();
      final repoProvider = _FakeRepositoryProvider(
        fakeContactRepo,
        fakeMessageRepo,
      );

      connectionService.emitConnectionInfo(
        const ConnectionInfo(
          isConnected: false,
          isReady: false,
          statusMessage: 'offline',
        ),
      );

      late ChatScreenController controller;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWithValue(connectionService),
            meshNetworkingServiceProvider.overrideWithValue(meshService),
            meshNetworkingControllerProvider.overrideWithValue(
              MeshNetworkingController(meshService),
            ),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(
                ConnectionInfo(
                  isConnected: true,
                  isReady: true,
                  statusMessage: 'ready',
                ),
              ),
            ),
            meshNetworkStatusProvider.overrideWith(
              (ref) => AsyncValue.data(
                MeshNetworkStatus(
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
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _buildController(
                      ref: ref,
                      context: context,
                      config: const ChatScreenConfig(
                        chatId: 'chat-1',
                        contactName: 'Test',
                        contactPublicKey: 'chat-1',
                      ),
                      messageRepository: fakeMessageRepo,
                      contactRepository: fakeContactRepo,
                      retryCoordinator: _FakeMessageRetryCoordinator(
                        status: retryStatus,
                        result: retryResult,
                        repositoryProvider: repoProvider,
                      ),
                      repositoryRetryHandler: (message) async {
                        final updated = message.copyWith(
                          status: MessageStatus.delivered,
                        );
                        await fakeMessageRepo.updateMessage(updated);
                        controller.applyMessageUpdate(updated);
                      },
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await controller.initialize(logChatOpen: false);
        await controller.retryFailedMessages();
      });

      final updated = controller.state.messages
          .firstWhere((m) => m.id.value == 'failed-1')
          .status;
      expect(updated, MessageStatus.delivered);
    });

    testWidgets('userRequestedPairing skips when disconnected', (tester) async {
      connectionService.currentSessionId = 'chat-1';
      final fakeMessageRepo = _FakeMessageRepository();
      final fakeContactRepo = _FakeContactRepository();
      final repoProvider = _FakeRepositoryProvider(
        fakeContactRepo,
        fakeMessageRepo,
      );

      connectionService.emitConnectionInfo(
        const ConnectionInfo(
          isConnected: false,
          isReady: false,
          statusMessage: 'offline',
        ),
      );

      late ChatScreenController controller;
      late _RecordingPairingController recorder;

      await tester.pumpWidget(
        MaterialApp(
          home: ProviderScope(
            overrides: [
              connectionServiceProvider.overrideWithValue(connectionService),
              meshNetworkingServiceProvider.overrideWithValue(meshService),
              meshNetworkingControllerProvider.overrideWithValue(
                MeshNetworkingController(meshService),
              ),
              connectionInfoProvider.overrideWith(
                (ref) => const AsyncValue.data(
                  ConnectionInfo(
                    isConnected: false,
                    isReady: false,
                    statusMessage: 'offline',
                  ),
                ),
              ),
              meshNetworkStatusProvider.overrideWith(
                (ref) => AsyncValue.data(_readyStatus),
              ),
            ],
            child: Builder(
              builder: (context) {
                recorder = _RecordingPairingController(
                  stateManager: BLEStateManager(),
                  connectionService: connectionService,
                  contactRepository: fakeContactRepo,
                  context: context,
                );
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _buildController(
                      ref: ref,
                      context: context,
                      config: const ChatScreenConfig(
                        chatId: 'chat-1',
                        contactName: 'Test',
                        contactPublicKey: 'chat-1',
                      ),
                      messageRepository: fakeMessageRepo,
                      contactRepository: fakeContactRepo,
                      pairingDialogController: recorder,
                      retryCoordinator: _FakeMessageRetryCoordinator(
                        status: MessageRetryStatus(
                          repositoryFailedMessages: const [],
                          queueFailedMessages: const [],
                          totalFailed: 0,
                        ),
                        result: MessageRetryResult(
                          success: true,
                          repositoryAttempted: 0,
                          repositorySucceeded: 0,
                          queueAttempted: 0,
                          queueSucceeded: 0,
                          message: 'none',
                        ),
                        repositoryProvider: repoProvider,
                      ),
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await controller.initialize(logChatOpen: false);
        await controller.userRequestedPairing();
      });

      expect(recorder.pairingRequested, isFalse);
    });

    testWidgets('pairing and asymmetric handlers delegate to controller', (
      tester,
    ) async {
      connectionService.currentSessionId = 'chat-1';
      final fakeMessageRepo = _FakeMessageRepository();
      final fakeContactRepo = _FakeContactRepository();
      final sharedStateManager = BLEStateManager();
      final repoProvider = _FakeRepositoryProvider(
        fakeContactRepo,
        fakeMessageRepo,
      );

      connectionService.emitConnectionInfo(
        const ConnectionInfo(
          isConnected: true,
          isReady: true,
          statusMessage: 'ready',
        ),
      );

      late ChatScreenController controller;
      late _RecordingPairingController recorder;

      await tester.pumpWidget(
        MaterialApp(
          home: ProviderScope(
            overrides: [
              connectionServiceProvider.overrideWithValue(connectionService),
              meshNetworkingServiceProvider.overrideWithValue(meshService),
              meshNetworkingControllerProvider.overrideWithValue(
                MeshNetworkingController(meshService),
              ),
              connectionInfoProvider.overrideWith(
                (ref) => const AsyncValue.data(
                  ConnectionInfo(
                    isConnected: true,
                    isReady: true,
                    statusMessage: 'ready',
                  ),
                ),
              ),
              meshNetworkStatusProvider.overrideWith(
                (ref) => AsyncValue.data(_readyStatus),
              ),
            ],
            child: Builder(
              builder: (context) {
                recorder = _RecordingPairingController(
                  stateManager: sharedStateManager,
                  connectionService: connectionService,
                  contactRepository: fakeContactRepo,
                  context: context,
                );
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _buildController(
                      ref: ref,
                      context: context,
                      config: const ChatScreenConfig(
                        chatId: 'chat-1',
                        contactName: 'Test',
                        contactPublicKey: 'chat-1',
                      ),
                      messageRepository: fakeMessageRepo,
                      contactRepository: fakeContactRepo,
                      pairingDialogController: recorder,
                      retryCoordinator: _FakeMessageRetryCoordinator(
                        status: MessageRetryStatus(
                          repositoryFailedMessages: const [],
                          queueFailedMessages: const [],
                          totalFailed: 0,
                        ),
                        result: MessageRetryResult(
                          success: true,
                          repositoryAttempted: 0,
                          repositorySucceeded: 0,
                          queueAttempted: 0,
                          queueSucceeded: 0,
                          message: 'none',
                        ),
                        repositoryProvider: repoProvider,
                      ),
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await controller.initialize(logChatOpen: false);
        await controller.userRequestedPairing();
        await controller.handleAsymmetricContact('pk', 'name');
      });

      expect(recorder.pairingRequested, isTrue);
      expect(recorder.asymmetricHandled, isTrue);
      expect(
        controller.pairingDialogController.stateManager,
        same(sharedStateManager),
      );
      controller.dispose();
      expect(recorder.cleared, isTrue);
    });

    testWidgets('initialize starts lifecycle listeners and retry helper', (
      tester,
    ) async {
      connectionService.currentSessionId = 'chat-1';
      late ChatScreenController controller;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWithValue(connectionService),
            meshNetworkingServiceProvider.overrideWithValue(meshService),
            meshNetworkingControllerProvider.overrideWithValue(
              MeshNetworkingController(meshService),
            ),
            meshNetworkStatusProvider.overrideWith(
              (ref) => AsyncValue.data(_readyStatus),
            ),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(
                ConnectionInfo(
                  isConnected: true,
                  isReady: true,
                  statusMessage: 'ready',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _buildController(
                      ref: ref,
                      context: context,
                      config: const ChatScreenConfig(
                        chatId: 'chat-1',
                        contactName: 'Test',
                        contactPublicKey: 'chat-1',
                      ),
                      messageRepository: _FakeMessageRepository(),
                      contactRepository: _FakeContactRepository(),
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await controller.initialize(logChatOpen: false);
      });

      expect(controller.sessionLifecycle.messageListenerActive, isTrue);
      expect(controller.sessionLifecycle.retryHelper, isNotNull);
    });

    testWidgets('connection change activates listener after offline init', (
      tester,
    ) async {
      connectionService.currentSessionId = 'chat-1';
      late ChatScreenController controller;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWithValue(connectionService),
            meshNetworkingServiceProvider.overrideWithValue(meshService),
            meshNetworkingControllerProvider.overrideWithValue(
              MeshNetworkingController(meshService),
            ),
            meshNetworkStatusProvider.overrideWith(
              (ref) => AsyncValue.data(_readyStatus),
            ),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(
                ConnectionInfo(
                  isConnected: false,
                  isReady: false,
                  statusMessage: 'offline',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _buildController(
                      ref: ref,
                      context: context,
                      config: const ChatScreenConfig(
                        chatId: 'chat-1',
                        contactName: 'Test',
                        contactPublicKey: 'chat-1',
                      ),
                      messageRepository: _FakeMessageRepository(),
                      contactRepository: _FakeContactRepository(),
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await controller.initialize(logChatOpen: false);
        expect(controller.sessionLifecycle.messageListenerActive, isFalse);
        controller.handleConnectionChange(
          const ConnectionInfo(
            isConnected: false,
            isReady: false,
            statusMessage: 'offline',
          ),
          const ConnectionInfo(
            isConnected: true,
            isReady: true,
            statusMessage: 'ready',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });

      expect(controller.sessionLifecycle.messageListenerActive, isTrue);
    });
  });
}

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
            connectionService,
            contactRepo,
            navigator,
            stateManager,
            onCompleted,
            onError,
            onSuccess,
          ) => ChatPairingDialogController(
            stateManager: stateManager,
            connectionService: connectionService,
            contactRepository: contactRepo,
            context: ctx,
            navigator: navigator,
            getTheirPersistentKey: () =>
                connectionService.theirPersistentPublicKey,
            onPairingCompleted: onCompleted,
            onPairingError: onError,
            onPairingSuccess: onSuccess,
          ),
      sessionViewModelFactory:
          ({
            required ChatScreenConfig config,
            required MessageRepository messageRepository,
            required ContactRepository contactRepository,
            required ChatsRepository chatsRepository,
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
            required MessageRepository messageRepository,
            MessageRetryCoordinator? retryCoordinator,
            OfflineMessageQueue? offlineQueue,
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
      if (value.length < before) {
        removed = true;
      }
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
      final migratedMessages = messages
          .map((m) => m.copyWith(chatId: newChatId))
          .toList();
      _store[newChatId.value] = migratedMessages;
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
  Contact? contact;

  @override
  Future<Contact?> getContact(String publicKey) async => contact;
}

class _FakeChatsRepository extends ChatsRepository {
  final Map<String, ChatListItem> _chats = {};

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    return _chats.values.toList();
  }

  @override
  Future<void> markChatAsRead(ChatId chatId) async {
    final existing = _chats[chatId.value];
    if (existing != null) {
      _chats[chatId.value] = ChatListItem(
        chatId: existing.chatId,
        contactName: existing.contactName,
        contactPublicKey: existing.contactPublicKey,
        lastMessage: existing.lastMessage,
        lastMessageTime: existing.lastMessageTime,
        unreadCount: 0,
        isOnline: existing.isOnline,
        hasUnsentMessages: existing.hasUnsentMessages,
        lastSeen: existing.lastSeen,
      );
    }
  }

  @override
  Future<void> incrementUnreadCount(ChatId chatId) async {
    final existing =
        _chats[chatId.value] ??
        ChatListItem(
          chatId: chatId,
          contactName: 'Test',
          unreadCount: 0,
          isOnline: false,
          hasUnsentMessages: false,
        );
    _chats[chatId.value] = ChatListItem(
      chatId: existing.chatId,
      contactName: existing.contactName,
      contactPublicKey: existing.contactPublicKey,
      lastMessage: existing.lastMessage,
      lastMessageTime: existing.lastMessageTime,
      unreadCount: existing.unreadCount + 1,
      isOnline: existing.isOnline,
      hasUnsentMessages: existing.hasUnsentMessages,
      lastSeen: existing.lastSeen,
    );
  }
}

class _FakeMeshNetworkingService implements IMeshNetworkingService {
  final StreamController<MeshNetworkStatus> statusController =
      StreamController<MeshNetworkStatus>.broadcast();
  final StreamController<String> deliveryController =
      StreamController<String>.broadcast();
  List<QueuedMessage> queuedMessages = [];

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
    return MeshSendResult.direct('msg');
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
      queuedMessages.where((message) => message.chatId == chatId).toList();

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

class _FakeMessageRetryCoordinator extends MessageRetryCoordinator {
  final MessageRetryStatus status;
  final MessageRetryResult result;

  _FakeMessageRetryCoordinator({
    required this.status,
    required this.result,
    required IRepositoryProvider repositoryProvider,
  }) : super(
         offlineQueue: _FakeOfflineMessageQueue(),
         repositoryProvider: repositoryProvider,
       );

  @override
  Future<MessageRetryStatus> getFailedMessageStatus(ChatId chatId) async {
    return status;
  }

  @override
  Future<MessageRetryResult> retryAllFailedMessages({
    required ChatId chatId,
    required Future<void> Function(Message message) onRepositoryMessageRetry,
    required Future<void> Function(QueuedMessage message) onQueueMessageRetry,
    bool allowPartialConnection = true,
  }) async {
    for (final message in status.repositoryFailedMessages) {
      await onRepositoryMessageRetry(message);
    }
    return result;
  }
}

class _FakeOfflineMessageQueue extends OfflineMessageQueue {}

class _FakeRepositoryProvider implements IRepositoryProvider {
  _FakeRepositoryProvider(this.contactRepository, this.messageRepository);

  @override
  final _FakeContactRepository contactRepository;

  @override
  final _FakeMessageRepository messageRepository;
}

class _RecordingPairingController extends ChatPairingDialogController {
  bool pairingRequested = false;
  bool asymmetricHandled = false;
  bool cleared = false;

  _RecordingPairingController({
    required BLEStateManager stateManager,
    required IConnectionService connectionService,
    required ContactRepository contactRepository,
    required BuildContext context,
  }) : super(
         stateManager: stateManager,
         connectionService: connectionService,
         contactRepository: contactRepository,
         context: context,
         navigator: Navigator.of(context),
         getTheirPersistentKey: () =>
             connectionService.theirPersistentPublicKey,
       );

  @override
  Future<bool> userRequestedPairing() async {
    pairingRequested = true;
    return true;
  }

  @override
  Future<void> handleAsymmetricContact(
    String publicKey,
    String displayName,
  ) async {
    asymmetricHandled = true;
  }

  @override
  Future<void> addAsVerifiedContact(
    String publicKey,
    String displayName,
  ) async {
    asymmetricHandled = true;
  }

  @override
  void clear() {
    cleared = true;
  }
}

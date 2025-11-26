import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:logging/logging.dart';
import '../../core/app_core.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/models/connection_info.dart';
import '../../core/messaging/message_router.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/security/message_security.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../core/services/persistent_chat_state_manager.dart';
import '../../core/services/security_manager.dart';
import '../../core/utils/chat_utils.dart';
import '../../core/utils/string_extensions.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/services/ble_state_manager.dart';
import '../../domain/entities/message.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/services/notification_service.dart';
import '../models/chat_screen_config.dart';
import '../../presentation/controllers/chat_pairing_dialog_controller.dart';
import '../../presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import '../../presentation/controllers/chat_search_controller.dart';
import '../../presentation/controllers/chat_session_lifecycle.dart';
import '../../presentation/models/chat_ui_state.dart';
import '../../presentation/providers/ble_providers.dart';
import '../../presentation/providers/chat_messaging_view_model.dart';
import '../../presentation/providers/mesh_networking_provider.dart';
import '../../presentation/providers/security_state_provider.dart';
import '../providers/chat_session_providers.dart';
import '../viewmodels/chat_session_view_model.dart';
import '../notifiers/chat_session_state_notifier.dart';
import '../widgets/chat_search_bar.dart' show SearchResult;
import 'chat_retry_helper.dart';

class ChatScreenControllerArgs {
  const ChatScreenControllerArgs({
    required this.ref,
    required this.context,
    required this.config,
    this.messageRepository,
    this.contactRepository,
    this.chatsRepository,
    this.persistentChatManager,
    this.retryCoordinator,
    this.messagingViewModel,
    this.repositoryRetryHandler,
    this.pairingDialogController,
    this.messageRouter,
  });

  final WidgetRef ref;
  final BuildContext context;
  final ChatScreenConfig config;
  final MessageRepository? messageRepository;
  final ContactRepository? contactRepository;
  final ChatsRepository? chatsRepository;
  final PersistentChatStateManager? persistentChatManager;
  final MessageRetryCoordinator? retryCoordinator;
  final ChatMessagingViewModel? messagingViewModel;
  final Future<void> Function(Message message)? repositoryRetryHandler;
  final ChatPairingDialogController? pairingDialogController;
  final MessageRouter? messageRouter;
}

/// Coordinates all non-UI chat behaviors so the widget can stay lean.
class ChatScreenController extends ChangeNotifier {
  final ChatScreenControllerArgs _args;
  final _logger = Logger('ChatScreenController');
  final WidgetRef ref;
  final BuildContext context;
  final ChatScreenConfig config;
  final MessageRepository messageRepository;
  final ContactRepository contactRepository;
  final ChatsRepository chatsRepository;
  late final Future<void> Function(Message message) _repositoryRetryHandler;
  final MessageRouter? _injectedMessageRouter;
  final ChatPairingDialogController? _injectedPairingController;
  final MessageRetryCoordinator? _initialRetryCoordinator;

  late ChatMessagingViewModel _messagingViewModel;
  late chat_controller.ChatScrollingController _scrollingController;
  late ChatSearchController _searchController;
  late ChatPairingDialogController _pairingDialogController;
  late ChatSessionViewModel _sessionViewModel;
  late ChatSessionLifecycle _sessionLifecycle;
  late ChatRetryHelper _retryHelper;
  PersistentChatStateManager? _persistentChatManager;
  late final ChatSessionStateStore _stateStore;

  bool _initialized = false;

  // Primary source of truth for controller state (legacy path).
  // Also published to provider for opt-in migration path.
  ChatUIState _state = const ChatUIState();
  String _chatId = '';
  String? _cachedContactPublicKey;
  bool _disposed = false;
  bool _messageListenerActive = false;
  OfflineMessageQueue? _fallbackOfflineQueue;
  bool _fallbackQueueInitialized = false;
  Future<void>? _fallbackQueueInitFuture;
  void Function(ChatUIState)? _stateListener;
  void Function()? _disposeStateListener;

  ChatScreenController(ChatScreenControllerArgs args)
    : _args = args,
      ref = args.ref,
      context = args.context,
      config = args.config,
      messageRepository = args.messageRepository ?? MessageRepository(),
      contactRepository = args.contactRepository ?? ContactRepository(),
      chatsRepository = args.chatsRepository ?? ChatsRepository(),
      _persistentChatManager = args.persistentChatManager,
      _injectedMessageRouter = args.messageRouter,
      _injectedPairingController = args.pairingDialogController,
      _initialRetryCoordinator = args.retryCoordinator {
    _repositoryRetryHandler =
        args.repositoryRetryHandler ?? _retryRepositoryMessage;
    _chatId = _calculateInitialChatId();
    _cachedContactPublicKey = _contactPublicKey;
    _stateStore = ref.read(chatSessionStateStoreProvider(_args).notifier);
    _state = _stateStore.current;
    _stateListener = (newState) {
      if (_disposed) return;
      _state = newState;
      _publishStateToOwnedNotifier(newState);
      notifyListeners();
    };
    _disposeStateListener = _stateStore.addListener(
      _stateListener!,
      fireImmediately: false,
    );
    _initializeControllers(messagingViewModel: args.messagingViewModel);
    _sessionViewModel.bindStateStore(_stateStore);
    _retryHelper = ChatRetryHelper(
      ref: ref,
      config: config,
      chatId: () => _chatId,
      contactPublicKey: () => _contactPublicKey,
      displayContactName: () => displayContactName,
      messageRepository: messageRepository,
      repositoryRetryHandler: _repositoryRetryHandler,
      showSuccess: _showSuccess,
      showError: _showError,
      showInfo: _showInfo,
      scrollToBottom: scrollToBottom,
      getMessages: () => state.messages,
      logger: _logger,
      initialCoordinator: args.retryCoordinator,
      offlineQueueResolver: _resolveOfflineQueue,
    );
    _sessionLifecycle.retryHelper = _retryHelper;
    _publishInitialState();
  }

  ChatUIState get state => _state;
  String get chatId => _chatId;
  chat_controller.ChatScrollingController get scrollingController =>
      _scrollingController;
  ChatSearchController get searchController => _searchController;
  ChatPairingDialogController get pairingDialogController =>
      _pairingDialogController;
  ChatSessionViewModel get sessionViewModel => _sessionViewModel;
  ChatSessionLifecycle get sessionLifecycle => _sessionLifecycle;
  ChatScreenControllerArgs get args => _args;

  /// Legacy-style constructor kept for compatibility in tests and widgets that
  /// still pass named parameters directly.
  @visibleForTesting
  ChatScreenController.deprecated({
    required WidgetRef ref,
    required BuildContext context,
    required ChatScreenConfig config,
    MessageRepository? messageRepository,
    ContactRepository? contactRepository,
    ChatsRepository? chatsRepository,
    PersistentChatStateManager? persistentChatManager,
    MessageRetryCoordinator? retryCoordinator,
    ChatMessagingViewModel? messagingViewModel,
    Future<void> Function(Message message)? repositoryRetryHandler,
    ChatPairingDialogController? pairingDialogController,
    MessageRouter? messageRouter,
  }) : this(
         ChatScreenControllerArgs(
           ref: ref,
           context: context,
           config: config,
           messageRepository: messageRepository,
           contactRepository: contactRepository,
           chatsRepository: chatsRepository,
           persistentChatManager: persistentChatManager,
           retryCoordinator: retryCoordinator,
           messagingViewModel: messagingViewModel,
           repositoryRetryHandler: repositoryRetryHandler,
           pairingDialogController: pairingDialogController,
           messageRouter: messageRouter,
         ),
       );

  String get displayContactName {
    if (config.isRepositoryMode) {
      return config.contactName ?? 'Unknown';
    }

    final connectionService = ref.read(connectionServiceProvider);
    final connectionInfo = connectionService.currentConnectionInfo;
    if (connectionInfo.otherUserName != null &&
        connectionInfo.otherUserName!.isNotEmpty) {
      return connectionInfo.otherUserName!;
    }

    if (config.isCentralMode && config.device != null) {
      return config.device!.uuid.toString().shortId(8);
    }
    if (config.isPeripheralMode && config.central != null) {
      return config.central!.uuid.toString().shortId(8);
    }
    return 'Unknown';
  }

  String? get securityStateKey {
    final publicKey = config.contactPublicKey ?? _contactPublicKey;
    if (publicKey != null && publicKey.isNotEmpty) {
      return 'repo_$publicKey';
    }

    return ref.read(connectionServiceProvider).currentSessionId;
  }

  String? get _contactPublicKey {
    if (config.contactPublicKey != null &&
        config.contactPublicKey!.isNotEmpty) {
      return config.contactPublicKey;
    }

    final connectionService = ref.read(connectionServiceProvider);
    final currentKey = connectionService.currentSessionId;
    if (currentKey != null && currentKey.isNotEmpty) {
      _cachedContactPublicKey = currentKey;
      return currentKey;
    }

    return _cachedContactPublicKey;
  }

  void _initializeControllers({ChatMessagingViewModel? messagingViewModel}) {
    _messagingViewModel =
        messagingViewModel ??
        ChatMessagingViewModel(
          chatId: _chatId,
          contactPublicKey: _contactPublicKey ?? '',
          messageRepository: messageRepository,
          contactRepository: contactRepository,
        );

    _scrollingController = chat_controller.ChatScrollingController(
      chatsRepository: chatsRepository,
      chatId: _chatId,
      onScrollToBottom: () => _stateStore.clearNewWhileScrolledUp(),
      onUnreadCountChanged: (count) => _stateStore.setUnreadCount(count),
      onStateChanged: _syncScrollState,
    );

    _searchController = ChatSearchController(
      onSearchModeToggled: (isSearchMode) =>
          _stateStore.setSearchMode(isSearchMode),
      onSearchResultsChanged: _onSearch,
      onNavigateToResult: _navigateToSearchResult,
      scrollController: _scrollingController.scrollController,
    );

    final connectionService = ref.read(connectionServiceProvider);
    _pairingDialogController =
        _injectedPairingController ??
        ChatPairingDialogController(
          stateManager: _resolvePairingStateManager(connectionService),
          connectionService: connectionService,
          contactRepository: contactRepository,
          context: context,
          navigator: Navigator.of(context),
          getTheirPersistentKey: () =>
              connectionService.theirPersistentPublicKey,
          onPairingCompleted: (success) {
            if (success && securityStateKey != null) {
              ref.invalidate(securityStateProvider(securityStateKey));
            }
          },
          onPairingError: _showError,
          onPairingSuccess: _showSuccess,
        );

    _sessionViewModel = ChatSessionViewModel(
      config: config,
      messageRepository: messageRepository,
      contactRepository: contactRepository,
      chatsRepository: chatsRepository,
      messagingViewModel: _messagingViewModel,
      scrollingController: _scrollingController,
      searchController: _searchController,
      pairingDialogController: _pairingDialogController,
      retryCoordinator: _initialRetryCoordinator,
    );

    _sessionLifecycle = ChatSessionLifecycle(
      viewModel: _sessionViewModel,
      connectionService: connectionService,
      meshService: ref.read(meshNetworkingServiceProvider),
      messageRouter: _resolveMessageRouter(connectionService),
      messageSecurity: MessageSecurity(),
      messageRepository: messageRepository,
      retryCoordinator: _initialRetryCoordinator,
      offlineQueue: _resolveOfflineQueue(),
      notificationService: NotificationService(),
      logger: _logger,
    );
    _sessionLifecycle.pairingController = _pairingDialogController;
  }

  MessageRouter? _resolveMessageRouter(IConnectionService connectionService) {
    if (_injectedMessageRouter != null) {
      return _injectedMessageRouter;
    }

    try {
      return MessageRouter.instance;
    } on StateError {
      _logger.warning(
        'MessageRouter not initialized; attempting on-demand initialization',
      );
      try {
        final fallbackQueue = _resolveOfflineQueue();
        unawaited(
          MessageRouter.initialize(
            connectionService,
            offlineQueue: fallbackQueue,
            fallbackQueueBuilder: _buildFallbackOfflineQueue,
          ),
        );
        return MessageRouter.instance;
      } catch (error, stack) {
        _logger.warning(
          'MessageRouter initialization failed; routing hooks disabled: $error',
          stack,
        );
        if (AppCore.instance.isInitialized) {
          _logger.warning(
            'AppCore initialized but MessageRouter still unavailable',
          );
        }
        return null;
      }
    }
  }

  OfflineMessageQueue? _resolveOfflineQueue() {
    final appCoreQueue = _tryResolveAppCoreQueue();
    if (appCoreQueue != null) {
      return appCoreQueue;
    }

    try {
      return MessageRouter.instance.offlineQueue;
    } catch (_) {}

    _logger.fine('Using standalone OfflineMessageQueue fallback');
    return _getFallbackQueue();
  }

  OfflineMessageQueue? _tryResolveAppCoreQueue() {
    final appCore = AppCore.instance;
    if (!appCore.isInitialized && !appCore.isInitializing) {
      _logger.fine('AppCore not initialized; offline queue unavailable');
      return null;
    }

    try {
      return appCore.messageQueue;
    } catch (error) {
      _logger.warning('Failed to access offline queue: $error');
      return null;
    }
  }

  Future<OfflineMessageQueue> _buildFallbackOfflineQueue() async {
    final queue = _getFallbackQueue(ensureInitialized: true);
    if (_fallbackQueueInitFuture != null) {
      try {
        await _fallbackQueueInitFuture;
      } catch (error, stack) {
        _logger.warning(
          'Fallback offline queue initialization failed: $error',
          stack,
        );
      }
    }
    return queue;
  }

  OfflineMessageQueue _getFallbackQueue({bool ensureInitialized = false}) {
    _fallbackOfflineQueue ??= OfflineMessageQueue();
    if (_fallbackQueueInitFuture == null && !_fallbackQueueInitialized) {
      _fallbackQueueInitialized = true;
      _fallbackQueueInitFuture = _fallbackOfflineQueue!.initialize();
      if (!ensureInitialized) {
        _fallbackQueueInitFuture!.catchError((error, stack) {
          _logger.warning(
            'Fallback offline queue initialization failed: $error',
            stack,
          );
        });
      }
    } else if (ensureInitialized && _fallbackQueueInitFuture == null) {
      _fallbackQueueInitFuture = _fallbackOfflineQueue!.initialize();
    }
    return _fallbackOfflineQueue!;
  }

  BLEStateManager _resolvePairingStateManager(
    IConnectionService connectionService,
  ) {
    if (_injectedPairingController != null) {
      return _injectedPairingController!.stateManager;
    }

    try {
      final dynamic maybeWithManager = connectionService;
      final manager = maybeWithManager.stateManager;
      if (manager is BLEStateManager) {
        return manager;
      }
    } catch (_) {
      // Fall back below when the connection service doesn't expose stateManager.
    }

    _logger.warning(
      'BLEStateManager not exposed by connection service; using fallback instance',
    );
    return BLEStateManager();
  }

  Future<void> initialize({bool logChatOpen = true}) async {
    if (_disposed || _initialized) return;
    if (logChatOpen) {
      await _logChatOpenState();
    }
    await _loadMessages();
    _setupPersistentChatManager();
    _checkAndSetupLiveMessaging();
    _setupMeshNetworking();
    _setupDeliveryListener();
    _sessionLifecycle.ensureRetryCoordinator();
    _setupSecurityStateListener();
    _initialized = true;
  }

  /// Publishes state to both local controller and provider-owned notifier.
  void publishState(ChatUIState newState) {
    if (_disposed) return;
    _stateStore.replace(newState);
  }

  void _publishStateToOwnedNotifier(ChatUIState newState) {
    if (_disposed) return;
    // Publish state for provider consumers.
    final ownedState = ref.read(
      chatSessionOwnedStateNotifierProvider(_args).notifier,
    );
    ownedState.replace(newState);
  }

  void _publishInitialState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _stateListener?.call(_stateStore.current);
    });
  }

  void _syncScrollState() {
    _stateStore.update(
      (state) => state.copyWith(
        unreadMessageCount: _scrollingController.unreadMessageCount,
        newMessagesWhileScrolledUp:
            _scrollingController.newMessagesWhileScrolledUp,
        showUnreadSeparator: _scrollingController.showUnreadSeparator,
      ),
    );
  }

  Future<void> _logChatOpenState() async {
    final publicKey = config.contactPublicKey ?? _chatId;
    if (publicKey == null) {
      _logger.warning('Chat open with no public key available');
      return;
    }

    final contact = await contactRepository.getContact(publicKey);
    final securityLevel = await SecurityManager.instance.getCurrentLevel(
      publicKey,
      contactRepository,
    );
    final encryptionMethod = await SecurityManager.instance.getEncryptionMethod(
      publicKey,
      contactRepository,
    );

    _logger.info(
      'Chat open: ${config.contactName ?? "Unknown"} | Security=${securityLevel.name} | Encryption=${encryptionMethod.type.name}',
    );
    final pkDisp = publicKey.length > 16
        ? '${publicKey.shortId()}...'
        : publicKey;
    final eph = contact?.currentEphemeralId;
    final ephDisp = eph != null
        ? (eph.length > 16 ? '${eph.shortId()}...' : eph)
        : 'NULL';
    final sid = contact?.sessionIdForNoise;
    final sidDisp = sid != null
        ? (sid.length > 16 ? '${sid.shortId()}...' : sid)
        : 'NULL';
    _logger.info(
      'Keys: PubKey=$pkDisp | CurrentEphemeralID=$ephDisp | NoiseSession=$sidDisp',
    );
  }

  void _checkAndSetupLiveMessaging() {
    final connectionInfo = ref.read(connectionInfoProvider).value;
    if (connectionInfo?.isConnected == true) {
      _setupMessageListener();
      _setupContactRequestListener();
    }
  }

  void _setupMeshNetworking() {
    try {
      final meshStatusAsync = ref.read(meshNetworkStatusProvider);
      _sessionLifecycle.handleMeshStatus(
        statusAsync: meshStatusAsync,
        isCurrentlyInitializing: _stateStore.current.meshInitializing,
        updateState: _stateStore.update,
        onSuccessMessage: _showSuccess,
        onWarningMessage: (msg) => _logger.warning(msg),
      );
      meshStatusAsync.when(
        data: (status) {
          if (!status.isInitialized) {
            _sessionLifecycle.startInitializationTimeout(
              isCheckingStatus: false,
              disposed: () => _disposed,
              stillInitializing: () => _stateStore.current.meshInitializing,
              updateState: _stateStore.update,
              onSuccessMessage: _showSuccess,
            );
          }
        },
        loading: () {
          _sessionLifecycle.startInitializationTimeout(
            isCheckingStatus: true,
            disposed: () => _disposed,
            stillInitializing: () => _stateStore.current.meshInitializing,
            updateState: _stateStore.update,
            onSuccessMessage: _showSuccess,
          );
        },
        error: (error, stack) {},
      );
    } catch (e) {
      _logger.warning('Failed to set up mesh networking: $e');
      _stateStore.setMeshState(
        meshInitializing: false,
        initializationStatus: 'Failed to initialize',
      );
    }
  }

  void _setupDeliveryListener() {
    _sessionLifecycle.setupDeliveryListener(
      onDelivered: (messageId) =>
          _updateMessageStatus(messageId, MessageStatus.delivered),
    );
  }

  void _updateMessageStatus(String messageId, MessageStatus newStatus) {
    _stateStore.updateMessageStatus(messageId, newStatus);
  }

  @visibleForTesting
  void applyMessageUpdate(Message updatedMessage) {
    _stateStore.updateMessage(updatedMessage);
  }

  void handleMeshInitializationStatusChange(
    AsyncValue<MeshNetworkStatus>? previous,
    AsyncValue<MeshNetworkStatus> next,
  ) {
    if (_disposed) return;
    _sessionLifecycle.handleMeshStatus(
      statusAsync: next,
      isCurrentlyInitializing: _stateStore.current.meshInitializing,
      updateState: _stateStore.update,
      onSuccessMessage: _showSuccess,
    );
  }

  void _setupSecurityStateListener() {
    final connectionService = ref.read(connectionServiceProvider);
    connectionService.setContactRequestCompletedListener((success) {
      if (success && securityStateKey != null) {
        ref.invalidate(securityStateProvider(securityStateKey));
      }
    });
  }

  Future<void> userRequestedPairing() async {
    final connectionService = ref.read(connectionServiceProvider);
    final connectionInfoAsync = ref.read(connectionInfoProvider);
    final connectionInfo =
        connectionInfoAsync.value ?? connectionService.currentConnectionInfo;

    await _sessionLifecycle.requestPairing(
      connectionInfo: connectionInfo,
      onErrorMessage: _showError,
    );
  }

  Future<void> _manualReconnection() => _sessionLifecycle.manualReconnection(
    disposed: () => _disposed,
    onSuccessMessage: _showSuccess,
    onErrorMessage: _showError,
  );

  bool _hasMessagesQueuedForRelay() {
    return _sessionLifecycle.hasMessagesQueuedForRelay(_contactPublicKey);
  }

  Future<void> _loadMessages() async {
    try {
      final meshService = ref.read(meshNetworkingServiceProvider);
      final allMessages = await _messagingViewModel.loadMessages(
        onLoadingStateChanged: (isLoading) {
          _stateStore.setLoading(isLoading);
        },
        onGetQueuedMessages: () =>
            meshService.getQueuedMessagesForChat(_chatId),
        onScrollToBottom: scrollToBottom,
        onError: _showError,
      );

      _stateStore.setMessages(allMessages);

      if (config.isRepositoryMode) {
        await _scrollingController.syncUnreadCount(messages: allMessages);
        _syncScrollState();
      }

      await _processBufferedMessages();

      _sessionLifecycle.scheduleAutoRetry(
        delay: const Duration(milliseconds: 1000),
        disposed: () => _disposed,
        onRetry: () async {
          _sessionLifecycle.ensureRetryCoordinator();
          await _sessionLifecycle.autoRetryFailedMessages();
        },
      );
    } catch (e) {
      _logger.severe('Error in loadMessages: $e');
      _showError('Failed to load messages: $e');
      _stateStore.setLoading(false);
    }
  }

  Future<void> _autoRetryFailedMessages() =>
      _sessionLifecycle.autoRetryFailedMessages();

  Future<void> _retryRepositoryMessage(Message message) async {
    try {
      final retryMessage = message.copyWith(status: MessageStatus.sending);
      await messageRepository.updateMessage(retryMessage);
      _stateStore.updateMessage(retryMessage);

      bool success = false;
      final connectionInfo = ref.read(connectionInfoProvider).value;
      final isConnected = connectionInfo?.isConnected ?? false;
      final isReady = connectionInfo?.isReady ?? false;

      try {
        final router = MessageRouter.instance;
        final result = await router.sendMessage(
          content: message.content,
          recipientId: _contactPublicKey ?? _chatId,
          messageId: message.id,
          recipientName: displayContactName,
        );

        success = result.isSentDirectly;

        if (result.isQueued) {
          _showInfo('Message queued - will send when peer comes online');
        }
      } catch (e) {
        if (isConnected && isReady) {
          final connectionService = ref.read(connectionServiceProvider);

          if (config.isCentralMode) {
            success = await connectionService.sendMessage(
              message.content,
              messageId: message.id,
            );
          } else {
            success = await connectionService.sendPeripheralMessage(
              message.content,
              messageId: message.id,
            );
          }
        }
      }

      if (!success && _contactPublicKey != null) {
        try {
          final meshController = ref.read(meshNetworkingControllerProvider);
          final meshResult = await meshController.sendMeshMessage(
            content: message.content,
            recipientPublicKey: _contactPublicKey!,
          );

          if (meshResult.isSuccess) {
            success = true;
          }
        } catch (_) {}
      }

      final newStatus = success
          ? MessageStatus.delivered
          : MessageStatus.failed;
      final updatedMessage = retryMessage.copyWith(status: newStatus);
      await messageRepository.updateMessage(updatedMessage);
      _stateStore.updateMessage(updatedMessage);
    } catch (e) {
      final failedAgain = message.copyWith(status: MessageStatus.failed);
      await messageRepository.updateMessage(failedAgain);
      _stateStore.updateMessage(failedAgain);
      rethrow;
    }
  }

  Future<void> _fallbackRetryFailedMessages() =>
      _sessionLifecycle.fallbackRetryFailedMessages();

  void _setupPersistentChatManager() {
    _persistentChatManager ??= ref.read(persistentChatStateManagerProvider);
    _sessionLifecycle.persistentChatManager = _persistentChatManager;
    _sessionLifecycle.registerPersistentListener(
      chatId: _chatId,
      incomingStream: () =>
          ref.read(connectionServiceProvider).receivedMessages,
      onMessage: _addReceivedMessage,
    );
  }

  void _handlePersistentMessage(String content) async {
    await _addReceivedMessage(content);
  }

  void _activateMessageListener() {
    if (_sessionLifecycle.messageListenerActive || _messageListenerActive) {
      return;
    }
    _sessionLifecycle.messageListenerActive = true;
    _messageListenerActive = true;
    final connectionService = ref.read(connectionServiceProvider);

    if (_persistentChatManager != null &&
        !_persistentChatManager!.hasActiveListener(_chatId)) {
      _sessionLifecycle.registerPersistentListener(
        chatId: _chatId,
        incomingStream: () => connectionService.receivedMessages,
        onMessage: _addReceivedMessage,
      );
    } else if (_persistentChatManager != null &&
        _persistentChatManager!.hasActiveListener(_chatId)) {
      return;
    } else {
      _sessionLifecycle.attachMessageStream(
        stream: connectionService.receivedMessages,
        disposed: () => _disposed,
        isActive: () => _sessionLifecycle.messageListenerActive,
        onMessage: (content) async {
          _sessionLifecycle.messageBuffer.add(content);
          await _processBufferedMessages();
        },
      );
    }
  }

  void _setupMessageListener() {
    _activateMessageListener();
  }

  Future<void> _addReceivedMessage(String content) async {
    final senderPublicKey = _contactPublicKey ?? _chatId;
    final secureMessageId = await MessageSecurity.generateSecureMessageId(
      senderPublicKey: senderPublicKey,
      content: content,
    );

    final existingMessage = await messageRepository.getMessageById(
      secureMessageId,
    );
    if (existingMessage != null) {
      final inUiList = state.messages.any((m) => m.id == secureMessageId);
      if (!inUiList) {
        _stateStore.appendMessage(existingMessage);
        scrollToBottom();
      }
      return;
    }

    final message = Message(
      id: secureMessageId,
      chatId: _chatId,
      content: content,
      timestamp: DateTime.now(),
      isFromMe: false,
      status: MessageStatus.delivered,
    );

    await messageRepository.saveMessage(message);

    try {
      await NotificationService.showMessageNotification(
        message: message,
        contactName: displayContactName,
        contactAvatar: null,
      );
    } catch (e, stackTrace) {
      _logger.severe('Failed to show notification: $e', e, stackTrace);
    }

    final shouldAutoScroll = _scrollingController.shouldAutoScrollOnIncoming;

    if (!shouldAutoScroll) {
      await _scrollingController.handleIncomingWhileScrolledAway();
    }

    _stateStore.appendMessage(message);

    if (shouldAutoScroll) {
      scrollToBottom();
      _scrollingController.scheduleMarkAsRead();
    }
  }

  Future<void> _processBufferedMessages() async {
    await _sessionLifecycle.processBufferedMessages(_addReceivedMessage);
  }

  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) return;
    try {
      await _messagingViewModel.sendMessage(
        content: content,
        onMessageAdded: (message) {
          _stateStore.appendMessage(message);
        },
        onShowSuccess: _showSuccess,
        onShowError: _showError,
        onScrollToBottom: scrollToBottom,
      );
    } catch (e) {
      _logger.severe('Unexpected error in sendMessage: $e');
    }
  }

  Future<void> deleteMessage(String messageId, bool deleteForEveryone) async {
    try {
      await _messagingViewModel.deleteMessage(
        messageId: messageId,
        deleteForEveryone: deleteForEveryone,
        onMessageRemoved: (id) {
          _stateStore.removeMessage(id);
        },
        onShowSuccess: _showSuccess,
        onShowError: _showError,
      );
    } catch (e) {
      _logger.severe('Unexpected error in deleteMessage: $e');
    }
  }

  void scrollToBottom() {
    _scrollingController.scrollToBottom();
  }

  String _calculateInitialChatId() {
    if (config.isRepositoryMode) {
      return config.chatId!;
    }

    final connectionService = ref.read(connectionServiceProvider);
    final otherPersistentId = connectionService.currentSessionId;

    if (otherPersistentId != null) {
      return ChatUtils.generateChatId(otherPersistentId);
    }

    final deviceId = config.isCentralMode
        ? config.device!.uuid.toString()
        : config.central!.uuid.toString();

    return 'temp_${deviceId.shortId(8)}';
  }

  Future<void> handleIdentityReceived() async {
    final connectionService = ref.read(connectionServiceProvider);
    final otherPersistentId = connectionService.theirPersistentPublicKey;
    if (otherPersistentId == null) return;

    final newChatId = ChatUtils.generateChatId(otherPersistentId);
    if (newChatId == _chatId) return;

    final oldChatId = _chatId;
    final messagesToMigrate = await messageRepository.getMessages(oldChatId);
    if (messagesToMigrate.isNotEmpty) {
      await _migrateMessages(oldChatId, newChatId);
    }
    _chatId = newChatId;
    _cachedContactPublicKey = otherPersistentId;
    _messagingViewModel = ChatMessagingViewModel(
      chatId: _chatId,
      contactPublicKey: otherPersistentId,
      messageRepository: messageRepository,
      contactRepository: contactRepository,
    );

    // Defer disposing the old scroll/search controllers until after the next
    // frame so the ListView has detached from the old ScrollController. This
    // avoids "ScrollController was disposed with one or more ScrollPositions
    // attached" when identity swap happens mid-frame.
    final oldScrollingController = _scrollingController;
    final oldSearchController = _searchController;

    _scrollingController = chat_controller.ChatScrollingController(
      chatsRepository: chatsRepository,
      chatId: _chatId,
      onScrollToBottom: () => _stateStore.clearNewWhileScrolledUp(),
      onUnreadCountChanged: (count) => _stateStore.setUnreadCount(count),
      onStateChanged: _syncScrollState,
    );

    _searchController = ChatSearchController(
      onSearchModeToggled: (isSearchMode) =>
          _stateStore.setSearchMode(isSearchMode),
      onSearchResultsChanged: _onSearch,
      onNavigateToResult: _navigateToSearchResult,
      scrollController: _scrollingController.scrollController,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      oldSearchController.clear();
      oldScrollingController.dispose();
    });

    _persistentChatManager?.unregisterChatScreen(oldChatId);
    _persistentChatManager?.registerChatScreen(
      _chatId,
      _handlePersistentMessage,
    );

    _stateStore.setMessages([]);
    await _loadMessages();
  }

  Future<void> _migrateMessages(String oldChatId, String newChatId) async {
    final oldMessages = await messageRepository.getMessages(oldChatId);

    for (final message in oldMessages) {
      final migratedMessage = Message(
        id: message.id,
        chatId: newChatId,
        content: message.content,
        timestamp: message.timestamp,
        isFromMe: message.isFromMe,
        status: message.status,
      );
      await messageRepository.saveMessage(migratedMessage);
    }

    await messageRepository.clearMessages(oldChatId);
    _logger.info(
      'Migrated ${oldMessages.length} messages from $oldChatId to $newChatId',
    );
  }

  void handleConnectionChange(
    ConnectionInfo? previous,
    ConnectionInfo? current,
  ) {
    _sessionLifecycle.handleConnectionChange(
      previous: previous,
      current: current,
      disposed: () => _disposed,
      onIdentityReceived: handleIdentityReceived,
      onSuccessMessage: _showSuccess,
      onErrorMessage: _showError,
      contactPublicKey: _contactPublicKey ?? _chatId,
      onInfoMessage: _showInfo,
    );
  }

  void _setupContactRequestListener() {
    final connectionService = ref.read(connectionServiceProvider);

    connectionService.setContactRequestCompletedListener((success) {
      if (success && securityStateKey != null) {
        ref.invalidate(securityStateProvider(securityStateKey));
      }
    });

    connectionService.setContactRequestReceivedListener((
      publicKey,
      displayName,
    ) {
      if (!context.mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Contact Request'),
          content: Text(
            '$displayName wants to add you as a trusted contact. This enables enhanced encryption.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                connectionService.rejectContactRequest();
                Navigator.pop(dialogContext);
              },
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await connectionService.acceptContactRequest();
              },
              child: const Text('Accept'),
            ),
          ],
        ),
      );
    });

    connectionService.setAsymmetricContactListener((publicKey, displayName) {
      handleAsymmetricContact(publicKey, displayName);
    });
  }

  Future<void> handleAsymmetricContact(
    String publicKey,
    String displayName,
  ) async {
    await _sessionLifecycle.handleAsymmetricContact(publicKey, displayName);
  }

  Future<void> addAsVerifiedContact(String publicKey, String displayName) =>
      _sessionLifecycle.addAsVerifiedContact(publicKey, displayName);

  void toggleSearchMode() {
    _sessionViewModel.toggleSearchMode();
  }

  void _onSearch(String query, List<SearchResult> results) {
    _sessionViewModel.updateSearchQuery(query);
  }

  void _navigateToSearchResult(int messageIndex) {
    _sessionViewModel.navigateToSearchResult(
      messageIndex,
      state.messages.length,
    );
  }

  Future<void> manualReconnection() => _manualReconnection();

  Future<void> retryFailedMessages() => _autoRetryFailedMessages();

  void _showError(String message) {
    _logger.warning('Error: $message');
  }

  void _showInfo(String message) {
    _logger.info('Info: $message');
  }

  void _showSuccess(String message) {
    _logger.info('Success: $message');
  }

  @override
  void dispose() {
    _disposed = true;
    _disposeStateListener?.call();
    _sessionLifecycle.unregisterPersistentListener(_chatId);
    _sessionLifecycle.messageListenerActive = false;
    _messageListenerActive = false;
    _scrollingController.dispose();
    _messagingViewModel.dispose();
    _searchController.clear();
    _pairingDialogController.clear();
    _sessionLifecycle.dispose();
    super.dispose();
  }
}

final chatScreenControllerProvider = ChangeNotifierProvider.autoDispose
    .family<ChatScreenController, ChatScreenControllerArgs>((ref, args) {
      final controller = ChatScreenController(args);
      unawaited(controller.initialize());
      return controller;
    });

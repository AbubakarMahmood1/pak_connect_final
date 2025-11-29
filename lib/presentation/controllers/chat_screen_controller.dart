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
import 'package:pak_connect/domain/values/id_types.dart';
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
    _repositoryRetryHandler =
        _args.repositoryRetryHandler ??
        _sessionViewModel.retryRepositoryMessage;
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
      scrollToBottom: _sessionViewModel.scrollToBottom,
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
      onStateChanged: () => _sessionViewModel.onScrollStateChanged(),
    );

    _searchController = ChatSearchController(
      onSearchModeToggled: (isSearchMode) =>
          _stateStore.setSearchMode(isSearchMode),
      onSearchResultsChanged: (query, _) =>
          _sessionViewModel.onSearchResultsChanged(query),
      onNavigateToResult: (messageIndex) =>
          _sessionViewModel.onNavigateToSearchResultIndex(messageIndex),
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
      // Phase 6A: Wire up callbacks for extracted methods
      sessionLifecycle: null, // Will be set after creation
      displayContactNameFn: () => displayContactName,
      getContactPublicKeyFn: () => _contactPublicKey,
      getChatIdFn: () => _chatId,
      onChatIdUpdated: (newChatId) => _chatId = newChatId,
      onContactPublicKeyUpdated: (newKey) => _cachedContactPublicKey = newKey,
      onScrollToBottom: () => _scrollingController.scrollToBottom(),
      onShowError: _showError,
      onShowSuccess: _showSuccess,
      onShowInfo: _showInfo,
      isDisposedFn: () => _disposed,
      onControllersRebound:
          ({
            required messagingViewModel,
            required scrollingController,
            required searchController,
            ChatMessagingViewModel? previousMessagingViewModel,
            chat_controller.ChatScrollingController?
            previousScrollingController,
            ChatSearchController? previousSearchController,
          }) => _handleControllersRebound(
            messagingViewModel: messagingViewModel,
            scrollingController: scrollingController,
            searchController: searchController,
            previousMessagingViewModel: previousMessagingViewModel,
            previousScrollingController: previousScrollingController,
            previousSearchController: previousSearchController,
          ),
      // Phase 6B: Wire up callbacks for message listener management
      getConnectionServiceFn: () => ref.read(connectionServiceProvider),
      getPersistentChatManagerFn: () => _persistentChatManager,
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
    // Phase 6A: Set lifecycle reference on ViewModel after creation
    _sessionViewModel.sessionLifecycle = _sessionLifecycle;
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
    _setupContactRequestHandling();
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

  void _handleControllersRebound({
    required ChatMessagingViewModel messagingViewModel,
    required chat_controller.ChatScrollingController scrollingController,
    required ChatSearchController searchController,
    ChatMessagingViewModel? previousMessagingViewModel,
    chat_controller.ChatScrollingController? previousScrollingController,
    ChatSearchController? previousSearchController,
  }) {
    final scrollChanged =
        previousScrollingController != null &&
        previousScrollingController != scrollingController;
    final searchChanged =
        previousSearchController != null &&
        previousSearchController != searchController;
    final messagingChanged =
        previousMessagingViewModel != null &&
        previousMessagingViewModel != messagingViewModel;

    _messagingViewModel = messagingViewModel;
    _scrollingController = scrollingController;
    _searchController = searchController;

    if (!scrollChanged && !searchChanged && !messagingChanged) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      if (searchChanged) {
        previousSearchController!.clear();
      }
      if (scrollChanged) {
        previousScrollingController!.dispose();
      }
      if (messagingChanged) {
        previousMessagingViewModel!.dispose();
      }
    });
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
    // Phase 6A: Delegate to ViewModel
    final currentState = _stateStore.current;
    final newState = _sessionViewModel.applyMessageStatus(
      currentState,
      messageId,
      newStatus,
    );
    _stateStore.setMessages(newState.messages);
  }

  @visibleForTesting
  void applyMessageUpdate(Message updatedMessage) {
    // Phase 6A: Delegate to ViewModel
    final currentState = _stateStore.current;
    final newState = _sessionViewModel.applyMessageUpdate(
      currentState,
      updatedMessage,
    );
    _stateStore.setMessages(newState.messages);
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

  void _setupContactRequestHandling() {
    _sessionLifecycle.setupContactRequestHandling(
      context: context,
      mounted: () => context.mounted,
      onSecurityStateInvalidate: () {
        final key = securityStateKey;
        if (key != null) {
          ref.invalidate(securityStateProvider(key));
        }
      },
    );
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
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.loadMessages();
  }

  Future<void> _autoRetryFailedMessages() async {
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.autoRetryFailedMessages();
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
    // Phase 6B: Delegate to ViewModel
    unawaited(_sessionViewModel.activateMessageListener());
  }

  void _setupMessageListener() {
    _activateMessageListener();
  }

  Future<void> _addReceivedMessage(String content) async {
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.addReceivedMessage(content);
  }

  Future<void> _processBufferedMessages() async {
    // Phase 6B: Delegate to ViewModel
    await _sessionViewModel.processBufferedMessages();
  }

  Future<void> sendMessage(String content) async {
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.sendMessage(content);
  }

  Future<void> deleteMessage(
    MessageId messageId,
    bool deleteForEveryone,
  ) async {
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.deleteMessage(messageId, deleteForEveryone);
  }

  String _calculateInitialChatId() {
    // Fallback calculation that does not depend on ViewModel initialization
    if (config.isRepositoryMode && config.chatId != null) {
      return config.chatId!;
    }

    final explicitKey = config.contactPublicKey;
    if (explicitKey != null && explicitKey.isNotEmpty) {
      return ChatUtils.generateChatId(explicitKey);
    }

    final connectionService = ref.read(connectionServiceProvider);
    final sessionId = connectionService.currentSessionId;
    if (sessionId != null && sessionId.isNotEmpty) {
      return ChatUtils.generateChatId(sessionId);
    }

    // Last resort: empty string (will be set once identity is resolved)
    return '';
  }

  Future<void> handleIdentityReceived() async {
    await _sessionViewModel.handleIdentityReceived();
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

  Future<void> handleAsymmetricContact(
    String publicKey,
    String displayName,
  ) async {
    await _sessionLifecycle.handleAsymmetricContact(publicKey, displayName);
  }

  Future<void> addAsVerifiedContact(String publicKey, String displayName) =>
      _sessionLifecycle.addAsVerifiedContact(publicKey, displayName);

  Future<void> manualReconnection() => _manualReconnection();

  Future<void> retryFailedMessages() {
    // Phase 6A: Delegate to ViewModel
    return _sessionViewModel.retryFailedMessages();
  }

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

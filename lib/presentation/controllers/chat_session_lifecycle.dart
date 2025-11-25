import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/app_core.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/interfaces/i_mesh_networking_service.dart';
import '../../core/messaging/message_router.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/security/message_security.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../core/services/persistent_chat_state_manager.dart';
import '../../data/repositories/message_repository.dart';
import '../../domain/entities/message.dart';
import '../../domain/services/notification_service.dart';
import '../../domain/models/mesh_network_models.dart';
import '../controllers/chat_retry_helper.dart';
import '../models/chat_ui_state.dart';
import '../viewmodels/chat_session_view_model.dart';

/// Planned lifecycle manager for ChatScreen orchestration.
/// Responsible for subscriptions, buffering, retry coordination, pairing hooks,
/// and persistence once migration moves logic out of ChatScreenController.
class ChatSessionLifecycle {
  ChatSessionLifecycle({
    required this.viewModel,
    required this.connectionService,
    required this.meshService,
    required this.messageRouter,
    required this.messageSecurity,
    required this.messageRepository,
    this.retryCoordinator,
    this.offlineQueue,
    this.notificationService,
    Logger? logger,
  }) : _logger = logger ?? Logger('ChatSessionLifecycle');

  final ChatSessionViewModel viewModel;
  final IConnectionService connectionService;
  final IMeshNetworkingService meshService;
  final MessageRouter messageRouter;
  final MessageSecurity messageSecurity;
  final MessageRepository messageRepository;
  final MessageRetryCoordinator? retryCoordinator;
  final OfflineMessageQueue? offlineQueue;
  final NotificationService? notificationService;
  final Logger _logger;
  ChatRetryHelper? retryHelper;

  final List<StreamSubscription<dynamic>> _managedSubscriptions = [];
  StreamSubscription<String>? _deliverySubscription;
  StreamSubscription<dynamic>? _messageSubscription;
  bool messageListenerActive = false;
  final List<String> messageBuffer = [];
  Timer? _initializationTimeoutTimer;
  Timer? _delayedRetryTimer;
  PersistentChatStateManager? persistentChatManager;

  /// Placeholder init hook; real logic will move here during migration.
  Future<void> initialize() async {
    _logger.fine('ChatSessionLifecycle initialize (scaffold)');
  }

  /// Placeholder send hook; will orchestrate routing and retry later.
  Future<void> onSend(Message message) async {
    _logger.fine('ChatSessionLifecycle onSend (scaffold) for ${message.id}');
  }

  /// Subscribe to mesh delivery stream and notify caller on delivery.
  void setupDeliveryListener({
    required void Function(String messageId) onDelivered,
  }) {
    try {
      _deliverySubscription = meshService.messageDeliveryStream.listen(
        onDelivered,
      );
      _managedSubscriptions.add(_deliverySubscription!);
    } catch (e) {
      _logger.warning('Failed to set up delivery listener: $e');
    }
  }

  /// Track subscriptions that should be cancelled with the lifecycle.
  void trackSubscription(StreamSubscription<dynamic> subscription) {
    _managedSubscriptions.add(subscription);
  }

  /// Activate the message listener with buffering semantics.
  void activateMessageListener(Stream<String> messageStream) {
    if (messageListenerActive) return;
    messageListenerActive = true;
    _messageSubscription = messageStream.listen((content) {
      if (messageListenerActive) {
        messageBuffer.add(content);
      }
    });
    _managedSubscriptions.add(_messageSubscription!);
  }

  /// Attach a direct message stream with buffering when disposed.
  void attachMessageStream({
    required Stream<String> stream,
    required bool Function() disposed,
    required bool Function() isActive,
    required Future<void> Function(String content) onMessage,
  }) {
    _messageSubscription = stream.listen((content) {
      if (!disposed() && isActive()) {
        unawaited(onMessage(content));
      } else if (disposed()) {
        messageBuffer.add(content);
      }
    });
    _managedSubscriptions.add(_messageSubscription!);
  }

  /// Flush buffered messages through the provided handler.
  Future<void> processBufferedMessages(
    Future<void> Function(String content) onMessage,
  ) async {
    if (messageBuffer.isEmpty) return;
    final buffered = List<String>.from(messageBuffer);
    messageBuffer.clear();
    for (final content in buffered) {
      await onMessage(content);
    }
  }

  /// Handle mesh initialization status updates and banner timeout.
  void handleMeshStatus({
    required AsyncValue<MeshNetworkStatus> statusAsync,
    required bool isCurrentlyInitializing,
    required void Function(ChatUIState Function(ChatUIState)) updateState,
    required void Function(String) onSuccessMessage,
    void Function(String message)? onWarningMessage,
  }) {
    statusAsync.when(
      data: (status) {
        if (status.isInitialized && isCurrentlyInitializing) {
          _initializationTimeoutTimer?.cancel();
          updateState(
            (state) => viewModel.applyMeshState(
              state,
              meshInitializing: false,
              initializationStatus: 'Ready',
            ),
          );
          onSuccessMessage('Mesh networking ready');
        } else if (!status.isInitialized && !isCurrentlyInitializing) {
          updateState(
            (state) =>
                viewModel.applyInitializationStatus(state, 'Initializing...'),
          );
        }
      },
      loading: () {
        if (!isCurrentlyInitializing) {
          updateState(
            (state) => viewModel.applyMeshState(
              state,
              meshInitializing: true,
              initializationStatus: 'Initializing mesh network...',
            ),
          );
        }
      },
      error: (error, stack) {
        updateState(
          (state) => viewModel.applyMeshState(
            state,
            meshInitializing: false,
            initializationStatus: 'Initialization failed',
          ),
        );
        _logger.severe('Mesh initialization error: $error');
        onWarningMessage?.call('Mesh status error - skipping banner: $error');
      },
    );
  }

  /// Start a mesh initialization timeout with fallback messaging.
  void startInitializationTimeout({
    required bool isCheckingStatus,
    required bool Function() disposed,
    required bool Function() stillInitializing,
    required void Function(ChatUIState Function(ChatUIState)) updateState,
    required void Function(String) onSuccessMessage,
  }) {
    _initializationTimeoutTimer?.cancel();
    final timeoutDuration = isCheckingStatus
        ? const Duration(seconds: 3)
        : const Duration(seconds: 15);

    _initializationTimeoutTimer = Timer(timeoutDuration, () {
      if (disposed() || !stillInitializing()) return;
      _logger.info('Mesh initialization timeout reached - hiding banner');
      updateState(
        (state) => viewModel.applyMeshState(
          state,
          meshInitializing: false,
          initializationStatus: 'Ready (timeout fallback)',
        ),
      );
      onSuccessMessage('Mesh networking ready (fallback mode)');
    });
  }

  /// Placeholder dispose hook; will close subscriptions after migration.
  void dispose() {
    _deliverySubscription?.cancel();
    _messageSubscription?.cancel();
    _initializationTimeoutTimer?.cancel();
    _delayedRetryTimer?.cancel();
    retryHelper?.dispose();
    for (final sub in _managedSubscriptions) {
      sub.cancel();
    }
    _managedSubscriptions.clear();
  }

  /// Schedule an auto-retry after a delay, respecting disposal.
  void scheduleAutoRetry({
    required Duration delay,
    required bool Function() disposed,
    required Future<void> Function() onRetry,
  }) {
    _delayedRetryTimer?.cancel();
    _delayedRetryTimer = Timer(delay, () {
      if (disposed()) return;
      unawaited(onRetry());
    });
  }

  Future<void> autoRetryFailedMessages() async {
    if (retryHelper == null) return;
    await retryHelper!.autoRetryFailedMessages();
  }

  Future<void> fallbackRetryFailedMessages() async {
    if (retryHelper == null) return;
    await retryHelper!.fallbackRetryFailedMessages();
  }

  void ensureRetryCoordinator() {
    retryHelper?.ensureRetryCoordinator();
  }

  /// Register persistent chat listener when available.
  void registerPersistentListener({
    required String chatId,
    required Stream<String> Function() incomingStream,
    required Future<void> Function(String content) onMessage,
  }) {
    persistentChatManager ??= PersistentChatStateManager();
    persistentChatManager?.registerChatScreen(chatId, (content) {
      unawaited(onMessage(content));
    });
    persistentChatManager?.setupPersistentListener(chatId, incomingStream());
  }

  void unregisterPersistentListener(String chatId) {
    persistentChatManager ??= PersistentChatStateManager();
    persistentChatManager?.unregisterChatScreen(chatId);
  }
}

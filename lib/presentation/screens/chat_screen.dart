import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import '../../domain/models/connection_info.dart';
import '../../domain/models/security_state.dart';
import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/interfaces/i_contact_repository.dart';
import '../../domain/interfaces/i_message_repository.dart';
import '../../domain/services/message_retry_coordinator.dart';
import '../../domain/services/media_send_handler.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../controllers/chat_pairing_dialog_controller.dart';
import '../controllers/chat_scrolling_controller.dart' as chat_controller;
import '../controllers/chat_search_controller.dart';
import '../controllers/chat_session_lifecycle.dart';
import '../controllers/chat_screen_controller.dart';
import '../models/chat_screen_config.dart';
import '../models/chat_ui_state.dart';
import '../providers/chat_messaging_view_model.dart';
import '../providers/ble_providers.dart';
import '../providers/mesh_networking_provider.dart';
import '../providers/security_state_provider.dart';
import '../providers/chat_session_providers.dart';
import '../viewmodels/chat_session_view_model.dart';
import '../widgets/chat_screen_helpers.dart';
import '../widgets/chat_binary_widgets.dart';
import '../widgets/chat_screen_sections.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/utils/chat_utils.dart';
import '../../domain/services/mesh_networking_service.dart'
    show ReceivedBinaryEvent;

class ChatScreen extends ConsumerStatefulWidget {
  final Peripheral? device; // For central mode (live connection)
  final Central? central; // For peripheral mode (live connection)
  final String? chatId; // For repository mode (stored data)
  final String? contactName; // Contact display name
  final String? contactPublicKey; // Contact public key

  const ChatScreen({
    super.key,
    this.device,
    this.central,
    this.chatId,
    this.contactName,
    this.contactPublicKey,
  }) : assert(
         (device != null || central != null) ||
             (chatId != null && contactName != null),
         'Either live connection (device/central) OR chat data (chatId/contactName) must be provided',
       );

  const ChatScreen.fromChatData({
    super.key,
    required this.chatId,
    required this.contactName,
    required this.contactPublicKey,
  }) : device = null,
       central = null;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final TextEditingController _messageController;
  late final ChatScreenControllerArgs _controllerArgs;
  ProviderSubscription<AsyncValue<ReceivedBinaryEvent>>?
  _binaryPayloadSubscription;
  ProviderSubscription<AsyncValue<ConnectionInfo>>? _connectionSubscription;
  ProviderSubscription<AsyncValue<MeshNetworkStatus>>? _meshSubscription;
  bool get _isRepositoryMode => widget.chatId != null;
  bool get _isPeripheralMode => widget.central != null;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
    final messageRepository = _resolveMessageRepository();
    final contactRepository = _resolveContactRepository();
    final chatsRepository = _resolveChatsRepository();
    _controllerArgs = ChatScreenControllerArgs(
      ref: ref,
      context: context,
      config: ChatScreenConfig(
        device: widget.device,
        central: widget.central,
        chatId: widget.chatId,
        contactName: widget.contactName,
        contactPublicKey: widget.contactPublicKey,
      ),
      messageRepository: messageRepository,
      contactRepository: contactRepository,
      chatsRepository: chatsRepository,
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
                chatsRepository: chatsRepository,
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
            onSearchResultsChanged: onSearchResultsChanged,
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
            required config,
            required messageRepository,
            required contactRepository,
            required chatsRepository,
            required messagingViewModel,
            required scrollingController,
            required searchController,
            required pairingDialogController,
            MessageRetryCoordinator? retryCoordinator,
            sessionLifecycle,
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
            required viewModel,
            required connectionService,
            required meshService,
            messageRouter,
            required messageSecurity,
            required messageRepository,
            retryCoordinator,
            offlineQueue,
            logger,
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
    );
    _binaryPayloadSubscription = ref
        .listenManual<AsyncValue<ReceivedBinaryEvent>>(
          binaryPayloadStreamProvider,
          (previous, next) {
            next.whenData((event) async {
              if (!_isRelevantBinary(event)) return;
              await _refreshMessagesFromRepo();
            });
          },
        );
    _connectionSubscription = ref.listenManual<AsyncValue<ConnectionInfo>>(
      connectionInfoProvider,
      (previous, next) {
        final actions = ref
            .read(chatSessionHandleProvider(_controllerArgs))
            .actions;
        actions.handleConnectionChange(previous?.value, next.value);
      },
    );
    _meshSubscription = ref.listenManual<AsyncValue<MeshNetworkStatus>>(
      meshNetworkStatusProvider,
      (previous, next) {
        final actions = ref
            .read(chatSessionHandleProvider(_controllerArgs))
            .actions;
        actions.handleMeshInitializationStatusChange(previous, next);
      },
    );
  }

  IMessageRepository _resolveMessageRepository() {
    final di = GetIt.instance;
    if (di.isRegistered<IMessageRepository>()) {
      return di<IMessageRepository>();
    }
    throw StateError(
      'IMessageRepository is not registered. '
      'Call setupServiceLocator() before opening ChatScreen.',
    );
  }

  IContactRepository _resolveContactRepository() {
    final di = GetIt.instance;
    if (di.isRegistered<IContactRepository>()) {
      return di<IContactRepository>();
    }
    throw StateError(
      'IContactRepository is not registered. '
      'Call setupServiceLocator() before opening ChatScreen.',
    );
  }

  IChatsRepository _resolveChatsRepository() {
    final di = GetIt.instance;
    if (di.isRegistered<IChatsRepository>()) {
      return di<IChatsRepository>();
    }
    throw StateError(
      'IChatsRepository is not registered. '
      'Call setupServiceLocator() before opening ChatScreen.',
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _binaryPayloadSubscription?.close();
    _connectionSubscription?.close();
    _meshSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep state store alive while the screen is mounted.
    ref.watch(chatSessionStateStoreProvider(_controllerArgs));
    final controller = ref.watch(chatScreenControllerProvider(_controllerArgs));
    final sessionHandle = ref.watch(chatSessionHandleProvider(_controllerArgs));
    final sessionActions = sessionHandle.actions;
    final ChatUIState uiState = sessionHandle.state;
    final searchController = sessionHandle.viewModel.searchController;
    final scrollingController = sessionHandle.viewModel.scrollingController;

    final connectionInfo = ref.watch(connectionInfoProvider).value;

    final securityStateAsync = ref.watch(
      securityStateProvider(controller.securityStateKey),
    );

    final bleService = ref.watch(connectionServiceProvider);

    final actuallyConnected = connectionInfo?.isConnected ?? false;
    final messages = uiState.messages;
    final binaryInbox = ref.watch(binaryPayloadInboxProvider);
    final pendingTransfers = ref.watch(pendingBinaryTransfersProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isRepositoryMode
                  ? '${widget.contactName}'
                  : (connectionInfo?.otherUserName ??
                        'Device ${controller.displayContactName}'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            securityStateAsync.when(
              data: (securityState) => Text(
                _buildStatusText(connectionInfo, securityState),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _getStatusColor(securityState),
                ),
              ),
              loading: () => Text(
                'Loading...',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              error: (error, stack) => Text(
                'Error',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.red),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              searchController.isSearchMode ? Icons.close : Icons.search,
            ),
            onPressed: _toggleSearchMode,
            tooltip: searchController.isSearchMode
                ? 'Exit search'
                : 'Search messages',
          ),
          securityStateAsync.when(
            data: (securityState) => _buildSingleActionButton(securityState),
            loading: () => const SizedBox.shrink(),
            error: (error, stack) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: SafeArea(
        bottom: true,
        child: Column(
          children: [
            if (!actuallyConnected || bleService.isActivelyReconnecting)
              ReconnectionBanner(
                bleService: bleService,
                isPeripheralMode: _isPeripheralMode,
                onReconnect: () {
                  _manualReconnect();
                },
              ),
            if (uiState.meshInitializing)
              InitializationStatusPanel(
                statusText: uiState.initializationStatus,
              ),
            if (pendingTransfers.isNotEmpty)
              PendingBinaryBanner(
                transfers: pendingTransfers,
                onRetryNow: () async {
                  final service = ref.read(meshNetworkingServiceProvider);
                  for (final t in pendingTransfers) {
                    await service.retryBinaryMedia(
                      transferId: t.transferId,
                      recipientId: t.recipientId,
                      originalType: t.originalType,
                    );
                  }
                  setState(() {});
                },
              ),
            if (binaryInbox.isNotEmpty)
              BinaryInboxList(
                inbox: binaryInbox,
                onDismiss: (id) => ref
                    .read(binaryPayloadInboxProvider.notifier)
                    .clearPayload(id),
              ),
            ChatMessagesSection(
              uiState: uiState,
              messages: messages,
              searchController: searchController,
              scrollingController: scrollingController,
              onToggleSearchMode: _toggleSearchMode,
              onRetryFailedMessages: sessionActions.retryFailedMessages,
              retryHandlerFor: _retryHandlerFor,
              onDeleteMessage: _deleteMessage,
            ),
            ChatComposer(
              messageController: _messageController,
              hintText: _getMessageHintText(connectionInfo),
              canSendImage: actuallyConnected,
              onPickImage: _pickAndSendImage,
              onSendMessage: _sendMessage,
            ),
          ],
        ),
      ),
      floatingActionButton:
          scrollingController.shouldShowScrollDownButton(messages.length)
          ? ChatScrollDownFab(
              newMessagesWhileScrolledUp: uiState.newMessagesWhileScrolledUp,
              onPressed: () {
                sessionActions.scrollToBottom();
                scrollingController.scheduleMarkAsRead();
              },
            )
          : null,
    );
  }

  String _buildStatusText(
    ConnectionInfo? connectionInfo,
    SecurityState securityState,
  ) {
    final parts = <String>[];

    if (!_isRepositoryMode && connectionInfo != null) {
      if (connectionInfo.isConnected && connectionInfo.isReady) {
        parts.add('Connected');
      } else if (connectionInfo.isConnected && !connectionInfo.isReady) {
        parts.add('Connecting');
      } else if (connectionInfo.isReconnecting) {
        parts.add('Reconnecting');
      } else {
        parts.add('Offline');
      }
    }

    switch (securityState.status) {
      case SecurityStatus.verifiedContact:
        parts.add('ECDH Encrypted');
        break;
      case SecurityStatus.paired:
        parts.add('Paired');
        break;
      case SecurityStatus.asymmetricContact:
        parts.add('Contact Sync Needed');
        break;
      case SecurityStatus.needsPairing:
        parts.add('Basic Encryption');
        break;
      default:
        parts.add('Disconnected');
    }

    return parts.join(' • ');
  }

  Color _getStatusColor(SecurityState securityState) {
    switch (securityState.status) {
      case SecurityStatus.verifiedContact:
        return Colors.green;
      case SecurityStatus.paired:
        return Colors.blue;
      case SecurityStatus.asymmetricContact:
        return Colors.orange;
      case SecurityStatus.needsPairing:
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Widget _buildSingleActionButton(SecurityState securityState) {
    if (securityState.showPairingButton) {
      return IconButton(
        icon: const Icon(Icons.lock_open),
        onPressed: () {
          ref
              .read(chatSessionHandleProvider(_controllerArgs))
              .actions
              .requestPairing();
        },
        tooltip: 'Secure Chat',
      );
    } else if (securityState.showContactAddButton) {
      return IconButton(
        icon: const Icon(Icons.person_add),
        onPressed: () {
          ref
              .read(chatSessionHandleProvider(_controllerArgs))
              .actions
              .requestPairing();
        },
        tooltip: 'Add Contact',
      );
    } else if (securityState.showContactSyncButton) {
      return IconButton(
        icon: const Icon(Icons.sync),
        onPressed: () {
          final handle = ref
              .read(chatSessionHandleProvider(_controllerArgs))
              .actions
              .handleAsymmetricContact;
          handle(
            securityState.otherPublicKey ?? '',
            securityState.otherUserName ?? 'Unknown',
          );
        },
        tooltip: 'Sync Contact',
      );
    }
    return const SizedBox.shrink();
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    ref
        .read(chatSessionHandleProvider(_controllerArgs))
        .actions
        .sendMessage(text);
  }

  /// Pick and send an image using ImagePicker and MediaSendHandler
  Future<void> _pickAndSendImage() async {
    try {
      // Pick image with quality/size constraints
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920, // Limit resolution to save bandwidth
        maxHeight: 1080,
        imageQuality: 85, // Compress at picker level (0-100)
      );

      if (image == null) return; // User cancelled

      // Get recipient ID (follow identity resolution invariant)
      final meshService = ref.read(meshNetworkingServiceProvider);
      final connection = ref.read(connectionServiceProvider);
      final recipientId =
          widget.contactPublicKey ??
          connection.theirPersistentPublicKey ??
          connection.currentSessionId;

      if (recipientId == null || recipientId.isEmpty) {
        // CRITICAL: Check if widget still mounted before showing UI
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot send: recipient unknown'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Show sending indicator
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Sending image...'),
            ],
          ),
          duration: Duration(seconds: 2),
        ),
      );

      // Create handler and send (use XFile.mimeType for reliable type detection)
      final handler = MediaSendHandler(
        meshService: meshService,
        hasEstablishedNoiseSession:
            SecurityServiceLocator.instance.hasEstablishedNoiseSession,
      );
      await handler.sendImage(
        file: File(image.path),
        recipientId: recipientId,
        knownMimeType: image.mimeType,
      );

      // Success - dismiss loading and show success
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 12),
              Text('Image queued for sending'),
            ],
          ),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } on MediaSendException catch (e) {
      // Handle known media send errors
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text(e.message)),
            ],
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      // Handle unexpected errors
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text('Failed to send image: $e')),
            ],
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  VoidCallback? _retryHandlerFor(Message message) {
    if (message is! EnhancedMessage) return null;
    if (!message.isFromMe) return null;
    if (message.attachments.isEmpty) return null;
    final transferId = message.attachments.first.id;
    if (transferId.isEmpty) return null;
    return () => _retryBinaryTransfer(transferId);
  }

  Future<void> _retryBinaryTransfer(String transferId) async {
    final svc = ref.read(meshNetworkingServiceProvider);
    final connection = ref.read(connectionServiceProvider);
    final recipientId =
        widget.contactPublicKey ??
        connection.theirPersistentPublicKey ??
        connection.currentSessionId;
    if (recipientId == null || recipientId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Missing recipient for retry')),
        );
      }
      return;
    }
    final ok = await svc.retryBinaryMedia(
      transferId: transferId,
      recipientId: recipientId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Retry scheduled' : 'Retry failed'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  bool _isRelevantBinary(ReceivedBinaryEvent event) {
    final contactKey = widget.contactPublicKey;
    if (contactKey != null && contactKey.isNotEmpty) {
      if (event.senderNodeId == contactKey) return true;
      if (event.recipient == contactKey) return true;
    }

    final targetChatId =
        widget.chatId ??
        (contactKey != null && contactKey.isNotEmpty
            ? ChatUtils.generateChatId(contactKey)
            : null);

    if (targetChatId != null) {
      final senderChat =
          (event.senderNodeId != null && event.senderNodeId!.isNotEmpty)
          ? ChatUtils.generateChatId(event.senderNodeId!)
          : null;
      final recipientChat =
          (event.recipient != null && event.recipient!.isNotEmpty)
          ? ChatUtils.generateChatId(event.recipient!)
          : null;
      if (senderChat == targetChatId || recipientChat == targetChatId) {
        return true;
      }
    }

    return false;
  }

  Future<void> _refreshMessagesFromRepo() async {
    final targetChatId =
        widget.chatId ??
        (widget.contactPublicKey != null && widget.contactPublicKey!.isNotEmpty
            ? ChatUtils.generateChatId(widget.contactPublicKey!)
            : null);
    if (targetChatId == null) return;

    final messages = await _controllerArgs.messageRepository.getMessages(
      ChatId(targetChatId),
    );
    final notifier = ref.read(
      chatSessionOwnedStateNotifierProvider(_controllerArgs).notifier,
    );
    final current = ref.read(
      chatSessionOwnedStateNotifierProvider(_controllerArgs),
    );
    notifier.replace(current.copyWith(messages: messages));
  }

  String _getMessageHintText(ConnectionInfo? connectionInfo) {
    if (_isRepositoryMode) {
      return 'Type a message...';
    }

    if (connectionInfo?.isConnected != true) {
      return 'Message will send when connected...';
    }

    if (connectionInfo?.isReady != true) {
      return 'Connecting... message will send when ready...';
    }

    return 'Type a message...';
  }

  Future<void> _deleteMessage(MessageId messageId, bool deleteForEveryone) {
    final actions = ref
        .read(chatSessionHandleProvider(_controllerArgs))
        .actions;
    return actions.deleteMessage(messageId, deleteForEveryone);
  }

  void _toggleSearchMode() {
    ref
        .read(chatSessionHandleProvider(_controllerArgs))
        .actions
        .toggleSearchMode();
  }

  Future<void> _manualReconnect() {
    return ref
        .read(chatSessionHandleProvider(_controllerArgs))
        .actions
        .manualReconnection();
  }
}

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/security_state.dart';
import '../../domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../controllers/chat_screen_controller.dart';
import '../models/chat_screen_config.dart';
import '../models/chat_ui_state.dart';
import '../providers/ble_providers.dart';
import '../providers/mesh_networking_provider.dart';
import '../providers/security_state_provider.dart';
import '../providers/chat_session_providers.dart';
import '../widgets/chat_screen_helpers.dart';
import '../widgets/chat_search_bar.dart';
import '../widgets/message_bubble.dart';

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
  bool get _isRepositoryMode => widget.chatId != null;
  bool get _isPeripheralMode => widget.central != null;
  bool get _isCentralMode => widget.device != null;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
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
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatScreenControllerProvider(_controllerArgs));
    final sessionHandle = ref.watch(chatSessionHandleProvider(_controllerArgs));
    final sessionActions = sessionHandle.actions;
    final ChatUIState uiState = sessionHandle.state;
    final searchController = sessionHandle.viewModel.searchController;
    final scrollingController = sessionHandle.viewModel.scrollingController;

    ref.listen(connectionInfoProvider, (previous, next) {
      sessionActions.handleConnectionChange(previous?.value, next.value);
    });
    ref.listen(meshNetworkStatusProvider, (previous, next) {
      sessionActions.handleMeshInitializationStatusChange(previous, next);
      ref.watch(chatSessionLifecycleFromControllerProvider(_controllerArgs));
    });

    final connectionInfo = ref.watch(connectionInfoProvider).value;

    final securityStateAsync = ref.watch(
      securityStateProvider(controller.securityStateKey),
    );

    final bleService = ref.watch(connectionServiceProvider);

    final actuallyConnected = connectionInfo?.isConnected ?? false;
    final messages = uiState.messages;

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
            if (searchController.isSearchMode)
              ChatSearchBar(
                messages: messages,
                onSearch: searchController.handleSearchQuery,
                onNavigateToResult: (index) => searchController
                    .navigateToSearchResult(index, messages.length),
                onExitSearch: _toggleSearchMode,
              ),
            Expanded(
              child: uiState.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : messages.isEmpty
                  ? const EmptyChatPlaceholder()
                  : ListView.builder(
                      controller: scrollingController.scrollController,
                      padding: EdgeInsets.zero,
                      itemCount: messages.length + 1,
                      itemBuilder: (context, index) {
                        if (index == messages.length) {
                          final failedCount = uiState.messages
                              .where(
                                (m) =>
                                    m.isFromMe &&
                                    m.status == MessageStatus.failed,
                              )
                              .length;
                          return RetryIndicator(
                            failedCount: failedCount,
                            onRetry: () => sessionActions.retryFailedMessages(),
                          );
                        }

                        final message = messages[index];
                        Widget messageWidget = MessageBubble(
                          message: message,
                          showAvatar: true,
                          showStatus: true,
                          searchQuery: searchController.isSearchMode
                              ? searchController.searchQuery
                              : null,
                          onRetry: null,
                          onDelete: (messageId, deleteForEveryone) =>
                              _deleteMessage(messageId, deleteForEveryone),
                        );

                        if (uiState.showUnreadSeparator &&
                            index ==
                                scrollingController.lastReadMessageIndex + 1 &&
                            scrollingController.unreadMessageCount > 0) {
                          return Column(
                            children: [const UnreadSeparator(), messageWidget],
                          );
                        }

                        return messageWidget;
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: _getMessageHintText(connectionInfo),
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton:
          scrollingController.shouldShowScrollDownButton(messages.length)
          ? Padding(
              padding: const EdgeInsets.only(bottom: 80.0),
              child: FloatingActionButton(
                mini: true,
                onPressed: () {
                  sessionActions.scrollToBottom();
                  scrollingController.scheduleMarkAsRead();
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(Icons.arrow_downward),
                    if (uiState.newMessagesWhileScrolledUp > 0)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            uiState.newMessagesWhileScrolledUp > 99
                                ? '99+'
                                : '${uiState.newMessagesWhileScrolledUp}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
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

  Future<void> _deleteMessage(String messageId, bool deleteForEveryone) {
    final actions = ref
        .read(chatSessionHandleProvider(_controllerArgs))
        .actions;
    return actions.deleteMessage(MessageId(messageId), deleteForEveryone);
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

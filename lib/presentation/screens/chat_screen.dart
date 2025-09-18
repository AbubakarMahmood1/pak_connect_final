// ignore_for_file: avoid_print

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../providers/ble_providers.dart';
import '../providers/security_state_provider.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/chat_list_item.dart'; 
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../core/utils/chat_utils.dart';
import '../widgets/message_bubble.dart';
import '../../core/models/connection_info.dart';
import '../widgets/pairing_dialog.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/models/security_state.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final Peripheral? device;      // For central mode (live connection)
  final Central? central;        // For peripheral mode (live connection)
  final String? chatId;          // For repository mode (stored data)
  final String? contactName;     // Contact display name
  final String? contactPublicKey; // Contact public key
  
  const ChatScreen({
    super.key, 
    this.device,
    this.central,
    this.chatId,
    this.contactName,
    this.contactPublicKey,
  }) : assert(
    (device != null || central != null) || (chatId != null && contactName != null),
    'Either live connection (device/central) OR chat data (chatId/contactName) must be provided'
  );

  // Named constructor for repository-based chats
  const ChatScreen.fromChatData({
    super.key,
    required String this.chatId,
    required String this.contactName,
    required String this.contactPublicKey,
  }) : device = null, central = null;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _logger = Logger('ChatScreen');
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final MessageRepository _messageRepository = MessageRepository();
  static final Map<String, SecurityState> _securityStateCache = {};
  
  List<Message> _messages = [];
  bool _isLoading = true;
  bool _pairingDialogShown = false;
  bool _contactRequestInProgress = false;
  StreamSubscription<String>? _messageSubscription;
  String? _currentChatId;
  int _unreadMessageCount = 0;
  int _lastReadMessageIndex = -1;
  bool _showUnreadSeparator = false;
  Timer? _unreadSeparatorTimer;
  String? _persistentContactPublicKey;
 
  String get _chatId => _currentChatId!;
  bool get _isPeripheralMode => widget.central != null;
  bool get _isCentralMode => widget.device != null;
  bool get _isRepositoryMode => widget.chatId != null;
  bool get _isConnectedMode => _isCentralMode || _isPeripheralMode;

String get _displayContactName {
  if (_isRepositoryMode) return widget.contactName!;
  if (_isCentralMode && widget.device != null) {
    return widget.device!.uuid.toString().substring(0, 8);
  }
  if (_isPeripheralMode && widget.central != null) {
    return widget.central!.uuid.toString().substring(0, 8);
  }
  return 'Unknown';
}

String? get securityStateKey {
    print('🐛 NAV DEBUG: securityStateKey getter called');
    print('🐛 NAV DEBUG: - _isRepositoryMode: $_isRepositoryMode');
    print('🐛 NAV DEBUG: - widget.contactPublicKey: ${widget.contactPublicKey?.substring(0, 16)}...');
    print('🐛 NAV DEBUG: - _persistentContactPublicKey: ${_persistentContactPublicKey?.substring(0, 16)}...');
    
    if (_isRepositoryMode) {
      // Always prioritize widget.contactPublicKey if available from widget
      if (widget.contactPublicKey != null && widget.contactPublicKey!.isNotEmpty) {
        final key = 'repo_${widget.contactPublicKey}';
        print('🐛 NAV DEBUG: - returning repo key with widget: $key');
        return key;
      }
      // Fallback to persistent key
      if (_persistentContactPublicKey != null && _persistentContactPublicKey!.isNotEmpty) {
        final key = 'repo_$_persistentContactPublicKey';
        print('🐛 NAV DEBUG: - returning repo key with persistent: $key');
        return key;
      }
      // Final fallback - but this should be rare
      final fallbackKey = 'repo_${widget.chatId}';
      print('🐛 NAV DEBUG: - returning repo key with chatId: $fallbackKey');
      return fallbackKey;
    } else {
      // Live connection mode: prioritize widget.contactPublicKey, then persistent key
      if (widget.contactPublicKey != null && widget.contactPublicKey!.isNotEmpty) {
        print('🐛 NAV DEBUG: - returning live widget key: ${widget.contactPublicKey!.substring(0, 16)}...');
        return widget.contactPublicKey;
      }
      if (_persistentContactPublicKey != null) {
        print('🐛 NAV DEBUG: - returning live persistent key: ${_persistentContactPublicKey!.substring(0, 16)}...');
        return _persistentContactPublicKey;
      }
      
      // Fallback to current connection if persistent not yet set
      final bleService = ref.read(bleServiceProvider);
      final fallbackKey = bleService.otherDevicePersistentId;
      print('🐛 NAV DEBUG: - returning live fallback key: ${fallbackKey?.substring(0, 16) ?? 'NULL'}...');
      return fallbackKey;
    }
  }

@override
  void initState() {
    super.initState();
    print('🐛 NAV DEBUG: ChatScreen initState() called');
    print('🐛 NAV DEBUG: - widget.device: ${widget.device?.uuid}');
    print('🐛 NAV DEBUG: - widget.central: ${widget.central?.uuid}');
    print('🐛 NAV DEBUG: - widget.chatId: ${widget.chatId}');
    print('🐛 NAV DEBUG: - widget.contactName: ${widget.contactName}');
    print('🐛 NAV DEBUG: - widget.contactPublicKey: ${widget.contactPublicKey?.substring(0, 16)}...');
    
    _currentChatId = _calculateInitialChatId();
    print('🐛 NAV DEBUG: - calculated chatId: $_currentChatId');
    
    _initializePersistentValues();
    
    _loadMessages();
    _loadUnreadCount();
    
    if (_isConnectedMode) {
      _setupMessageListener();
      _setupContactRequestListener();
    }
    
    _setupSecurityStateListener();
    print('🐛 NAV DEBUG: ChatScreen initState() completed');
  }

void _setupSecurityStateListener() {
  final bleService = ref.read(bleServiceProvider);
  
  bleService.stateManager.onContactRequestCompleted = (success) {
    if (!mounted) return;
    _logger.info('Contact operation completed: $success - refreshing UI state');
    
    if (success) {
      Timer(Duration(milliseconds: 500), () {
        if (mounted) {
          ref.invalidate(securityStateProvider(securityStateKey));
        }
      });
    }
  };
}

void _userRequestedPairing() async {
  if (_pairingDialogShown) return;
  
  final connectionInfo = ref.read(connectionInfoProvider).value;
if (!(connectionInfo?.isConnected ?? false)) {
    _showError('Not connected - cannot pair');
    return;
  }
  
  print('🔑 USER: User requested pairing dialog');
  _pairingDialogShown = true;
  _showPairingDialog();
}

void _showPairingDialog() async {
  final bleService = ref.read(bleServiceProvider);
  bleService.connectionManager.setPairingInProgress(true);
  bleService.stateManager.clearPairing();
  
  final myCode = bleService.stateManager.generatePairingCode();
  
  // Capture context before async
  final navigator = Navigator.of(context);
  
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PairingDialog(
      myCode: myCode,
      onCodeEntered: (theirCode) async {
        final success = await bleService.stateManager.completePairing(theirCode);
        if (mounted) navigator.pop(success);
      },
      onCancel: () {
        if (mounted) navigator.pop(false);
      },
    ),
  );
  
  // Resume health checks after pairing
  bleService.connectionManager.setPairingInProgress(false);
  
  if (result == true) {
    print('🛠 DEBUG: Pairing completed successfully in chat screen');
    
    final otherKey = bleService.otherDevicePersistentId;
    if (otherKey != null) {
      print('🛠 DEBUG: Attempting security upgrade for: $otherKey');
      final upgradeResult = await bleService.stateManager.confirmSecurityUpgrade(otherKey, SecurityLevel.medium);
      print('🛠 DEBUG: Security upgrade result: $upgradeResult');
    }
    
    _logger.info('Pairing successful - keeping session active');
  } else {
    print('🛠 DEBUG: Pairing failed or cancelled');
    bleService.stateManager.clearPairing();
  }

  _pairingDialogShown = false;
}

void _handleAsymmetricContact(String publicKey, String displayName) {
  // Only show if we're not already handling this
  if (_contactRequestInProgress) return;
  
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.sync_problem, color: Colors.orange),
          SizedBox(width: 8),
          Text('Contact Sync'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$displayName has you as a verified contact, but you haven\'t added them back yet.'),
          SizedBox(height: 12),
          Text('Add them to enable secure ECDH encryption?'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Not Now'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(context);
            await _addAsVerifiedContact(publicKey, displayName);
          },
          child: Text('Add Contact'),
        ),
      ],
    ),
  );
}

Future<void> _addAsVerifiedContact(String publicKey, String displayName) async {
  try {
    final contactRepo = ContactRepository();
    await contactRepo.saveContact(publicKey, displayName);
    await contactRepo.markContactVerified(publicKey);
    
    // Compute and cache ECDH shared secret
    final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
    if (sharedSecret != null) {
      await contactRepo.cacheSharedSecret(publicKey, sharedSecret);
      
      // Also restore it in SimpleCrypto for immediate use
      await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
    }
    
    _logger.info('Added asymmetric contact as verified: $displayName');
  } catch (e) {
    _logger.severe('Failed to add verified contact: $e');
  }
}

Future<void> _manualReconnection() async {
  final bleService = ref.read(bleServiceProvider);
  
  // Check if already connected
  if (bleService.isConnected) {
    _showSuccess('Already connected');
    return;
  }
  
  _showSuccess('Manually searching for device...');
  
  try {
    final foundDevice = await bleService.scanForSpecificDevice(
      timeout: Duration(seconds: 10)
    );
    
    if (foundDevice != null) {
      // Check if this is the same device we're already connected to
      if (bleService.connectedDevice?.uuid == foundDevice.uuid) {
        _showSuccess('Already connected to this device');
        return;
      }
      
      await bleService.connectToDevice(foundDevice);
      _showSuccess('Manual reconnection successful!');
    } else {
      _showError('Device not found - ensure other device is in discoverable mode');
    }
  } catch (e) {
    // Better error handling for already connected case
    final errorMsg = e.toString();
    if (errorMsg.contains('1049')) {
      _showSuccess('Already connected to device');
    } else {
      _showError('Manual reconnection failed: ${errorMsg.split(':').last}');
    }
  }
}

Future<void> _initializePersistentValues() async {
    print('🐛 NAV DEBUG: _initializePersistentValues() called');
    print('🐛 NAV DEBUG: - _isRepositoryMode: $_isRepositoryMode');
    
    if (_isRepositoryMode) {
      _persistentContactPublicKey = widget.contactPublicKey;
      print('🐛 NAV DEBUG: - set persistent key from widget: ${_persistentContactPublicKey?.substring(0, 16)}...');
    } else {
      // For live connections, get and cache the values
      final bleService = ref.read(bleServiceProvider);
      
      print('🐛 NAV DEBUG: - bleService.otherDevicePersistentId: ${bleService.otherDevicePersistentId?.substring(0, 16)}...');
      
      _persistentContactPublicKey = bleService.otherDevicePersistentId;
      print('🐛 NAV DEBUG: - set persistent key immediately: ${_persistentContactPublicKey?.substring(0, 16)}...');
      
      // If still null, setup listener for when they become available (no race condition)
      if (_persistentContactPublicKey == null) {
        print('🐛 NAV DEBUG: - persistent key null, setting up one-time listener');
        Timer.periodic(Duration(milliseconds: 500), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          final bleService = ref.read(bleServiceProvider);
          if (bleService.otherDevicePersistentId != null) {
            print('🐛 NAV DEBUG: - listener found key: ${bleService.otherDevicePersistentId!.substring(0, 16)}...');
            setState(() {
              _persistentContactPublicKey = bleService.otherDevicePersistentId;
            });
            timer.cancel();
          }
        });
      }
    }
    print('🐛 NAV DEBUG: _initializePersistentValues() completed with key: ${_persistentContactPublicKey?.substring(0, 16)}...');
  }

  Future<void> _loadMessages() async {
    final messages = await _messageRepository.getMessages(_chatId);
    setState(() {
      _messages = messages;
      _isLoading = false;
    });
    _scrollToBottom();
    
    // Auto-retry failed messages after a short delay
    Future.delayed(Duration(milliseconds: 1000), () {
      if (mounted) {
        _autoRetryFailedMessages();
      }
    });
  }

  Future<void> _autoRetryFailedMessages() async {
    final bleService = ref.read(bleServiceProvider);
     final connectionInfo = ref.read(connectionInfoProvider).value;
if (!(connectionInfo?.isConnected ?? false)) {
    _showError('Cannot retry - device not connected');
    return;
  }
    
    // Find failed messages
    final failedMessages = _messages.where((m) => m.isFromMe && m.status == MessageStatus.failed).toList();
    
    if (failedMessages.isEmpty) {
    _logger.info('No failed messages to retry');
    return;
  }
    _logger.info('Found ${failedMessages.length} failed messages to retry');

    // Sort by timestamp to preserve order
    failedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    _showSuccess('Retrying ${failedMessages.length} failed message${failedMessages.length > 1 ? 's' : ''}...');
    
    // Retry each message with delay
    for (int i = 0; i < failedMessages.length; i++) {
      final message = failedMessages[i];
      
      // Update to sending status
      final retryMessage = message.copyWith(status: MessageStatus.sending);
      await _messageRepository.updateMessage(retryMessage);
      setState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          _messages[index] = retryMessage;
        }
      });
      
      try {
  bool success;
  
  if (_isCentralMode) {
    success = await bleService.sendMessage(message.content, messageId: message.id);
  } else {
    // Peripheral mode: use peripheral sending method
    success = await bleService.sendPeripheralMessage(message.content, messageId: message.id);
  }
  
  final newStatus = success ? MessageStatus.delivered : MessageStatus.failed;
  final updatedMessage = retryMessage.copyWith(status: newStatus);
  await _messageRepository.updateMessage(updatedMessage);
  setState(() {
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index != -1) {
      _messages[index] = updatedMessage;
    }
  });
  _scrollToBottom();
      } catch (e) {
        // Mark as failed again
        final failedAgain = retryMessage.copyWith(status: MessageStatus.failed);
        await _messageRepository.updateMessage(failedAgain);
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = failedAgain;
          }
        });
      }
      
      // Rate limiting: delay between retries
      if (i < failedMessages.length - 1) {
        await Future.delayed(Duration(milliseconds: 500));
      }
    }
    
    // Show completion message
    final stillFailed = _messages.where((m) => m.isFromMe && m.status == MessageStatus.failed).length;
    if (stillFailed == 0) {
      _showSuccess('All messages delivered!');
    } else {
      _showError('$stillFailed message${stillFailed > 1 ? 's' : ''} still failed');
    }
  }

  void _setupMessageListener() {
    final bleService = ref.read(bleServiceProvider);
    _messageSubscription = bleService.receivedMessages.listen((content) {
      if (mounted) {
        _addReceivedMessage(content);
      }
    });
  }

  Future<void> _addReceivedMessage(String content) async {
    final message = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      chatId: _chatId,
      content: content,
      timestamp: DateTime.now(),
      isFromMe: false,
      status: MessageStatus.delivered,
    );
    
    await _messageRepository.saveMessage(message);
    setState(() {
      _messages.add(message);
      if (_showUnreadSeparator) {
        _showUnreadSeparator = false;
        _unreadSeparatorTimer?.cancel();
        _markAsRead();
      }
    });
    _scrollToBottom();
  }

Future<void> _loadUnreadCount() async {
  if (_isRepositoryMode) {
    final chatsRepo = ChatsRepository();
    final chats = await chatsRepo.getAllChats();
    final currentChat = chats.firstWhere(
      (chat) => chat.chatId == _chatId,
      orElse: () => ChatListItem(
        chatId: '', 
        contactName: '', 
        contactPublicKey: null,
        lastMessage: null, 
        lastMessageTime: null,
        unreadCount: 0, 
        isOnline: false, 
        hasUnsentMessages: false,
        lastSeen: null,
      ),
    );
    
    setState(() {
      _unreadMessageCount = currentChat.unreadCount;
      if (_unreadMessageCount > 0 && _messages.isNotEmpty) {
        _lastReadMessageIndex = _messages.length - _unreadMessageCount - 1;
        _showUnreadSeparator = true;
      }
    });
    
    // Auto-hide separator after 3 seconds
    if (_showUnreadSeparator) {
      _startUnreadSeparatorTimer();
    }
  }
}

  void _startUnreadSeparatorTimer() {
    _unreadSeparatorTimer?.cancel();
    _unreadSeparatorTimer = Timer(Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showUnreadSeparator = false;
        });
        _markAsRead();
      }
    });
  }

  Future<void> _markAsRead() async {
  if (_unreadMessageCount > 0) {
    final chatsRepo = ChatsRepository();
    await chatsRepo.markChatAsRead(_chatId);
    setState(() {
      _unreadMessageCount = 0;
      _lastReadMessageIndex = -1;
    });
  }
}

@override
Widget build(BuildContext context) {
  final securityStateAsync = ref.watch(securityStateProvider(securityStateKey));
    
    // Store successful state in cache
    securityStateAsync.whenData((state) {
      if (securityStateKey != null) {
        _securityStateCache[securityStateKey!] = state;
      }
    });
    
    // Use cached state if provider is loading
    securityStateAsync.when(
      data: (state) => state,
      loading: () => _securityStateCache[securityStateKey ?? ''] ?? SecurityState.disconnected(),
      error: (error, stack) => SecurityState.disconnected(),
    );

  print('🛠 DEBUG: SecurityStateProvider called for key: $securityStateKey');
  print('🛠 DEBUG: SecurityState result: ${securityStateAsync.hasValue ? securityStateAsync.value.toString() : 'LOADING'}');

  ref.watch(connectionInfoProvider);
  ref.watch(discoveredDevicesProvider);
  ref.watch(discoveryDataProvider);

  ref.listen(connectionInfoProvider, (previous, next) {
    _handleConnectionChange(previous?.value, next.value);
  });

  // Listen for identity changes
  ref.listen(connectionInfoProvider, (previous, next) {
    if (next.hasValue && 
        next.value?.otherUserName != null && 
        next.value!.otherUserName!.isNotEmpty &&
        previous?.value?.otherUserName != next.value?.otherUserName) {
      
      _logger.info('🔄 Identity exchange detected: ${next.value!.otherUserName}');
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleIdentityReceived();
          
          Future.delayed(Duration(milliseconds: 500), () {
  if (mounted) {
  }
});
        }
      });
    }
  });

  // Handle connection state changes for auto-retry
  ref.listen(connectionInfoProvider, (previous, next) {
    if (!mounted) return;
    
    final connectionInfo = next.maybeWhen(
      data: (info) => info,
      orElse: () => null,
    );
    if (connectionInfo == null) return;
    
    final isConnected = connectionInfo.isConnected;
    _logger.info('Chat screen received connection state: $isConnected');
    
    if (isConnected) {
      _showSuccess('Device reconnected!');
      Future.delayed(Duration(milliseconds: 2500), () {
        if (mounted) {
          _autoRetryFailedMessages();
        }
      });
    } else {
      _showError('Device disconnected');
      
      final bleService = ref.read(bleServiceProvider);
      if (!bleService.isPeripheralMode) {
        bleService.startConnectionMonitoring();
      }
    }
  });

  try {
    final bleService = ref.watch(bleServiceProvider);
    final connectionInfoAsync = ref.watch(connectionInfoProvider);
    
    // Use the stabilized security state key getter
    final securityStateAsync = ref.watch(securityStateProvider(securityStateKey));
    
    // Connection info for legacy compatibility
    final connectionInfo = connectionInfoAsync.maybeWhen(
      data: (info) => info,
      orElse: () => null,
    );

final actuallyConnected = connectionInfo?.isConnected ?? false;
    
    return Scaffold(
  appBar: AppBar(
  title: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _isRepositoryMode 
          ? 'Chat with ${widget.contactName}'
          : (connectionInfo?.otherUserName ?? 'Device $_displayContactName...'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      // Simple, clear text status
      securityStateAsync.when(
        data: (securityState) => Text(
          _buildStatusText(connectionInfo, securityState),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _getStatusColor(securityState),
          ),
        ),
        loading: () => Text(
          'Loading...',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey,
          ),
        ),
        error: (error, stack) => Text(
          'Error',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.red,
          ),
        ),
      ),
    ],
  ),
  actions: [
    // Only show relevant action button
    securityStateAsync.when(
      data: (securityState) => _buildSingleActionButton(securityState),
      loading: () => SizedBox(width: 48),
      error: (error, stack) => SizedBox(width: 48),
    ),
  ],
),
      body: SafeArea(
  bottom: true,
  child: Column(
    children: [
      // Reconnection banner
      if (!actuallyConnected || bleService.isActivelyReconnecting)
        _buildReconnectionBanner(),

      // Messages list
      Expanded(
  child: _isLoading
      ? Center(child: CircularProgressIndicator())
      : _messages.isEmpty
          ? _buildEmptyChat()
          : ListView.builder(
              controller: _scrollController,
              padding: EdgeInsets.zero,
              itemCount: _messages.length + 1,
              itemBuilder: (context, index) {
                if (index == _messages.length) {
                  return _buildSubtleRetryIndicator();
                }
                
                // ✅ NEW: Create the message widget
                Widget messageWidget = MessageBubble(
                  message: _messages[index],
                  showAvatar: true,
                  showStatus: true,
                  onRetry: _messages[index].status == MessageStatus.failed
                      ? () => _retryMessage(_messages[index])
                      : null,
                );
                
                // ✅ NEW: Check if we need to show unread separator BEFORE this message
                if (_showUnreadSeparator && 
                    index == _lastReadMessageIndex + 1 && 
                    _unreadMessageCount > 0) {
                  // This is the first unread message - show separator above it
                  return Column(
                    children: [
                      _buildUnreadMessageSeparator(),
                      messageWidget,
                    ],
                  );
                }
                
                // ✅ Regular message without separator
                return messageWidget;
              },
            ),
	),
      Container(
        padding: EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                decoration: InputDecoration(
                  hintText: _getMessageHintText(),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.send),
              onPressed: _sendMessage, // Always enabled
            ),
          ],
        ),
      ),
    ],
  ),
),
    );
  } catch (e) {
    return Scaffold(
      appBar: AppBar(title: Text('Error')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red),
            SizedBox(height: 16),
            Text('Error: $e'),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}

String _buildStatusText(ConnectionInfo? connectionInfo, SecurityState securityState) {
  final parts = <String>[];
  
  // Connection status (only for live connections)
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
  
  // Security status (always shown)
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
      icon: Icon(Icons.lock_open),
      onPressed: _userRequestedPairing,
      tooltip: 'Secure Chat',
    );
  } else if (securityState.showContactAddButton) {
    return IconButton(
      icon: Icon(Icons.person_add),
      onPressed: _sendContactRequest,
      tooltip: 'Add Contact',
    );
  } else if (securityState.showContactSyncButton) {
    return IconButton(
      icon: Icon(Icons.sync),
      onPressed: () => _handleAsymmetricContact(
        securityState.otherPublicKey ?? '',
        securityState.otherUserName ?? 'Unknown',
      ),
      tooltip: 'Sync Contact',
    );
  }
  return SizedBox(width: 48);
}

Widget _buildReconnectionBanner() {
  final bleService = ref.read(bleServiceProvider);
  
  // Check BT state for both modes first
  if (bleService.state != BluetoothLowEnergyState.poweredOn) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled, size: 16),
          SizedBox(width: 8),
          Text(
            'Bluetooth is off - Please enable Bluetooth', 
            style: TextStyle(fontSize: 12)
          ),
        ],
      ),
    );
  }
  
  if (_isPeripheralMode) {
    // Peripheral mode - show advertising status
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(Icons.wifi_tethering, size: 16, color: Colors.green),
          SizedBox(width: 8),
          Text('Advertising - Waiting for connection...', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  } else {
    // Central mode - ONLY show banner if actively reconnecting (not health checking)
    if (bleService.isActivelyReconnecting) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Expanded(child: Text('Searching for device...', style: TextStyle(fontSize: 12))),
            TextButton(
              onPressed: _manualReconnection,
              child: Text('Reconnect Now'),
            ),
          ],
        ),
      );
    }
  }
  
  // No banner needed - connection is healthy
  return SizedBox.shrink();
}

Widget _buildUnreadMessageSeparator() {
    return Container(
      margin: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Theme.of(context).colorScheme.primary.withValues(),
                    Theme.of(context).colorScheme.primary.withValues(),
                    Theme.of(context).colorScheme.primary.withValues(),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyChat() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          SizedBox(height: 16),
          Text(
            'Start your conversation',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Send a message to begin chatting',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubtleRetryIndicator() {
    final failedCount = _messages.where((m) => m.isFromMe && m.status == MessageStatus.failed).length;
    
    if (failedCount == 0) return SizedBox.shrink();
    
    return Padding(
      padding: EdgeInsets.only(top: 8, bottom: 16, left: 16, right: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: _autoRetryFailedMessages,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer.withValues(),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withValues(),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(),
                  ),
                  SizedBox(width: 4),
                  Text(
                    '$failedCount failed',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(),
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(
                    Icons.refresh,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  SizedBox(width: 2),
                  Text(
                    'retry',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

void _sendContactRequest() async {
  setState(() => _contactRequestInProgress = true);
  
  final bleService = ref.read(bleServiceProvider);
  final otherPublicKey = bleService.otherDevicePersistentId;
  final otherName = bleService.otherUserName;
  
  if (otherPublicKey == null || otherName == null) {
    _showError('Cannot add contact - missing identity');
    setState(() => _contactRequestInProgress = false);
    return;
  }
  
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('Add to Contacts?'),
      content: Text('This will save $otherName as a trusted contact with ECDH encryption.'),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            setState(() => _contactRequestInProgress = false);
          },
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(context);
            
            try {
              // Don't use the complex contact request system for direct addition
              final contactRepo = ContactRepository();
              
              // Check if already exists
              final existingContact = await contactRepo.getContact(otherPublicKey);
              
              if (existingContact != null) {
                print('🔧 ADD CONTACT: Already exists - just marking as verified');
                await contactRepo.markContactVerified(otherPublicKey);
                
                if (existingContact.securityLevel.index < SecurityLevel.high.index) {
                  await contactRepo.updateContactSecurityLevel(otherPublicKey, SecurityLevel.high);
                }
              } else {
                print('🔧 ADD CONTACT: Creating new verified contact');
                await contactRepo.saveContactWithSecurity(otherPublicKey, otherName, SecurityLevel.high);
                await contactRepo.markContactVerified(otherPublicKey);
                
                // Compute ECDH if not already done
                final sharedSecret = SimpleCrypto.computeSharedSecret(otherPublicKey);
                if (sharedSecret != null) {
                  await contactRepo.cacheSharedSecret(otherPublicKey, sharedSecret);
                }
              }
              
              // Force refresh security state
              ref.invalidate(securityStateProvider(securityStateKey));              
            } catch (e) {
              print('🔧 ADD CONTACT ERROR: $e');
            }
            
            setState(() => _contactRequestInProgress = false);
          },
          child: Text('Add Contact'),
        ),
      ],
    ),
  );
}

// Listen for incoming contact requests
void _setupContactRequestListener() {
  final bleService = ref.read(bleServiceProvider);

    bleService.stateManager.onContactRequestCompleted = (success) {
    if (!mounted) return;
    _logger.info('Contact operation completed: $success - refreshing UI state');
  };
  
  bleService.stateManager.onContactRequestReceived = (publicKey, displayName) {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Contact Request'),
        content: Text('$displayName wants to add you as a trusted contact. This enables enhanced encryption.'),
        actions: [
          TextButton(
            onPressed: () {
              bleService.stateManager.rejectContactRequest();
              Navigator.pop(context);
            },
            child: Text('Decline'),
          ),
          FilledButton(
  onPressed: () async {
    Navigator.pop(context);
    await bleService.stateManager.acceptContactRequest();
  },
  child: Text('Accept'),
),
        ],
      ),
    );
  };
  
  // Handle asymmetric contact detection
  bleService.stateManager.onAsymmetricContactDetected = (publicKey, displayName) {
    if (!mounted) return;
    
    _logger.info('🔄 Asymmetric contact detected: $displayName');
    _handleAsymmetricContact(publicKey, displayName);
  };
}

  void _sendMessage() async {
  final text = _messageController.text.trim();
  if (text.isEmpty) return;

  _messageController.clear();
  
  print('🔧 SEND DEBUG: Attempting to send message: "$text"');
  print('🔧 SEND DEBUG: _isRepositoryMode: $_isRepositoryMode');
  
  // Create message with sending status
  final message = Message(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    chatId: _chatId,
    content: text,
    timestamp: DateTime.now(),
    isFromMe: true,
    status: MessageStatus.sending,
  );

  // Save and show immediately
  await _messageRepository.saveMessage(message);
  setState(() {
    _messages.add(message);
  });
  _scrollToBottom();

  try {
    bool success = false;
    
    if (_isRepositoryMode) {
      print('🔧 SEND DEBUG: Repository mode - marking as delivered');
      success = true;
    } else {
      // Live connection mode - ALWAYS TRY TO SEND regardless of security level
      final connectionInfo = ref.read(connectionInfoProvider).value;
      
      print('🔧 SEND DEBUG: Connection info - isConnected: ${connectionInfo?.isConnected}, isReady: ${connectionInfo?.isReady}');
      
      if (connectionInfo?.isConnected == true && connectionInfo?.isReady == true) {
        print('🔧 SEND DEBUG: Connection ready - attempting to send');
        
        final bleService = ref.read(bleServiceProvider);
        
        if (_isCentralMode) {
          print('🔧 SEND DEBUG: Using central mode sending');
          success = await bleService.sendMessage(text, messageId: message.id);
        } else if (_isPeripheralMode) {
          print('🔧 SEND DEBUG: Using peripheral mode sending');
          success = await bleService.sendPeripheralMessage(text, messageId: message.id);
        } else {
          print('🔧 SEND DEBUG: No valid connection mode - but attempting anyway');
          // Try both methods as fallback
          try {
            success = await bleService.sendMessage(text, messageId: message.id);
          } catch (e) {
            print('🔧 SEND DEBUG: Central send failed, trying peripheral: $e');
            success = await bleService.sendPeripheralMessage(text, messageId: message.id);
          }
        }
      } else {
        print('🔧 SEND DEBUG: Not connected - marking as failed for later retry');
        success = false;
      }
    }
    
    print('🔧 SEND DEBUG: Send result: $success');
    
    final newStatus = success ? MessageStatus.delivered : MessageStatus.failed;
    final updatedMessage = message.copyWith(status: newStatus);
    await _messageRepository.updateMessage(updatedMessage);
    setState(() {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        _messages[index] = updatedMessage;
      }
    });
    _scrollToBottom();
      
  } catch (e) {
    print('🔧 SEND DEBUG: Exception caught: $e');
    final failedMessage = message.copyWith(status: MessageStatus.failed);
    await _messageRepository.updateMessage(failedMessage);
    setState(() {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        _messages[index] = failedMessage;
      }
    });
  }
}

  Future<void> _retryMessage(Message failedMessage) async {
    final bleService = ref.read(bleServiceProvider);
    
    final connectionInfo = ref.read(connectionInfoProvider).value;
if (!(connectionInfo?.isConnected ?? false)) {
      _showError('Not connected. Please reconnect to the device first.');
      return;
    }
    
    _showSuccess('Retrying message...');
    
    // Update to sending status
    final retryMessage = failedMessage.copyWith(status: MessageStatus.sending);
    await _messageRepository.updateMessage(retryMessage);
    setState(() {
      final index = _messages.indexWhere((m) => m.id == failedMessage.id);
      if (index != -1) {
        _messages[index] = retryMessage;
      }
    });

    // Retry sending
    try {
      final success = await bleService.sendMessage(failedMessage.content, messageId: failedMessage.id);
      
      final newStatus = success ? MessageStatus.delivered : MessageStatus.failed;
      final updatedMessage = retryMessage.copyWith(status: newStatus);
      await _messageRepository.updateMessage(updatedMessage);
      setState(() {
        final index = _messages.indexWhere((m) => m.id == failedMessage.id);
        if (index != -1) {
          _messages[index] = updatedMessage;
        }
      });
     
      if (success) {
        _showSuccess('Message delivered!');
      } else {
        _showError('Retry failed - message timeout');
      }
      
    } catch (e) {
      final failedAgain = retryMessage.copyWith(status: MessageStatus.failed);
      await _messageRepository.updateMessage(failedAgain);
      setState(() {
        final index = _messages.indexWhere((m) => m.id == failedMessage.id);
        if (index != -1) {
          _messages[index] = failedAgain;
        }
      });
       _showError('Retry failed: ${e.toString().split(':').last}');
    }
  }

  void _scrollToBottom() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scrollController.hasClients && mounted) {
      Future.delayed(Duration(milliseconds: 50), () {
        if (_scrollController.hasClients && mounted) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  });
}

String _getMessageHintText() {
  if (_isRepositoryMode) {
    return 'Type a message...';
  }
  
  final connectionInfo = ref.read(connectionInfoProvider).value;
  if (connectionInfo?.isConnected != true) {
    return 'Message will send when connected...';
  }
  
  if (connectionInfo?.isReady != true) {
    return 'Connecting... message will send when ready...';
  }
  
  return 'Type a message...';
}

String _calculateInitialChatId() {
  // Repository mode: use provided chatId
  if (_isRepositoryMode) {
    return widget.chatId!;
  }
  
  // Live connection mode: generate from BLE service
  final bleService = ref.read(bleServiceProvider);
  final otherPersistentId = bleService.otherDevicePersistentId;
  final myPersistentId = bleService.myPersistentId;
  
  if (otherPersistentId != null && myPersistentId != null) {
    return ChatUtils.generateChatId(myPersistentId, otherPersistentId);
  }
  
  // Fallback for live connections
  final deviceId = _isCentralMode 
    ? widget.device!.uuid.toString()
    : widget.central!.uuid.toString();
  
  return 'temp_${deviceId.substring(0, 8)}';
}

Future<void> _handleIdentityReceived() async {
    final bleService = ref.read(bleServiceProvider);
    final otherPersistentId = bleService.otherDevicePersistentId;
    final myPersistentId = bleService.myPersistentId;
    
    // UPDATE persistent values when identity is received
    if (otherPersistentId != null) {
      setState(() {
        _persistentContactPublicKey = otherPersistentId;
      });
    }
    
    if (otherPersistentId != null && myPersistentId != null) {
      final newChatId = ChatUtils.generateChatId(myPersistentId, otherPersistentId);
      
      if (newChatId != _currentChatId) {
        final messagesToMigrate = await _messageRepository.getMessages(_currentChatId!);
        
        if (messagesToMigrate.isNotEmpty) {
          _logger.info('Identity received - migrating ${messagesToMigrate.length} messages from $_currentChatId to $newChatId');
          await _migrateMessages(_currentChatId!, newChatId);
          _currentChatId = newChatId;
          await _loadMessages();
        } else {
          _logger.info('Identity received - switching to persistent chat ID but no messages to migrate');
          _currentChatId = newChatId;
        }
        
        // IMPORTANT: Don't invalidate security state here - it should persist
      }
    }
  }

Future<void> _migrateMessages(String oldChatId, String newChatId) async {
  final oldMessages = await _messageRepository.getMessages(oldChatId);
  
  for (final message in oldMessages) {
    final migratedMessage = Message(
      id: message.id,
      chatId: newChatId, // NEW chat ID
      content: message.content,
      timestamp: message.timestamp,
      isFromMe: message.isFromMe,
      status: message.status,
    );
    await _messageRepository.saveMessage(migratedMessage);
  }
  
  // Clean up old temp messages
  await _messageRepository.clearMessages(oldChatId);
  _logger.info('Migrated ${oldMessages.length} messages from $oldChatId to $newChatId');
}


void _handleConnectionChange(ConnectionInfo? previous, ConnectionInfo? current) {
  if (!mounted) return;
  
  // Only react to meaningful changes
  final wasConnected = previous?.isConnected ?? false;
  final isConnected = current?.isConnected ?? false;
  final wasReady = previous?.isReady ?? false;
  final isReady = current?.isReady ?? false;
  
  if (!wasConnected && isConnected) {
    _showSuccess('Connected to device!');
  } else if (wasConnected && !isConnected) {
    _showError('Device disconnected');
  } else if (isConnected && !wasReady && isReady) {
    _showSuccess('Identity exchange complete!');
    // Trigger auto-retry after identity is established
    Future.delayed(Duration(milliseconds: 1000), () {
      if (mounted) _autoRetryFailedMessages();
    });
  }
}

  void _showError(String message) {
     _logger.warning('Error: $message');
  }

  void _showSuccess(String message) {
    _logger.info('Success: $message');
  }

  
@override
void dispose() {
  print('🐛 NAV DEBUG: ChatScreen dispose() called');
  print('🐛 NAV DEBUG: - Final persistent key: ${_persistentContactPublicKey?.substring(0, 16)}...');
  print('🐛 NAV DEBUG: - Final chatId: $_currentChatId');
  
  _messageSubscription?.cancel();
  _messageController.dispose();
  _scrollController.dispose();
  _unreadSeparatorTimer?.cancel();
  super.dispose();
  
  print('🐛 NAV DEBUG: ChatScreen dispose() completed');
}
}
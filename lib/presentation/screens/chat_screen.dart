import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../providers/ble_providers.dart';
import '../../domain/entities/message.dart';
import '../../data/repositories/message_repository.dart';
import '../../core/utils/chat_utils.dart';
import '../widgets/message_bubble.dart';
import '../../data/services/ble_service.dart';
import '../../core/models/connection_info.dart';
import '../widgets/pairing_dialog.dart';
import '../../core/models/pairing_state.dart';
import '../../core/services/simple_crypto.dart';
import '../../data/repositories/contact_repository.dart';

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
  
  List<Message> _messages = [];
  bool _isLoading = true;
  bool _hasPaired = false;
  bool _pairingDialogShown = false;
  bool _isContact = false;
  bool _contactRequestInProgress = false;
  StreamSubscription<String>? _messageSubscription;
  String? _currentChatId;
  bool get _isPeripheralMode => widget.central != null;
  bool get _isCentralMode => widget.device != null;
  bool get _isRepositoryMode => widget.chatId != null;
  bool get _isConnectedMode => _isCentralMode || _isPeripheralMode;

  String get _chatId => _currentChatId!;

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

String get _deviceDisplayName {
  if (_isCentralMode && widget.device != null) {
    return widget.device!.uuid.toString().substring(0, 8);
  } else if (_isPeripheralMode && widget.central != null) {
    return widget.central!.uuid.toString().substring(0, 8);
  } else {
    return 'Unknown';
  }
}

@override
void initState() {
  super.initState();
  _currentChatId = _calculateInitialChatId();
  
  // Load messages immediately
  _loadMessages();
  
  // Only setup listeners for live connection modes
  if (_isConnectedMode) {
    _setupMessageListener();
    _setupContactRequestListener();
    
    // Check pairing after a delay to ensure connection is stable
    Future.delayed(Duration(seconds: 1), () {
      if (mounted) {
        _checkPairingStatus();
      }
    });
  }
}

void _checkPairingStatus() async {
  // Prevent multiple checks
  if (_pairingDialogShown) return;
  
  final bleService = ref.read(bleServiceProvider);
  
  // Don't check pairing if already in repository mode
  if (_isRepositoryMode) {
    _hasPaired = true; // Repository chats always have keys
    return;
  }
  
  final otherPublicKey = bleService.otherDevicePersistentId;
  if (otherPublicKey == null) {
    _logger.warning('No public key available for pairing check');
    return;
  }
  
  // HIERARCHY: Contact > Cached Pairing > New Pairing
  
  // 1. Check if they're a verified contact (strongest security)
  final contact = await bleService.stateManager.contactRepository.getContact(otherPublicKey);
  if (contact != null && contact.trustStatus == TrustStatus.verified) {
    _logger.info('Verified contact detected - using ECDH encryption');
    _isContact = true;
    _hasPaired = true; // Contacts are implicitly paired
    
    // Ensure ECDH key is loaded
    await bleService.stateManager.checkExistingPairing(otherPublicKey);
    return;
  }
  
  // 2. Check for cached conversation key (from previous pairing)
  final hasExistingPairing = await bleService.stateManager.checkExistingPairing(otherPublicKey);
  if (hasExistingPairing) {
    _logger.info('Previous pairing found - restored conversation key');
    _hasPaired = true;
    return;
  }
  
  // 3. No existing security - need new pairing
  _logger.info('No existing security - showing pairing dialog');
  if (bleService.isConnected && !_pairingDialogShown) {
    _pairingDialogShown = true;
    _showPairingDialog();
  }
}

void _showPairingDialog() async {
  final bleService = ref.read(bleServiceProvider);
  
  // Pause health checks during pairing
  bleService.connectionManager.setPairingInProgress(true);
  
  // Clear any existing pairing first
  bleService.stateManager.clearPairing();
  
  // Generate code ONCE
  final myCode = bleService.stateManager.generatePairingCode();
  
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PairingDialog(
      myCode: myCode,
      onCodeEntered: (theirCode) async {
        final success = await bleService.stateManager.completePairing(theirCode);
        if (mounted) Navigator.pop(context, success);
      },
      onCancel: () {
        if (mounted) Navigator.pop(context, false);
      },
    ),
  );
  
  // Resume health checks after pairing
  bleService.connectionManager.setPairingInProgress(false);
  
  if (result == true) {
    setState(() => _hasPaired = true);
    // NO TOAST - UI shows lock icon change
  }
  
  bleService.stateManager.clearPairing();
  _pairingDialogShown = false;  // Reset flag after dialog closes
}

void _handleAsymmetricContact(String publicKey, String displayName) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Contact Mismatch'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sync_problem, size: 48, color: Colors.orange),
          SizedBox(height: 16),
          Text('$displayName has you as a verified contact.'),
          SizedBox(height: 8),
          Text('Add them back to enable secure ECDH encryption?'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Not Now'),
        ),
        FilledButton(
          onPressed: () async {
            // Add them as contact automatically
            await _addAsVerifiedContact(publicKey, displayName);
            Navigator.pop(context);
            setState(() => _isContact = true);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Contact added - ECDH enabled!')),
            );
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

Future<void> _restartAdvertising() async {
  final bleService = ref.read(bleServiceProvider);
  try {
    // Stop first, then restart
    await bleService.peripheralManager.stopAdvertising();
    await Future.delayed(Duration(milliseconds: 500));
    await bleService.startAsPeripheral();
    _showSuccess('Restarted advertising');
  } catch (e) {
    _showError('Failed to restart advertising: $e');
  }
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
    bool isConnected;

isConnected = bleService.isConnected;

  if (!isConnected) {
    _showError('Cannot retry messages - device not connected');
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
    });
    _scrollToBottom();
  }

@override
Widget build(BuildContext context) {
  ref.listen(connectionInfoProvider, (previous, next) {
    if (next.hasValue && 
        next.value?.otherUserName != null && 
        next.value!.otherUserName!.isNotEmpty &&
        previous?.value?.otherUserName != next.value?.otherUserName) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleIdentityReceived();
      });
    }
  });

  // Handle connection state changes
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
    final bleStateAsync = ref.watch(bleStateProvider);
    
    // Single source of truth for connection state
    final connectionInfo = connectionInfoAsync.maybeWhen(
      data: (info) => info,
      orElse: () => null,
    );

    final actuallyConnected = _isCentralMode 
      ? (bleService.isConnected && bleService.connectedDevice?.uuid == widget.device?.uuid)
      : (bleService.isConnected && _isPeripheralMode);
    
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
            Text(
              _getConnectionStatusText(connectionInfo),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _getConnectionStatusColor(connectionInfo),
              ),
            ),
          ],
        ),
        actions: [
          // Single security/action button based on state
          if ((connectionInfo?.isConnected ?? false))
            _buildSecurityIndicator(connectionInfo),

          if ((connectionInfo?.isConnected ?? false) && 
              _hasPaired && 
              !_isContact && 
              !_contactRequestInProgress)
            IconButton(
              onPressed: _sendContactRequest,
              icon: Icon(Icons.person_add, color: Colors.blue),
              tooltip: 'Add to contacts',
            ),

          if (_isContact)
            Icon(Icons.verified_user, color: Colors.green),

          // Show identity request button if connected but no name
          if ((connectionInfo?.isConnected ?? false) && 
              (connectionInfo?.otherUserName == null || connectionInfo!.otherUserName!.isEmpty))
            IconButton(
              onPressed: _requestIdentityExchange,
              icon: Icon(Icons.person_search, color: Colors.orange),
              tooltip: 'Request name exchange',
            ),

          // Show pairing button if connected with name but not paired
          if ((connectionInfo?.isConnected ?? false) && 
              (connectionInfo?.otherUserName != null && connectionInfo!.otherUserName!.isNotEmpty) &&
              !_hasPaired && 
              !_isRepositoryMode)
            IconButton(
              onPressed: _showPairingDialog,
              icon: Icon(Icons.lock_open, color: Colors.orange),
              tooltip: 'Setup secure chat',
            ),

          IconButton(
            onPressed: () => _showConnectionInfo(),
            icon: Icon(
              (connectionInfo?.isConnected ?? false)
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: (connectionInfo?.isConnected ?? false) ? Colors.green : Colors.red,
            ),
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
                            return MessageBubble(
                              message: _messages[index],
                              showAvatar: true,
                              showStatus: true,
                              onRetry: _messages[index].status == MessageStatus.failed
                                  ? () => _retryMessage(_messages[index])
                                  : null,
                            );
                          },
                        ),
            ),

            // Message input
            _buildMessageInput(connectionInfo?.isConnected ?? false, connectionInfo?.isReady ?? false),
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

  Widget _buildConnectionBanner() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          SizedBox(width: 8),
          Text(
            'Reconnecting... Messages will be sent when connected',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
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
      color: Theme.of(context).colorScheme.surfaceVariant,
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

  Widget _buildMessageStatusIcon(MessageStatus status, Message message) {
    switch (status) {
      case MessageStatus.sending:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1,
            color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.7),
          ),
        );
      case MessageStatus.sent:
        return Icon(
          Icons.check,
          size: 14,
          color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.7),
        );
      case MessageStatus.delivered:
        return Icon(
          Icons.done_all,
          size: 14,
          color: Colors.green,
        );
      case MessageStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 14,
          color: Colors.red,
        );
    }
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
                color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                  ),
                  SizedBox(width: 4),
                  Text(
                    '$failedCount failed',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
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

Widget _buildSecurityIndicator(ConnectionInfo? connectionInfo) {
  // Priority: Contact > Paired > Need Pairing > Need Identity
  
  if (_isContact) {
    return Padding(
      padding: EdgeInsets.only(right: 8),
      child: Tooltip(
        message: 'Verified Contact (ECDH)',
        child: Icon(Icons.verified_user, size: 20, color: Colors.green),
      ),
    );
  }
  
  if (_hasPaired) {
    // Show add contact button if paired but not contact
    if (!_contactRequestInProgress) {
      return IconButton(
        onPressed: _sendContactRequest,
        icon: Icon(Icons.person_add, size: 20, color: Colors.blue),
        tooltip: 'Add to contacts',
      );
    } else {
      return Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.lock, size: 20, color: Colors.blue),
      );
    }
  }
  
  // Not paired - check what's needed
  if (connectionInfo?.otherUserName == null || connectionInfo!.otherUserName!.isEmpty) {
    return IconButton(
      onPressed: _requestIdentityExchange,
      icon: Icon(Icons.person_search, size: 20, color: Colors.orange),
      tooltip: 'Request name exchange',
    );
  }
  
  // Has name but not paired
  if (!_isRepositoryMode) {
    return IconButton(
      onPressed: _showPairingDialog,
      icon: Icon(Icons.lock_open, size: 20, color: Colors.orange),
      tooltip: 'Setup encryption',
    );
  }
  
  return SizedBox.shrink();
}

Widget _buildMessageInput(bool isConnected, bool hasNameExchange) {
  return Container(
    padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        top: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
        ),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.3,
              minHeight: 48,
            ),
            child: TextField(
              controller: _messageController,
                decoration: InputDecoration(
                hintText: isConnected 
  ? (hasNameExchange ? 'Type a message...' : 'Exchanging names...') 
  : 'Reconnecting...',
enabled: isConnected && hasNameExchange,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceVariant,
                contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              maxLines: null,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              scrollPhysics: BouncingScrollPhysics(),
            ),
          ),
        ),
        SizedBox(width: 8),
        ValueListenableBuilder(
          valueListenable: _messageController,
          builder: (context, value, child) {
            final hasText = value.text.trim().isNotEmpty;
final canSend = hasText && isConnected && hasNameExchange && (_hasPaired || _isRepositoryMode);
return FloatingActionButton.small(
  onPressed: canSend ? _sendMessage : null,
  backgroundColor: canSend
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.surfaceVariant,
              child: Icon(
                Icons.send,
                color: (hasText && isConnected)
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            );
          },
        ),
      ],
    ),
  );
}


void _sendContactRequest() async {
  setState(() => _contactRequestInProgress = true);
  
  final bleService = ref.read(bleServiceProvider);
  
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('Add to Contacts?'),
      content: Text('This will save ${bleService.otherUserName} as a trusted contact with enhanced encryption.'),
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
            
            final success = await bleService.stateManager.sendContactRequest();
            
            if (success) {
              setState(() => _isContact = true);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Contact added successfully!')),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Contact request declined')),
              );
            }
            
            setState(() => _contactRequestInProgress = false);
          },
          child: Text('Send Request'),
        ),
      ],
    ),
  );
}

// Listen for incoming contact requests
void _setupContactRequestListener() {
  final bleService = ref.read(bleServiceProvider);
  
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
              await bleService.stateManager.acceptContactRequest();
              setState(() => _isContact = true);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Contact added!')),
              );
            },
            child: Text('Accept'),
          ),
        ],
      ),
    );
  };
}

  void _sendMessage() async {
  final text = _messageController.text.trim();
  if (text.isEmpty) return;

  _messageController.clear();

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

  // Send via appropriate method based on mode
  try {
    bool success;
    
    if (_isCentralMode) {
      // Central mode: send via writeCharacteristic
      final bleService = ref.read(bleServiceProvider);

if (!bleService.isConnected) {
  _showError('Not connected - please ensure devices are paired');
  return;
}
      success = await bleService.sendMessage(text, messageId: message.id);
    } else {
      // Peripheral mode: send via notifications
      success = await _sendPeripheralMessage(text, message.id);
    }
    
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
    final failedMessage = message.copyWith(status: MessageStatus.failed);
    await _messageRepository.updateMessage(failedMessage);
    setState(() {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        _messages[index] = failedMessage;
      }
    });
    
    final errorMsg = e.toString().contains('Write characteristic failed') 
        ? 'Message failed - device may be disconnected'
        : 'Message failed - please retry';
    _showError(errorMsg);
  }
}

Future<bool> _sendPeripheralMessage(String content, String messageId) async {
  final bleService = ref.read(bleServiceProvider);
  
  // For peripheral mode, we need to send via notifications
  // This requires the BLE service to handle peripheral message sending
  return await bleService.sendPeripheralMessage(content, messageId: messageId);
}

  Future<void> _retryMessage(Message failedMessage) async {
    final bleService = ref.read(bleServiceProvider);
    
    // Check if connected first
    if (!bleService.isConnected) {
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
  
  if (otherPersistentId != null && myPersistentId != null) {
    final newChatId = ChatUtils.generateChatId(myPersistentId, otherPersistentId);
    
    if (newChatId != _currentChatId) {
      _logger.info('Identity received - migrating from $_currentChatId to $newChatId');
      await _migrateMessages(_currentChatId!, newChatId);
      _currentChatId = newChatId;
      await _loadMessages(); // Reload with new chat ID
    }
  }
}

Future<void> _requestIdentityExchange() async {
  final bleService = ref.read(bleServiceProvider);
  
  if (!bleService.isConnected) {
    _showError('Not connected to request identity');
    return;
  }
  
  _showSuccess('Requesting identity exchange...');
  
  try {
    await bleService.requestIdentityExchange();
    _showSuccess('Identity request sent');
  } catch (e) {
    _showError('Failed to request identity: $e');
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


  void _showConnectionInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Connection Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device: $_deviceDisplayName'),
            SizedBox(height: 8),
            Text('Status: ${ref.read(bleServiceProvider).isConnected ? "Connected" : "Disconnected"}'),
            SizedBox(height: 8),
            Text('Messages sent: ${_messages.where((m) => m.isFromMe).length}'),
            Text('Messages received: ${_messages.where((m) => !m.isFromMe).length}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
     _logger.warning('Error: $message');
  }

  void _showSuccess(String message) {
    _logger.info('Success: $message');
  }

String _getConnectionStatusText(ConnectionInfo? connectionInfo) {
  if (_isRepositoryMode) return 'Offline - Message history';
  if (_isContact) return 'Verified Contact • ECDH';
  if (_hasPaired) return 'Secured • Paired';
  if (connectionInfo?.isReady ?? false) return 'Connected • Tap lock to secure';
  if (connectionInfo?.isConnected ?? false) return 'Setting up...';
  return connectionInfo?.statusMessage ?? 'Disconnected';
}

Color _getConnectionStatusColor(ConnectionInfo? connectionInfo) {
  if (_isContact) return Colors.green;
  if (_hasPaired) return Colors.blue;
  if (connectionInfo?.isReady ?? false) return Colors.orange;
  if (connectionInfo?.isConnected ?? false) return Colors.yellow.shade700;
  return Colors.red;
}
  
  @override
void dispose() {
  _messageSubscription?.cancel();
  _messageController.dispose();
  _scrollController.dispose();
  super.dispose();
}
}
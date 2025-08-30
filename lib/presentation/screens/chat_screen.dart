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
import '../../core/models/connection_state.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final Peripheral? device;      // For central mode
  final Central? central;        // For peripheral mode
  
  const ChatScreen({
    super.key, 
    this.device,
    this.central,
  }) : assert(device != null || central != null, 'Either device or central must be provided');

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
  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  String? _currentChatId;
  String get _chatId => _currentChatId!;
  bool get _isPeripheralMode => widget.central != null;
  bool get _isCentralMode => widget.device != null;

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
  _loadMessages();
  _setupMessageListener();

  _setupConnectionListener();
  
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _scrollToBottom();
  });
  
  // Start connection monitoring for this chat
}

Future<void> _manualReconnection() async {
  final bleService = ref.read(bleServiceProvider);
  
  _showSuccess('Manually searching for device...');
  
  try {
    final foundDevice = await bleService.scanForSpecificDevice(
  timeout: Duration(seconds: 10)
);
    
    if (foundDevice != null) {
      await bleService.connectToDevice(foundDevice);
      _showSuccess('Manual reconnection successful!');
    } else {
      _showError('Device not found - ensure other device is in discoverable mode');
    }
  } catch (e) {
    _showError('Manual reconnection failed: ${e.toString().split(':').last}');
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

if (_isPeripheralMode) {
    // For peripheral: check if we have active name AND BT is on
    isConnected = bleService.otherUserName != null && 
                  bleService.otherUserName!.isNotEmpty &&
                  bleService.state == BluetoothLowEnergyState.poweredOn;
  } else {
    isConnected = bleService.isConnected;
  }

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
   ref.listen(nameChangesProvider, (previous, next) {
    if (next.hasValue && next.value != null && next.value!.isNotEmpty) {
      _handleIdentityReceived();
    }
  });
  try {
    final bleService = ref.watch(bleServiceProvider);
final connectionStateAsync = ref.watch(connectionStateStreamProvider);
final nameAsync = ref.watch(nameChangesProvider);
final bleStateAsync = ref.watch(bleStateProvider);
final advertisingStateAsync = ref.watch(advertisingStateProvider);

final isConnected = connectionStateAsync.maybeWhen(
  data: (connected) => connected,
  orElse: () => bleService.isConnected, // Fallback to service
);
final hasNameExchange = nameAsync.maybeWhen(
  data: (name) => name != null && name.isNotEmpty,
  orElse: () => false,
);

    final isMonitoring = bleService.isMonitoring;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Consumer(
              builder: (context, ref, child) {
                final nameAsync = ref.watch(nameChangesProvider);
                
                return nameAsync.when(
                  data: (otherName) {
                    if (otherName != null && otherName.isNotEmpty) {
                      return Text(
                        'Chat with $otherName',
                        style: Theme.of(context).textTheme.titleMedium,
                      );
                    } else {
                      return Text(
                        'Device $_deviceDisplayName...',
                        style: Theme.of(context).textTheme.titleMedium,
                      );
                    }
                  },
                  loading: () => Text(
                    'Device $_deviceDisplayName...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  error: (err, stack) => Text(
                    'Device $_deviceDisplayName...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                );
              },
            ),
            Consumer(
  builder: (context, ref, child) {
    final connectionInfoAsync = ref.watch(connectionInfoProvider);
    
    return connectionInfoAsync.when(
      data: (info) => Text(
        info.statusMessage ?? 'Disconnected',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: info.isReady ? Colors.green : (info.isConnected ? Colors.orange : Colors.red),
        ),
      ),
      loading: () => Text(
        isConnected 
          ? (hasNameExchange ? 'Ready to chat' : 'Setting up chat...')
          : 'Connecting...',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: isConnected ? Colors.orange : Colors.grey
        ),
      ),
      error: (err, stack) => Text(
        isConnected ? 'Connected' : 'Disconnected',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: isConnected ? Colors.green : Colors.red,
        ),
      ),
    );
  },
),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => _showConnectionInfo(),
            icon: Icon(
              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: isConnected ? Colors.green : Colors.red,
            ),
          ),
        ],
      ),
      body: SafeArea(
        bottom: true,
        child: Column(
          children: [
            if (!isConnected && (
    (!bleService.isPeripheralMode && isMonitoring) ||
    (bleService.isPeripheralMode))) _buildReconnectionBanner(),
            
            // Messages list - clean, no auto-retry banner
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
                            // Show retry indicator after last message
                            if (index == _messages.length) {
                              return _buildSubtleRetryIndicator();
                            }
                            // Show regular message
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
            
            // Message input - this will be fixed at bottom
            _buildMessageInput(isConnected, hasNameExchange),
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
    return Consumer(
      builder: (context, ref, child) {
        final advertisingStateAsync = ref.watch(advertisingStateProvider);
        
        return advertisingStateAsync.when(
          data: (state) {
            switch (state) {
              case 'starting':
                return Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(12),
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Row(
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 8),
                      Text('Starting advertising...', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                );
              case 'active':
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
              case 'failed':
                return Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(12),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Row(
                    children: [
                      Icon(Icons.error, size: 16),
                      SizedBox(width: 8),
                      Text('Advertising failed - Please try switching modes', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                );
              default:
                return SizedBox.shrink();
            }
          },
          loading: () => SizedBox.shrink(),
          error: (err, stack) => SizedBox.shrink(),
        );
      },
    );
  } else {
    // Central mode - show scanning/reconnection status
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
    child: Row( // CHANGED: Remove Column wrapper, no typing display
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
final canSend = hasText && isConnected && hasNameExchange;
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
      // Check connection state based on mode
bool isConnected;
if (_isCentralMode) {
  isConnected = bleService.isConnected;
} else {
  isConnected = bleService.otherDevicePersistentId != null;
}

if (!isConnected) {
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
  final bleService = ref.read(bleServiceProvider);
  final otherPersistentId = bleService.otherDevicePersistentId;
  final myPersistentId = bleService.myPersistentId;
  
  if (otherPersistentId != null && myPersistentId != null) {
    return ChatUtils.generateChatId(myPersistentId, otherPersistentId);
  }
  
  // Device-specific temp fallback (not shared)
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

void _setupConnectionListener() {
  _connectionSubscription?.cancel();
  final bleService = ref.read(bleServiceProvider);
  
  _connectionSubscription = ref.read(connectionStateStreamProvider.stream).listen((isConnected) {
    if (mounted) {
      _logger.info('Chat screen received connection state: $isConnected');
      setState(() {});
      
      if (isConnected) {
        _showSuccess('Device reconnected! âœ…');
        Future.delayed(Duration(milliseconds: 2500), () {
          if (mounted) {
            _autoRetryFailedMessages();
          }
        });
      } else {
        _showError('Device disconnected âŒ');
        
        if (!bleService.isPeripheralMode) {
          bleService.startConnectionMonitoring();
        }
        // Peripheral mode: just wait for incoming connections, don't monitor
      }
    }
  });
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

String _getConnectionStatusText(bool isConnected, bool hasNameExchange) {
  if (hasNameExchange) return 'Ready to chat';
  if (isConnected) return 'Setting up chat...';
  return 'Disconnected';
}

Color _getConnectionStatusColor(bool isConnected, bool hasNameExchange) {
  if (hasNameExchange) return Colors.green;
  if (isConnected) return Colors.orange;
  return Colors.red;
}
  
  @override
void dispose() {
  _connectionSubscription?.cancel();
  _messageSubscription?.cancel();
  _messageController.dispose();
  _scrollController.dispose();
  super.dispose();
}
}
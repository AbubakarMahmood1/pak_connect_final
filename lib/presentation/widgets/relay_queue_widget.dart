import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../core/utils/mesh_debug_logger.dart';
import '../../core/utils/app_logger.dart';
import '../../domain/entities/enhanced_message.dart';

/// Widget for displaying and managing relay message queue
/// Shows pending messages, delivery status, and manual retry options
class RelayQueueWidget extends StatefulWidget {
  final MeshNetworkingService meshService;
  final VoidCallback? onRequestClose;
  
  const RelayQueueWidget({
    super.key, 
    required this.meshService,
    this.onRequestClose,
  });
  
  @override
  // ignore: library_private_types_in_public_api
  _RelayQueueWidgetState createState() => _RelayQueueWidgetState();
}

class _RelayQueueWidgetState extends State<RelayQueueWidget> {
  static final _logger = AppLogger.getLogger(LoggerNames.ui);
  Timer? _loadingTimeout;
  bool _timeoutReached = false;

  @override
  void initState() {
    super.initState();
    // Start timeout timer for loading state
    _startLoadingTimeout();
  }

  @override
  void dispose() {
    _loadingTimeout?.cancel();
    super.dispose();
  }

  /// Start timeout timer for loading state
  void _startLoadingTimeout() {
    _loadingTimeout?.cancel();
    _loadingTimeout = Timer(Duration(seconds: 10), () {
      if (mounted) {
        setState(() {
          _timeoutReached = true;
        });
        MeshDebugLogger.warning('RelayQueueWidget', 'Loading timeout reached - mesh status stream not providing data');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MeshNetworkStatus>(
      stream: widget.meshService.meshStatus,
      builder: (context, snapshot) {
        final status = snapshot.data;

        // 🔍 DEBUG: Log what RelayQueueWidget is receiving
        _logger.fine('🔍 RELAY QUEUE WIDGET DEBUG:');
        _logger.fine('  - snapshot.hasData: ${snapshot.hasData}');
        _logger.fine('  - snapshot.hasError: ${snapshot.hasError}');
        _logger.fine('  - status == null: ${status == null}');
        if (status != null) {
          _logger.fine('  - status.isInitialized: ${status.isInitialized}');
          _logger.fine('  - status.queueMessages: ${status.queueMessages?.length ?? "null"}');
          if (status.queueMessages != null && status.queueMessages!.isNotEmpty) {
            final content = status.queueMessages!.first.content;
            final preview = content.length > 20 ? '${content.substring(0, 20)}...' : content;
            _logger.fine('  - First message: $preview');
          }
        }

        if (status == null) {
          _logger.fine('ℹ️ RelayQueueWidget: Loading state displayed - MeshNetworkStatus is null');
          // Cancel timeout if we get data
          if (_timeoutReached) {
            _loadingTimeout?.cancel();
            return _buildTimeoutState();
          }
          return _buildLoadingState();
        }

        // Reset timeout state when we get data (defer to avoid setState during build)
        if (_timeoutReached) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _timeoutReached = false;
              });
              _loadingTimeout?.cancel();
            }
          });
        }
        
        return Card(
          elevation: 2,
          margin: EdgeInsets.all(8),
          child: Column(
            children: [
              // 📋 Header with queue summary
              _buildQueueHeader(status),
              
              // 📝 Queue content list
              Expanded(
                child: _buildQueueList(status),
              ),
              
              // 🔄 Action buttons
              if (status.statistics.queueStatistics != null && 
                  status.statistics.queueStatistics!.pendingMessages > 0)
                _buildActionButtons(),
            ],
          ),
        );
      },
    );
  }
  
  /// Build loading state while waiting for mesh status
  Widget _buildLoadingState() {
    // Add diagnostic logging
    MeshDebugLogger.info('RelayQueueWidget', 'Loading state displayed - MeshNetworkStatus is null');

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading relay queue...', style: TextStyle(color: Colors.grey[600])),
          SizedBox(height: 8),
          Text('Initializing mesh network...', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
        ],
      ),
    );
  }

  /// Build state when loading timeout is reached
  Widget _buildTimeoutState() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 64,
              color: Colors.orange[400],
            ),
            SizedBox(height: 16),
            Text(
              'Connection Timeout',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.orange[700],
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Unable to load relay queue status. This may indicate a connection issue.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
            SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _timeoutReached = false;
                    });
                    _startLoadingTimeout();
                    MeshDebugLogger.info('RelayQueueWidget', 'Retry after timeout requested');
                  },
                  icon: Icon(Icons.refresh),
                  label: Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange[600],
                    foregroundColor: Colors.white,
                  ),
                ),
                SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () => _handleCloseRequest(),
                  icon: Icon(Icons.close),
                  label: Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  /// Build queue header with summary information
  Widget _buildQueueHeader(MeshNetworkStatus status) {
    final queueStats = status.statistics.queueStatistics;
    final pendingCount = queueStats?.pendingMessages ?? 0;
    final sendingCount = queueStats?.sendingMessages ?? 0;
    final retryingCount = queueStats?.retryingMessages ?? 0;
    final isOnline = queueStats?.isOnline ?? false;
    
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isOnline ? Colors.green[50] : Colors.orange[50],
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
      ),
      child: Row(
        children: [
          // Queue icon with status color
          Icon(
            Icons.queue,
            color: isOnline ? Colors.green[700] : Colors.orange[700],
            size: 28,
          ),
          SizedBox(width: 12),
          
          // Title and subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '📤 Relay Queue',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  _buildQueueSummary(pendingCount, sendingCount, retryingCount, isOnline),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          
          // Connection status indicator
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isOnline ? Colors.green : Colors.orange,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              isOnline ? '🌐 Online' : '🔌 Offline',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          
          // Refresh button
          IconButton(
            icon: Icon(Icons.refresh, color: Colors.grey[600]),
            onPressed: () => _refreshQueue(),
            tooltip: 'Refresh queue status',
          ),
        ],
      ),
    );
  }
  
  /// Build summary text for queue status
  String _buildQueueSummary(int pending, int sending, int retrying, bool isOnline) {
    final totalActive = pending + sending + retrying;
    
    if (totalActive == 0) {
      return 'No messages in queue';
    }
    
    final parts = <String>[];
    if (pending > 0) parts.add('$pending pending');
    if (sending > 0) parts.add('$sending sending');
    if (retrying > 0) parts.add('$retrying retrying');
    
    final statusText = parts.join(' • ');
    final connectionText = isOnline ? 'Ready to deliver' : 'Waiting for connection';
    
    return '$statusText • $connectionText';
  }
  
  /// Build the main queue list
  Widget _buildQueueList(MeshNetworkStatus status) {
    final queueMessages = status.queueMessages;

    // 🔍 DEBUG: Log queue list building
    _logger.fine('🔍 BUILDING QUEUE LIST:');
    _logger.fine('  - queueMessages == null: ${queueMessages == null}');
    _logger.fine('  - queueMessages.length: ${queueMessages?.length ?? "null"}');

    if (queueMessages == null) {
      _logger.fine('  - Returning: Queue information unavailable');
      return _buildEmptyState('Queue information unavailable');
    }

    if (queueMessages.isEmpty) {
      _logger.fine('  - Returning: No messages in relay queue');
      return _buildEmptyState('No messages in relay queue');
    }

    _logger.fine('  - Returning: ListView with ${queueMessages.length} messages');

    return ListView.builder(
      padding: EdgeInsets.symmetric(vertical: 8),
      itemCount: queueMessages.length,
      itemBuilder: (context, index) => _buildRealQueueItem(queueMessages[index]),
    );
  }
  
  /// Build empty state when no messages
  Widget _buildEmptyState(String message) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
            SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[600],
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Messages will appear here when queued for relay',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  /// Build real queue item from QueuedMessage
  Widget _buildRealQueueItem(QueuedMessage message) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 1,
      child: ListTile(
        leading: _buildRealMessageIcon(message),
        title: Text(_buildRealMessageTitle(message)),
        subtitle: Text(_buildRealMessageSubtitle(message)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Priority indicator
            Container(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _getPriorityColor(message.priority),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                message.priority.name.toUpperCase(),
                style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            SizedBox(width: 8),

            // Action button
            _buildRealActionButton(message),
          ],
        ),
      ),
    );
  }

  /// Build icon for real message based on status and type
  Widget _buildRealMessageIcon(QueuedMessage message) {
    if (message.status == QueuedMessageStatus.sending) {
      return CircularProgressIndicator(strokeWidth: 2);
    } else if (message.status == QueuedMessageStatus.retrying) {
      return Icon(Icons.refresh, color: Colors.orange[600]);
    } else if (message.isRelayMessage) {
      return CircleAvatar(
        backgroundColor: Colors.purple[100],
        child: Icon(Icons.route, color: Colors.purple[700], size: 20),
      );
    } else {
      return CircleAvatar(
        backgroundColor: Colors.blue[100],
        child: Icon(Icons.message, color: Colors.blue[700], size: 20),
      );
    }
  }

  /// Build title for real message
  String _buildRealMessageTitle(QueuedMessage message) {
    if (message.status == QueuedMessageStatus.sending) {
      return 'Sending message...';
    } else if (message.status == QueuedMessageStatus.retrying) {
      return 'Retrying message delivery (${message.attempts}/${message.maxRetries})';
    } else if (message.isRelayMessage && message.relayMetadata != null) {
      return 'Relay: "${_truncateContent(message.content)}"';
    } else {
      return 'Direct: "${_truncateContent(message.content)}"';
    }
  }

  /// Build subtitle for real message
  String _buildRealMessageSubtitle(QueuedMessage message) {
    final recipientShort = message.recipientPublicKey.length > 12
        ? '${message.recipientPublicKey.substring(0, 12)}...'
        : message.recipientPublicKey;

    if (message.status == QueuedMessageStatus.sending) {
      return 'To: $recipientShort';
    } else if (message.status == QueuedMessageStatus.retrying) {
      return 'To: $recipientShort • Next retry in ${_getRetryTime(message)}';
    } else if (message.isRelayMessage && message.relayMetadata != null) {
      return 'Final recipient: $recipientShort • Hop ${message.relayMetadata!.hopCount}/${message.relayMetadata!.ttl}';
    } else {
      return 'To: $recipientShort • Queued ${_getQueueTime(message)}';
    }
  }

  /// Build action button for real message
  Widget _buildRealActionButton(QueuedMessage message) {
    if (message.status == QueuedMessageStatus.sending) {
      return SizedBox(width: 24); // Empty space during sending
    }

    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: Colors.grey[600]),
      onSelected: (value) => _handleRealMessageAction(value, message),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'retry',
          child: Row(
            children: [
              Icon(Icons.send, color: Colors.green[600], size: 18),
              SizedBox(width: 8),
              Text('Retry Now'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'priority',
          child: Row(
            children: [
              Icon(Icons.priority_high, color: Colors.orange[600], size: 18),
              SizedBox(width: 8),
              Text('Set High Priority'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.delete, color: Colors.red[600], size: 18),
              SizedBox(width: 8),
              Text('Remove'),
            ],
          ),
        ),
      ],
    );
  }

  /// Get priority color
  Color _getPriorityColor(MessagePriority priority) {
    switch (priority) {
      case MessagePriority.urgent:
        return Colors.red[600]!;
      case MessagePriority.high:
        return Colors.orange[600]!;
      case MessagePriority.normal:
        return Colors.blue[600]!;
      case MessagePriority.low:
        return Colors.grey[600]!;
    }
  }

  /// Truncate content for display
  String _truncateContent(String content) {
    if (content.length <= 30) return content;
    return '${content.substring(0, 30)}...';
  }

  /// Get retry time string
  String _getRetryTime(QueuedMessage message) {
    if (message.nextRetryAt == null) return 'soon';
    final diff = message.nextRetryAt!.difference(DateTime.now());
    if (diff.isNegative) return 'now';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m';
    return '${diff.inSeconds}s';
  }

  /// Get queue time string
  String _getQueueTime(QueuedMessage message) {
    final diff = DateTime.now().difference(message.queuedAt);
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return '${diff.inSeconds}s ago';
  }

  /// Build action buttons at bottom of queue
  Widget _buildActionButtons() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ElevatedButton.icon(
            onPressed: () => _retryAllMessages(),
            icon: Icon(Icons.send_outlined, size: 18),
            label: Text('Retry All'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green[600],
              foregroundColor: Colors.white,
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _clearFailedMessages(),
            icon: Icon(Icons.clear_all, size: 18),
            label: Text('Clear Failed'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange[700],
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _showQueueDetails(),
            icon: Icon(Icons.info_outline, size: 18),
            label: Text('Details'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.blue[700],
            ),
          ),
        ],
      ),
    );
  }
  
  // Action handlers
  
  void _refreshQueue() {
    setState(() {});
    MeshDebugLogger.info('UI Action', 'Queue refresh requested');
  }
  
  /// Handle real message actions
  void _handleRealMessageAction(String action, QueuedMessage message) {
    switch (action) {
      case 'retry':
        _retryRealMessage(message);
        break;
      case 'priority':
        _setPriorityReal(message);
        break;
      case 'remove':
        _removeRealMessage(message);
        break;
    }
  }

  /// Real action methods that interact with MeshNetworkingService

  void _retryRealMessage(QueuedMessage message) async {
    try {
      final success = await widget.meshService.retryMessage(message.id);
      final messageIdShort = message.id.length > 16 ? message.id.substring(0, 16) : message.id;

      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? '🔄 Retrying message $messageIdShort...'
              : '❌ Failed to retry message $messageIdShort...'),
          backgroundColor: success ? Colors.green[600] : Colors.red[600],
        ),
      );

      MeshDebugLogger.info('UI Action', 'Real retry ${success ? "successful" : "failed"} for message $messageIdShort...');
    } catch (e) {
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error retrying message: $e'),
          backgroundColor: Colors.red[600],
        ),
      );
    }
  }

  void _setPriorityReal(QueuedMessage message) async {
    try {
      final success = await widget.meshService.setPriority(message.id, MessagePriority.high);
      final messageIdShort = message.id.length > 16 ? message.id.substring(0, 16) : message.id;

      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? '⚡ Priority updated for $messageIdShort...'
              : '⚠️ Priority update not supported for $messageIdShort...'),
          backgroundColor: success ? Colors.orange[600] : Colors.grey[600],
        ),
      );

      MeshDebugLogger.info('UI Action', 'Real priority change ${success ? "successful" : "failed"} for message $messageIdShort...');
    } catch (e) {
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error setting priority: $e'),
          backgroundColor: Colors.red[600],
        ),
      );
    }
  }

  void _removeRealMessage(QueuedMessage message) async {
    try {
      final success = await widget.meshService.removeMessage(message.id);
      final messageIdShort = message.id.length > 16 ? message.id.substring(0, 16) : message.id;

      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? '🗑️ Message $messageIdShort... removed from queue'
              : '❌ Failed to remove message $messageIdShort...'),
          backgroundColor: success ? Colors.red[600] : Colors.grey[600],
        ),
      );

      MeshDebugLogger.info('UI Action', 'Real removal ${success ? "successful" : "failed"} for message $messageIdShort...');
    } catch (e) {
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error removing message: $e'),
          backgroundColor: Colors.red[600],
        ),
      );
    }
  }
  
  void _retryAllMessages() async {
    try {
      final retriedCount = await widget.meshService.retryAllMessages();

      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(retriedCount > 0
              ? '🚀 Retrying $retriedCount failed messages...'
              : '✅ No failed messages to retry'),
          backgroundColor: Colors.green[600],
        ),
      );

      MeshDebugLogger.info('UI Action', 'Retry all messages: $retriedCount messages queued for retry');
    } catch (e) {
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error retrying messages: $e'),
          backgroundColor: Colors.red[600],
        ),
      );
    }
  }
  
  void _clearFailedMessages() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🧹 Failed messages cleared'),
        backgroundColor: Colors.orange[600],
      ),
    );
    MeshDebugLogger.info('UI Action', 'Clear failed messages requested');
  }
  
  void _showQueueDetails() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('📊 Queue Details'),
        content: Text('Detailed queue statistics and performance metrics would be shown here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
    MeshDebugLogger.info('UI Action', 'Queue details dialog requested');
  }
  
  /// Handle close request with proper coordination
  void _handleCloseRequest() {
    MeshDebugLogger.info('RelayQueueWidget', 'Close request - using coordinated close');
    
    // First, cancel any active timers to prevent memory leaks
    _loadingTimeout?.cancel();
    
    // Use callback if provided (for tab-based integration)
    if (widget.onRequestClose != null) {
      widget.onRequestClose!();
    } else {
      // Fallback: Only pop if this is actually a separate screen
      // Check if we're in a tab view by examining the route
      final route = ModalRoute.of(context);
      if (route != null && route.isFirst == false) {
        Navigator.pop(context);
      } else {
        MeshDebugLogger.warning('RelayQueueWidget', 'Cannot close - appears to be in tab view without callback');
      }
    }
  }
}
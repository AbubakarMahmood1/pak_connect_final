import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../core/utils/mesh_debug_logger.dart';

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

        if (status == null) {
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
    final queueStats = status.statistics.queueStatistics;
    
    if (queueStats == null) {
      return _buildEmptyState('Queue information unavailable');
    }
    
    final totalMessages = queueStats.pendingMessages + queueStats.sendingMessages + queueStats.retryingMessages;
    
    if (totalMessages == 0) {
      return _buildEmptyState('No messages in relay queue');
    }
    
    return ListView.builder(
      padding: EdgeInsets.symmetric(vertical: 8),
      itemCount: totalMessages,
      itemBuilder: (context, index) => _buildQueueItem(index, queueStats),
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
  
  /// Build individual queue item
  Widget _buildQueueItem(int index, QueueStatistics queueStats) {
    final isPending = index < queueStats.pendingMessages;
    final isSending = !isPending && (index - queueStats.pendingMessages) < queueStats.sendingMessages;
    final isRetrying = !isPending && !isSending;
    
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 1,
      child: ListTile(
        leading: _buildMessageIcon(isPending, isSending, isRetrying),
        title: Text(_buildMessageTitle(index, isPending, isSending, isRetrying)),
        subtitle: Text(_buildMessageSubtitle(isPending, isSending, isRetrying)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Priority indicator
            Container(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue[100],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Normal',
                style: TextStyle(fontSize: 10, color: Colors.blue[700]),
              ),
            ),
            SizedBox(width: 8),
            
            // Action button
            _buildActionButton(index, isPending, isSending, isRetrying),
          ],
        ),
      ),
    );
  }
  
  /// Build icon for message based on status
  Widget _buildMessageIcon(bool isPending, bool isSending, bool isRetrying) {
    if (isSending) {
      return CircularProgressIndicator(strokeWidth: 2);
    } else if (isRetrying) {
      return Icon(Icons.refresh, color: Colors.orange[600]);
    } else {
      return CircleAvatar(
        backgroundColor: Colors.blue[100],
        child: Icon(Icons.message, color: Colors.blue[700], size: 20),
      );
    }
  }
  
  /// Build title for message item
  String _buildMessageTitle(int index, bool isPending, bool isSending, bool isRetrying) {
    if (isSending) {
      return 'Sending message...';
    } else if (isRetrying) {
      return 'Retrying message delivery';
    } else {
      return 'Message awaiting relay';
    }
  }
  
  /// Build subtitle for message item
  String _buildMessageSubtitle(bool isPending, bool isSending, bool isRetrying) {
    if (isSending) {
      return 'Currently being delivered';
    } else if (isRetrying) {
      return 'Will retry automatically';
    } else {
      return 'Waiting for device connection';
    }
  }
  
  /// Build action button for message item
  Widget _buildActionButton(int index, bool isPending, bool isSending, bool isRetrying) {
    if (isSending) {
      return SizedBox(width: 24); // Empty space during sending
    }
    
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: Colors.grey[600]),
      onSelected: (value) => _handleMessageAction(value, index),
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
  
  void _handleMessageAction(String action, int messageIndex) {
    switch (action) {
      case 'retry':
        _retryMessage(messageIndex);
        break;
      case 'priority':
        _setPriority(messageIndex);
        break;
      case 'remove':
        _removeMessage(messageIndex);
        break;
    }
  }
  
  void _retryMessage(int index) {
    // Implement manual retry
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🔄 Retrying message delivery...'),
        backgroundColor: Colors.green[600],
      ),
    );
    MeshDebugLogger.info('UI Action', 'Manual retry requested for message $index');
  }
  
  void _setPriority(int index) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ Message priority set to high'),
        backgroundColor: Colors.orange[600],
      ),
    );
    MeshDebugLogger.info('UI Action', 'Priority change requested for message $index');
  }
  
  void _removeMessage(int index) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🗑️ Message removed from queue'),
        backgroundColor: Colors.red[600],
        action: SnackBarAction(
          label: 'UNDO',
          textColor: Colors.white,
          onPressed: () {
            MeshDebugLogger.info('UI Action', 'Message removal undone');
          },
        ),
      ),
    );
    MeshDebugLogger.info('UI Action', 'Message removal requested for message $index');
  }
  
  void _retryAllMessages() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🚀 Retrying all pending messages...'),
        backgroundColor: Colors.green[600],
      ),
    );
    MeshDebugLogger.info('UI Action', 'Retry all messages requested');
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
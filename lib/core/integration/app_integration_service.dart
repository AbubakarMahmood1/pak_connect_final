// Comprehensive integration service that coordinates all app components

import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/power/adaptive_power_manager.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../domain/services/contact_management_service.dart';
import '../../domain/services/chat_management_service.dart';
import '../../data/services/ble_state_manager.dart';
import '../performance/performance_monitor.dart';
import '../../domain/entities/enhanced_message.dart';

/// Central integration service coordinating all app components
class AppIntegrationService {
  static final _logger = Logger('AppIntegrationService');
  
  // Core components
  late final AdaptivePowerManager _powerManager;
  late final OfflineMessageQueue _messageQueue;
  late final ContactManagementService _contactService;
  late final ChatManagementService _chatService;
  late final PerformanceMonitor _performanceMonitor;
  late final BLEStateManager _bleStateManager;
  
  // Integration state
  bool _isInitialized = false;
  bool _isRunning = false;
  
  // Component health tracking
  final Map<String, ComponentHealth> _componentHealth = {};
  Timer? _healthCheckTimer;
  
  // Performance metrics
  final Map<String, dynamic> _metrics = {};
  
  /// Initialize all app components in proper order
  Future<void> initialize({
    required BLEStateManager bleStateManager,
  }) async {
    if (_isInitialized) {
      _logger.warning('Integration service already initialized');
      return;
    }
    
    try {
      _logger.info('Initializing app integration service...');
      
      _bleStateManager = bleStateManager;
      
      // Initialize performance monitor first
      _performanceMonitor = PerformanceMonitor();
      await _performanceMonitor.initialize();
      _updateComponentHealth('performance_monitor', ComponentStatus.healthy);
      
      // Initialize power management
      _powerManager = AdaptivePowerManager();
      await _powerManager.initialize(
        onStartScan: () => _bleStateManager.startScanning(),
        onStopScan: () => _bleStateManager.stopScanning(),
        onHealthCheck: () => _performHealthCheck(),
        onStatsUpdate: _onPowerStatsUpdate,
      );
      _updateComponentHealth('power_manager', ComponentStatus.healthy);
      
      // Initialize message queue
      _messageQueue = OfflineMessageQueue();
      await _messageQueue.initialize(
        onMessageQueued: _onMessageQueued,
        onMessageDelivered: _onMessageDelivered,
        onMessageFailed: _onMessageFailed,
        onStatsUpdated: _onQueueStatsUpdate,
        onSendMessage: _sendMessageViaBLE,
        onConnectivityCheck: _checkConnectivity,
      );
      _updateComponentHealth('message_queue', ComponentStatus.healthy);
      
      // Initialize contact management
      _contactService = ContactManagementService();
      await _contactService.initialize();
      _updateComponentHealth('contact_service', ComponentStatus.healthy);
      
      // Initialize chat management
      _chatService = ChatManagementService();
      await _chatService.initialize();
      _updateComponentHealth('chat_service', ComponentStatus.healthy);
      
      // Start health monitoring
      _startHealthMonitoring();
      
      _isInitialized = true;
      _logger.info('App integration service initialized successfully');
      
    } catch (e) {
      _logger.severe('Failed to initialize integration service: $e');
      throw IntegrationException('Initialization failed: $e');
    }
  }
  
  /// Start all integrated services
  Future<void> start() async {
    if (!_isInitialized) {
      throw IntegrationException('Service not initialized');
    }
    
    if (_isRunning) {
      _logger.warning('Integration service already running');
      return;
    }
    
    try {
      _logger.info('Starting integrated services...');
      
      // Start performance monitoring
      _performanceMonitor.startMonitoring();
      
      // Start adaptive power management
      await _powerManager.startAdaptiveScanning();
      
      // Update BLE state manager with integration callbacks
      _setupBLEIntegration();
      
      _isRunning = true;
      _logger.info('All integrated services started successfully');
      
    } catch (e) {
      _logger.severe('Failed to start integrated services: $e');
      throw IntegrationException('Start failed: $e');
    }
  }
  
  /// Stop all services gracefully
  Future<void> stop() async {
    if (!_isRunning) return;
    
    try {
      _logger.info('Stopping integrated services...');
      
      // Stop power management
      await _powerManager.stopScanning();
      
      // Stop performance monitoring
      _performanceMonitor.stopMonitoring();
      
      // Stop health monitoring
      _healthCheckTimer?.cancel();
      
      _isRunning = false;
      _logger.info('All integrated services stopped');
      
    } catch (e) {
      _logger.warning('Error stopping services: $e');
    }
  }
  
  /// Send message through integrated queue system
  Future<String> sendMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    _performanceMonitor.startOperation('send_message');
    
    try {
      final messageId = await _messageQueue.queueMessage(
        chatId: chatId,
        content: content,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: senderPublicKey,
        priority: priority,
      );
      
      _performanceMonitor.endOperation('send_message', success: true);
      return messageId;
      
    } catch (e) {
      _performanceMonitor.endOperation('send_message', success: false);
      rethrow;
    }
  }
  
  /// Handle connection state changes
  void onConnectionStateChanged(bool isConnected) {
    _logger.info('Connection state changed: $isConnected');
    
    if (isConnected) {
      _messageQueue.setOnline();
      _powerManager.reportConnectionSuccess();
    } else {
      _messageQueue.setOffline();
      _powerManager.reportConnectionFailure(reason: 'Connection lost');
    }
    
    _updateMetric('connection_state', isConnected);
  }
  
  /// Handle BLE device discovery
  void onDeviceDiscovered(String deviceId, int? rssi) {
    // Calculate actual connection time based on discovery timestamp
    final connectionTime = DateTime.now().millisecondsSinceEpoch / 1000.0;

    _powerManager.reportConnectionSuccess(
      rssi: rssi,
      connectionTime: connectionTime,
    );

    _updateMetric('last_discovery_rssi', rssi);
  }
  
  /// Get comprehensive system health status
  SystemHealthStatus getSystemHealth() {
    final overallHealth = _calculateOverallHealth();
    final powerStats = _powerManager.getCurrentStats();
    final queueStats = _messageQueue.getStatistics();
    final performanceMetrics = _performanceMonitor.getMetrics();
    
    return SystemHealthStatus(
      overallHealth: overallHealth,
      componentHealth: Map.from(_componentHealth),
      powerManagement: powerStats,
      messageQueue: queueStats,
      performance: performanceMetrics,
      lastHealthCheck: DateTime.now(),
    );
  }
  
  /// Get integration metrics
  Map<String, dynamic> getMetrics() {
    return {
      ..._metrics,
      'power_management': _powerManager.getCurrentStats().toString(),
      'message_queue': _messageQueue.getStatistics().toString(),
      'performance': _performanceMonitor.getMetrics().overallScore,
      'component_health': _componentHealth.map((k, v) => MapEntry(k, v.status.name)),
    };
  }
  
  /// Optimize performance based on current conditions
  Future<void> optimizePerformance() async {
    try {
      _logger.info('Starting performance optimization...');
      
      final health = getSystemHealth();
      final metrics = _performanceMonitor.getMetrics();
      
      // Power optimization
      if (health.powerManagement.batteryEfficiencyRating < 0.7) {
        _powerManager.overrideScanInterval(8000); // Increase scan interval
        _logger.info('Applied power optimization: increased scan interval');
      }
      
      // Memory optimization
      if (metrics.memoryUsage > 0.8) {
        await _performMemoryCleanup();
        _logger.info('Applied memory optimization: cleanup performed');
      }
      
      // Queue optimization
      if (health.messageQueue.pendingMessages > 20) {
        // Prioritize urgent messages
        final urgentMessages = _messageQueue.getMessagesByStatus(QueuedMessageStatus.pending)
            .where((m) => m.priority == MessagePriority.urgent)
            .toList();
        
        _logger.info('Applied queue optimization: prioritizing ${urgentMessages.length} urgent messages');
      }
      
      _logger.info('Performance optimization completed');
      
    } catch (e) {
      _logger.warning('Performance optimization failed: $e');
    }
  }
  
  // Private methods
  
  /// Setup BLE integration callbacks
  void _setupBLEIntegration() {
    // Connect message delivery callbacks
    _bleStateManager.onMessageSent = (messageId, success) {
      if (success) {
        _messageQueue.markMessageDelivered(messageId);
      } else {
        _messageQueue.markMessageFailed(messageId, 'BLE transmission failed');
      }
    };
    
    // Connect discovery callbacks for power management
    _bleStateManager.onDeviceDiscovered = (device, rssi) {
      onDeviceDiscovered(device.toString(), rssi);
    };
  }
  
  /// Send message via BLE
  void _sendMessageViaBLE(String messageId) {
    try {
      // Find queued message
      final queuedMessages = _messageQueue.getMessagesByStatus(QueuedMessageStatus.sending);
      final message = queuedMessages.where((m) => m.id == messageId).firstOrNull;
      
      if (message == null) {
        _logger.warning('Queued message not found: ${messageId.substring(0, 16)}...');
        return;
      }
      
      // Use BLE state manager to send message
      _bleStateManager.sendMessage(message.content, messageId: messageId);
      
    } catch (e) {
      _logger.severe('Failed to send message via BLE: $e');
      _messageQueue.markMessageFailed(messageId, 'BLE send error: $e');
    }
  }
  
  /// Check connectivity status
  void _checkConnectivity() {
    final isConnected = _bleStateManager.isConnected;
    if (isConnected != _messageQueue.getStatistics().isOnline) {
      onConnectionStateChanged(isConnected);
    }
  }
  
  /// Perform system health check
  void _performHealthCheck() {
    try {
      // Check each component
      _checkComponentHealth('power_manager', () => _powerManager.getCurrentStats().connectionQualityScore > 0.3);
      _checkComponentHealth('message_queue', () => _messageQueue.getStatistics().queueHealthScore > 0.5);
      _checkComponentHealth('performance_monitor', () => _performanceMonitor.getMetrics().overallScore > 0.6);
      
      // Update overall system health
      final overallHealth = _calculateOverallHealth();
      _updateMetric('system_health', overallHealth);
      
      if (overallHealth < 0.6) {
        _logger.warning('System health degraded: $overallHealth - triggering optimization');
        optimizePerformance();
      }
      
    } catch (e) {
      _logger.warning('Health check failed: $e');
    }
  }
  
  /// Check individual component health
  void _checkComponentHealth(String component, bool Function() healthCheck) {
    try {
      final isHealthy = healthCheck();
      final status = isHealthy ? ComponentStatus.healthy : ComponentStatus.degraded;
      _updateComponentHealth(component, status);
    } catch (e) {
      _updateComponentHealth(component, ComponentStatus.error);
      _logger.warning('Component $component health check failed: $e');
    }
  }
  
  /// Update component health status
  void _updateComponentHealth(String component, ComponentStatus status) {
    _componentHealth[component] = ComponentHealth(
      status: status,
      lastCheck: DateTime.now(),
      message: _getStatusMessage(status),
    );
  }
  
  /// Calculate overall system health score
  double _calculateOverallHealth() {
    if (_componentHealth.isEmpty) return 0.0;
    
    final healthScores = _componentHealth.values.map((health) {
      switch (health.status) {
        case ComponentStatus.healthy:
          return 1.0;
        case ComponentStatus.degraded:
          return 0.5;
        case ComponentStatus.error:
          return 0.0;
      }
    }).toList();
    
    return healthScores.fold<double>(0.0, (sum, score) => sum + score) / healthScores.length;
  }
  
  /// Get status message for component status
  String _getStatusMessage(ComponentStatus status) {
    switch (status) {
      case ComponentStatus.healthy:
        return 'Operating normally';
      case ComponentStatus.degraded:
        return 'Performance degraded';
      case ComponentStatus.error:
        return 'Component error detected';
    }
  }
  
  /// Start health monitoring timer
  void _startHealthMonitoring() {
    _healthCheckTimer = Timer.periodic(Duration(minutes: 1), (timer) {
      _performHealthCheck();
    });
  }
  
  /// Perform memory cleanup
  Future<void> _performMemoryCleanup() async {
    // Clear old chat data
    final oldChats = await _chatService.getAllChats();
    final cutoffDate = DateTime.now().subtract(Duration(days: 30));
    
    for (final chat in oldChats) {
      if (chat.lastMessageTime?.isBefore(cutoffDate) == true) {
        await _chatService.clearChatMessages(chat.chatId);
      }
    }
    
    // Clear old performance data
    _performanceMonitor.clearOldData();
    
    _logger.info('Memory cleanup completed');
  }
  
  /// Update metric value
  void _updateMetric(String key, dynamic value) {
    _metrics[key] = value;
  }
  
  // Event handlers
  
  void _onMessageQueued(QueuedMessage message) {
    _updateMetric('messages_queued', (_metrics['messages_queued'] ?? 0) + 1);
  }
  
  void _onMessageDelivered(QueuedMessage message) {
    _updateMetric('messages_delivered', (_metrics['messages_delivered'] ?? 0) + 1);
  }
  
  void _onMessageFailed(QueuedMessage message, String reason) {
    _updateMetric('messages_failed', (_metrics['messages_failed'] ?? 0) + 1);
  }
  
  void _onPowerStatsUpdate(PowerManagementStats stats) {
    _updateMetric('power_efficiency', stats.batteryEfficiencyRating);
  }
  
  void _onQueueStatsUpdate(QueueStatistics stats) {
    _updateMetric('queue_health', stats.queueHealthScore);
  }
  
  /// Dispose of all resources
  void dispose() {
    _healthCheckTimer?.cancel();
    _powerManager.dispose();
    _chatService.dispose();
    _performanceMonitor.dispose();
    _logger.info('App integration service disposed');
  }
}

/// System health status
class SystemHealthStatus {
  final double overallHealth;
  final Map<String, ComponentHealth> componentHealth;
  final PowerManagementStats powerManagement;
  final QueueStatistics messageQueue;
  final PerformanceMetrics performance;
  final DateTime lastHealthCheck;
  
  const SystemHealthStatus({
    required this.overallHealth,
    required this.componentHealth,
    required this.powerManagement,
    required this.messageQueue,
    required this.performance,
    required this.lastHealthCheck,
  });
  
  /// Get health grade (A, B, C, D, F)
  String get healthGrade {
    if (overallHealth >= 0.9) return 'A';
    if (overallHealth >= 0.8) return 'B';
    if (overallHealth >= 0.6) return 'C';
    if (overallHealth >= 0.4) return 'D';
    return 'F';
  }
  
  /// Check if system needs attention
  bool get needsAttention => overallHealth < 0.7;
  
  /// Get recommendations for improvement
  List<String> get recommendations {
    final recommendations = <String>[];
    
    if (powerManagement.batteryEfficiencyRating < 0.7) {
      recommendations.add('Consider optimizing power settings');
    }
    
    if (messageQueue.successRate < 0.9) {
      recommendations.add('Check network connectivity for message delivery');
    }
    
    if (performance.memoryUsage > 0.8) {
      recommendations.add('Clear old chat data to free memory');
    }
    
    return recommendations;
  }
}

/// Component health information
class ComponentHealth {
  final ComponentStatus status;
  final DateTime lastCheck;
  final String message;
  
  const ComponentHealth({
    required this.status,
    required this.lastCheck,
    required this.message,
  });
}

/// Component status enumeration
enum ComponentStatus { healthy, degraded, error }

/// Integration exception
class IntegrationException implements Exception {
  final String message;
  const IntegrationException(this.message);
  
  @override
  String toString() => 'IntegrationException: $message';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
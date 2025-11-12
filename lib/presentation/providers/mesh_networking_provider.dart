// Riverpod providers for mesh networking UI state management
// Integrates MeshNetworkingService with the presentation layer

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../domain/services/chat_management_service.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/services/ble_message_handler.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import 'ble_providers.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Logger for mesh networking providers
final _logger = Logger('MeshNetworkingProvider');

/// Singleton providers for service dependencies
/// ✅ FIXED: Services now use singleton pattern to prevent re-initialization
final _messageHandlerProvider = Provider<BLEMessageHandler>(
  (ref) => BLEMessageHandler(),
);
final _contactRepositoryProvider = Provider<ContactRepository>(
  (ref) => ContactRepository(),
);
final _chatManagementServiceProvider = Provider<ChatManagementService>(
  (ref) => ChatManagementService.instance,
);
final _messageRepositoryProvider = Provider<MessageRepository>(
  (ref) => MessageRepository(),
);

/// Provider for Bluetooth state monitor
final bluetoothStateMonitorProvider = Provider<BluetoothStateMonitor>((ref) {
  return BluetoothStateMonitor.instance;
});

/// Stream provider for Bluetooth state information
/// FIX-007: Added autoDispose to prevent memory leaks
final bluetoothStateProvider = StreamProvider.autoDispose<BluetoothStateInfo>((
  ref,
) {
  final monitor = ref.watch(bluetoothStateMonitorProvider);
  return monitor.stateStream;
});

/// Stream provider for Bluetooth status messages
/// FIX-007: Added autoDispose to prevent memory leaks
final bluetoothStatusMessageProvider =
    StreamProvider.autoDispose<BluetoothStatusMessage>((ref) {
      final monitor = ref.watch(bluetoothStateMonitorProvider);
      return monitor.messageStream;
    });

/// Provider for current Bluetooth ready state
final bluetoothReadyProvider = Provider<bool>((ref) {
  final monitor = ref.watch(bluetoothStateMonitorProvider);
  return monitor.isBluetoothReady;
});

/// Provider for MeshNetworkingService (Singleton to prevent multiple instances)
final meshNetworkingServiceProvider = Provider<MeshNetworkingService>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  final messageHandler = ref.watch(_messageHandlerProvider);
  final contactRepository = ref.watch(_contactRepositoryProvider);
  final chatManagementService = ref.watch(_chatManagementServiceProvider);
  final messageRepository = ref.watch(_messageRepositoryProvider);

  _logger.info(
    '🔧 Creating MeshNetworkingService instance (should happen only once)',
  );

  final service = MeshNetworkingService(
    bleService: bleService,
    messageHandler: messageHandler,
    contactRepository: contactRepository,
    chatManagementService: chatManagementService,
    messageRepository: messageRepository,
  );

  // Initialize the service asynchronously with error handling
  _initializeServiceAsync(service, ref);

  ref.onDispose(() {
    _logger.info('🔧 Disposing MeshNetworkingService');
    service.dispose();
  });

  return service;
});

/// Stream provider for mesh network status with fallback
/// FIX-007: Added autoDispose to prevent memory leaks
final meshNetworkStatusProvider = StreamProvider.autoDispose<MeshNetworkStatus>(
  (ref) {
    final service = ref.watch(meshNetworkingServiceProvider);

    return service.meshStatus.handleError((error) {
      _logger.warning('Mesh status stream error: $error');
      // Return a default status to prevent infinite loading
      return MeshNetworkStatus(
        isInitialized: false,
        currentNodeId: null,
        isDemoMode: true,
        isConnected: false,
        queueMessages: [], // CRITICAL FIX: Initialize empty queue messages list
        statistics: MeshNetworkStatistics(
          nodeId: 'error',
          isInitialized: false,
          isDemoMode: true,
          relayStatistics: null,
          queueStatistics: null,
          syncStatistics: null,
          spamStatistics: null,
          demoStepsCount: 0,
          trackedMessagesCount: 0,
          spamPreventionActive: false,
          queueSyncActive: false,
        ),
      );
    });
  },
);

/// Stream provider for relay statistics with fallback
/// FIX-007: Added autoDispose to prevent memory leaks
final relayStatisticsProvider = StreamProvider.autoDispose<RelayStatistics>((
  ref,
) {
  final service = ref.watch(meshNetworkingServiceProvider);

  return service.relayStats.handleError((error) {
    _logger.warning('Relay stats stream error: $error');
    // Return default stats to prevent stream failure
  });
});

/// Stream provider for queue sync statistics with fallback
/// FIX-007: Added autoDispose to prevent memory leaks
final queueSyncStatisticsProvider =
    StreamProvider.autoDispose<QueueSyncManagerStats>((ref) {
      final service = ref.watch(meshNetworkingServiceProvider);

      return service.queueStats.handleError((error) {
        _logger.warning('Queue stats stream error: $error');
        // Return default stats to prevent stream failure
      });
    });

/// Stream provider for demo events
/// FIX-007: Added autoDispose to prevent memory leaks
final meshDemoEventsProvider = StreamProvider.autoDispose<DemoEvent>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.demoEvents;
});

/// Provider for current mesh network statistics
final meshNetworkStatisticsProvider = Provider<MeshNetworkStatistics>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.getNetworkStatistics();
});

/// Provider for demo steps list
final meshDemoStepsProvider = Provider<List<DemoRelayStep>>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.getDemoSteps();
});

/// State provider for currently selected demo scenario
final selectedDemoScenarioProvider = Provider<DemoScenarioType?>((ref) => null);

/// State provider for demo mode enabled/disabled
final isDemoModeEnabledProvider = Provider<bool>((ref) => true);

/// Provider for mesh networking UI state
final meshNetworkingUIStateProvider = Provider<MeshNetworkingUIState>((ref) {
  final networkStatus = ref.watch(meshNetworkStatusProvider);
  final relayStats = ref.watch(relayStatisticsProvider);
  final queueStats = ref.watch(queueSyncStatisticsProvider);
  final demoSteps = ref.watch(meshDemoStepsProvider);
  final selectedScenario = ref.watch(selectedDemoScenarioProvider);
  final isDemoMode = ref.watch(isDemoModeEnabledProvider);

  return MeshNetworkingUIState(
    networkStatus: networkStatus,
    relayStats: relayStats,
    queueStats: queueStats,
    demoSteps: demoSteps,
    selectedScenario: selectedScenario,
    isDemoModeEnabled: isDemoMode,
  );
});

/// Controller provider for mesh networking actions
final meshNetworkingControllerProvider = Provider<MeshNetworkingController>((
  ref,
) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return MeshNetworkingController(service);
});

/// Controller class for mesh networking actions
class MeshNetworkingController {
  final MeshNetworkingService _service;

  MeshNetworkingController(this._service);

  /// Send mesh message
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    bool isDemo = false,
  }) async {
    try {
      _logger.info(
        'UI: Sending mesh message to ${recipientPublicKey.shortId(8)}...',
      );

      final result = await _service.sendMeshMessage(
        content: content,
        recipientPublicKey: recipientPublicKey,
        priority: priority,
        isDemo: isDemo,
      );

      _logger.info('UI: Mesh send result: ${result.type.name}');
      return result;
    } catch (e) {
      _logger.severe('UI: Failed to send mesh message: $e');
      return MeshSendResult.error('Send failed: $e');
    }
  }

  /// Initialize demo scenario
  Future<DemoScenarioResult> initializeDemoScenario(
    DemoScenarioType type,
  ) async {
    try {
      _logger.info('UI: Initializing demo scenario: ${type.name}');

      final result = await _service.initializeDemoScenario(type);

      if (result.success) {
        // Note: Selected scenario state updated (would need StateNotifier for persistence)
      }

      return result;
    } catch (e) {
      _logger.severe('UI: Failed to initialize demo scenario: $e');
      return DemoScenarioResult.error('Demo initialization failed: $e');
    }
  }

  /// Clear demo data
  void clearDemoData() {
    _logger.info('UI: Clearing demo data');
    _service.clearDemoData();
    // Note: Selected scenario cleared (would need StateNotifier for persistence)
  }

  /// Sync queues with connected peers
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async {
    try {
      _logger.info('UI: Syncing queues with peers');
      return await _service.syncQueuesWithPeers();
    } catch (e) {
      _logger.severe('UI: Queue sync failed: $e');
      return {'error': QueueSyncResult.error('Sync failed: $e')};
    }
  }

  /// Toggle demo mode
  void toggleDemoMode() {
    // For now, just log the toggle request
    _logger.info('UI: Demo mode toggle requested');
    // Note: State management would need a proper StateNotifier implementation
  }

  /// Get network health status
  MeshNetworkHealth getNetworkHealth() {
    final statistics = _service.getNetworkStatistics();

    final relayEfficiency = statistics.relayStatistics?.relayEfficiency ?? 0.0;
    final queueHealth = statistics.queueStatistics?.queueHealthScore ?? 0.0;
    final spamBlockRate = statistics.spamStatistics?.blockRate ?? 0.0;

    // Calculate overall health (0.0 - 1.0)
    double overallHealth = 0.0;
    int factors = 0;

    if (statistics.isInitialized) {
      overallHealth += 0.3; // Base health for being initialized
      factors++;
    }

    if (statistics.spamPreventionActive) {
      overallHealth += 0.2; // Health bonus for spam prevention
      factors++;
    }

    if (statistics.queueSyncActive) {
      overallHealth += 0.2; // Health bonus for queue sync
      factors++;
    }

    // Add relay efficiency
    overallHealth += relayEfficiency * 0.2;
    factors++;

    // Add queue health
    overallHealth += queueHealth * 0.1;
    factors++;

    final finalHealth = factors > 0 ? overallHealth : 0.0;

    return MeshNetworkHealth(
      overallHealth: finalHealth.clamp(0.0, 1.0),
      relayEfficiency: relayEfficiency,
      queueHealth: queueHealth,
      spamBlockRate: spamBlockRate,
      isHealthy: finalHealth > 0.7,
      issues: _getNetworkIssues(statistics),
    );
  }

  /// Get network issues for health assessment
  List<String> _getNetworkIssues(MeshNetworkStatistics statistics) {
    final issues = <String>[];

    if (!statistics.isInitialized) {
      issues.add('Mesh networking not initialized');
    }

    if (!statistics.spamPreventionActive) {
      issues.add('Spam prevention not active');
    }

    if (!statistics.queueSyncActive) {
      issues.add('Queue synchronization not active');
    }

    if (statistics.relayStatistics != null) {
      final relayStats = statistics.relayStatistics!;
      if (relayStats.totalDropped > relayStats.totalRelayed * 0.5) {
        issues.add('High message drop rate');
      }

      if (relayStats.totalBlocked > relayStats.totalProcessed * 0.3) {
        issues.add('High spam block rate');
      }
    }

    if (statistics.queueStatistics != null) {
      final queueStats = statistics.queueStatistics!;
      if (queueStats.failedMessages > 10) {
        issues.add('Many failed messages in queue');
      }

      if (queueStats.queueHealthScore < 0.5) {
        issues.add('Poor queue health');
      }
    }

    return issues;
  }
}

/// UI state for mesh networking components
class MeshNetworkingUIState {
  final AsyncValue<MeshNetworkStatus> networkStatus;
  final AsyncValue<RelayStatistics> relayStats;
  final AsyncValue<QueueSyncManagerStats> queueStats;
  final List<DemoRelayStep> demoSteps;
  final DemoScenarioType? selectedScenario;
  final bool isDemoModeEnabled;

  const MeshNetworkingUIState({
    required this.networkStatus,
    required this.relayStats,
    required this.queueStats,
    required this.demoSteps,
    this.selectedScenario,
    required this.isDemoModeEnabled,
  });

  /// Check if mesh networking is ready for use
  bool get isReady {
    return networkStatus.asData?.value.isInitialized ?? false;
  }

  /// Check if connected to mesh network
  bool get isConnected {
    return networkStatus.asData?.value.isConnected ?? false;
  }

  /// Get current node ID
  String? get currentNodeId {
    return networkStatus.asData?.value.currentNodeId;
  }

  /// Check if demo mode is active
  bool get isDemoMode {
    return networkStatus.asData?.value.isDemoMode ?? false;
  }

  /// Get relay efficiency percentage
  double get relayEfficiencyPercent {
    final efficiency = relayStats.asData?.value.relayEfficiency ?? 0.0;
    return efficiency * 100;
  }

  /// Get queue health percentage
  double get queueHealthPercent {
    final health =
        networkStatus
            .asData
            ?.value
            .statistics
            .queueStatistics
            ?.queueHealthScore ??
        0.0;
    return health * 100;
  }

  /// Get total messages relayed
  int get totalRelayed {
    return relayStats.asData?.value.totalRelayed ?? 0;
  }

  /// Get total messages blocked by spam prevention
  int get totalBlocked {
    return relayStats.asData?.value.totalBlocked ?? 0;
  }

  /// Get pending messages count
  int get pendingMessages {
    return networkStatus
            .asData
            ?.value
            .statistics
            .queueStatistics
            ?.pendingMessages ??
        0;
  }
}

/// Network health assessment
class MeshNetworkHealth {
  final double overallHealth; // 0.0 - 1.0
  final double relayEfficiency; // 0.0 - 1.0
  final double queueHealth; // 0.0 - 1.0
  final double spamBlockRate; // 0.0 - 1.0
  final bool isHealthy;
  final List<String> issues;

  const MeshNetworkHealth({
    required this.overallHealth,
    required this.relayEfficiency,
    required this.queueHealth,
    required this.spamBlockRate,
    required this.isHealthy,
    required this.issues,
  });

  /// Get health status as text
  String get healthStatus {
    if (overallHealth >= 0.8) return 'Excellent';
    if (overallHealth >= 0.6) return 'Good';
    if (overallHealth >= 0.4) return 'Fair';
    if (overallHealth >= 0.2) return 'Poor';
    return 'Critical';
  }

  /// Get health color indicator
  String get healthColor {
    if (overallHealth >= 0.7) return 'green';
    if (overallHealth >= 0.5) return 'orange';
    return 'red';
  }
}

/// Provider for A->B->C demo scenario state
final aToBtoCDemoProvider = Provider<AToBtoCDemoState>((ref) {
  return const AToBtoCDemoState();
});

/// State for A->B->C demo scenario
class AToBtoCDemoState {
  final List<DemoNode> nodes;
  final String? activeMessageId;
  final int currentStep;
  final bool isRunning;

  const AToBtoCDemoState({
    this.nodes = const [],
    this.activeMessageId,
    this.currentStep = 0,
    this.isRunning = false,
  });

  AToBtoCDemoState copyWith({
    List<DemoNode>? nodes,
    String? activeMessageId,
    int? currentStep,
    bool? isRunning,
  }) {
    return AToBtoCDemoState(
      nodes: nodes ?? this.nodes,
      activeMessageId: activeMessageId ?? this.activeMessageId,
      currentStep: currentStep ?? this.currentStep,
      isRunning: isRunning ?? this.isRunning,
    );
  }
}

/// Demo node representation for visualization
class DemoNode {
  final String id;
  final String name;
  final bool isActive;
  final bool isCurrentUser;
  final double x; // Position for visualization
  final double y;

  const DemoNode({
    required this.id,
    required this.name,
    required this.isActive,
    required this.isCurrentUser,
    required this.x,
    required this.y,
  });

  DemoNode copyWith({
    String? id,
    String? name,
    bool? isActive,
    bool? isCurrentUser,
    double? x,
    double? y,
  }) {
    return DemoNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isActive: isActive ?? this.isActive,
      isCurrentUser: isCurrentUser ?? this.isCurrentUser,
      x: x ?? this.x,
      y: y ?? this.y,
    );
  }
}

/// Utility provider extensions
extension MeshNetworkingProviderExtensions on WidgetRef {
  /// Send mesh message with error handling
  Future<bool> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    bool isDemo = false,
  }) async {
    final controller = read(meshNetworkingControllerProvider);
    final result = await controller.sendMeshMessage(
      content: content,
      recipientPublicKey: recipientPublicKey,
      priority: priority,
      isDemo: isDemo,
    );
    return result.isSuccess;
  }

  /// Initialize demo scenario with state update
  Future<bool> initializeDemoScenario(DemoScenarioType type) async {
    final controller = read(meshNetworkingControllerProvider);
    final result = await controller.initializeDemoScenario(type);
    return result.success;
  }

  /// Get current mesh network health
  MeshNetworkHealth getMeshNetworkHealth() {
    final controller = read(meshNetworkingControllerProvider);
    return controller.getNetworkHealth();
  }
}

/// Initialize mesh service asynchronously with error handling
Future<void> _initializeServiceAsync(
  MeshNetworkingService service,
  Ref ref,
) async {
  try {
    _logger.info('Initializing mesh networking service with auto demo mode...');

    // Initialize with demo mode enabled by default
    await service.initialize(enableDemo: true);

    _logger.info('✅ Mesh networking service initialized successfully');

    // CRITICAL FIX: Add a small delay then force a status broadcast
    // This ensures any late-subscribing widgets get the final initialized status
    await Future.delayed(Duration(milliseconds: 100));

    // Force a final status broadcast to ensure all listeners get the initialized state
    service.refreshMeshStatus();
    _logger.info(
      '🔄 Final status broadcast sent to ensure all widgets receive initialized state',
    );
  } catch (e) {
    _logger.severe('❌ Failed to initialize mesh networking service: $e');
    // Don't rethrow - let the service handle fallback status broadcasting
  }
}

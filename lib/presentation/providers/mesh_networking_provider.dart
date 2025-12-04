// Riverpod providers for mesh networking UI state management
// Integrates MeshNetworkingService with the presentation layer

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:logging/logging.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../domain/services/chat_management_service.dart';
import '../../data/services/ble_message_handler.dart';
import '../../data/services/ble_message_handler_facade_impl.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/interfaces/i_seen_message_store.dart';
import '../../core/interfaces/i_mesh_networking_service.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/interfaces/i_mesh_routing_service.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/services/mesh_networking_service.dart'
    show ReceivedBinaryEvent, PendingBinaryTransfer;
import '../../domain/entities/message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/services/mesh/mesh_relay_coordinator.dart';
import '../../domain/services/mesh/mesh_queue_sync_coordinator.dart';
import '../../domain/services/mesh/mesh_network_health_monitor.dart';
import 'ble_providers.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../core/di/service_locator.dart'; // Phase 1 Part C: DI integration
import 'runtime_providers.dart';
import '../../core/networking/topology_manager.dart';
import '../../core/models/network_topology.dart';

// =============================================================================
// CORE RUNTIME NOTIFIER (MESH)
// =============================================================================

class MeshRuntimeState {
  final MeshNetworkStatus status;
  final RelayStatistics? relayStatistics;
  final QueueSyncManagerStats? queueStatistics;

  const MeshRuntimeState({
    required this.status,
    required this.relayStatistics,
    required this.queueStatistics,
  });

  factory MeshRuntimeState.initial() => MeshRuntimeState(
    status: MeshNetworkStatus(
      isInitialized: false,
      currentNodeId: null,
      isConnected: false,
      queueMessages: const [],
      statistics: const MeshNetworkStatistics(
        nodeId: 'unknown',
        isInitialized: false,
        relayStatistics: null,
        queueStatistics: null,
        syncStatistics: null,
        spamStatistics: null,
        spamPreventionActive: false,
        queueSyncActive: false,
      ),
    ),
    relayStatistics: null,
    queueStatistics: null,
  );

  MeshRuntimeState copyWith({
    MeshNetworkStatus? status,
    RelayStatistics? relayStatistics,
    QueueSyncManagerStats? queueStatistics,
  }) {
    return MeshRuntimeState(
      status: status ?? this.status,
      relayStatistics: relayStatistics ?? this.relayStatistics,
      queueStatistics: queueStatistics ?? this.queueStatistics,
    );
  }
}

/// ✅ Phase 6: Migrated from manual StreamSubscriptions to ref.listen pattern
class MeshRuntimeNotifier extends AsyncNotifier<MeshRuntimeState> {
  @override
  Future<MeshRuntimeState> build() async {
    await ref.watch(appBootstrapProvider.future);

    final service = ref.watch(meshNetworkingServiceProvider);
    final initialState = MeshRuntimeState.initial();
    state = AsyncValue.data(initialState);

    // ✅ Phase 6: Use ref.listen for automatic lifecycle management
    ref.listen<AsyncValue<MeshNetworkStatus>>(meshStatusStreamProvider, (
      prev,
      next,
    ) {
      next.whenData((value) {
        final current = state.asData?.value;
        if (current != null) {
          state = AsyncValue.data(current.copyWith(status: value));
        }
      });
    });

    ref.listen<AsyncValue<RelayStatistics>>(relayStatsStreamProvider, (
      prev,
      next,
    ) {
      next.whenData((value) {
        final current = state.asData?.value;
        if (current != null) {
          state = AsyncValue.data(current.copyWith(relayStatistics: value));
        }
      });
    });

    ref.listen<AsyncValue<QueueSyncManagerStats>>(queueStatsStreamProvider, (
      prev,
      next,
    ) {
      next.whenData((value) {
        final current = state.asData?.value;
        if (current != null) {
          state = AsyncValue.data(current.copyWith(queueStatistics: value));
        }
      });
    });

    // Force a status refresh for late subscribers.
    try {
      service.refreshMeshStatus();
    } catch (_) {}

    return initialState;
  }
}

final meshRuntimeProvider =
    AsyncNotifierProvider<MeshRuntimeNotifier, MeshRuntimeState>(
      () => MeshRuntimeNotifier(),
    );

/// Logger for mesh networking providers
final _logger = Logger('MeshNetworkingProvider');

/// Singleton providers for service dependencies
/// ✅ FIXED: Services now use singleton pattern to prevent re-initialization

/// Provider for IBLEMessageHandlerFacade implementation
/// ✅ Phase 3A: Wraps BLEMessageHandler with simplified facade interface
final _messageHandlerProvider = Provider<IBLEMessageHandlerFacade>((ref) {
  final seenMessageStore = getIt<ISeenMessageStore>();
  return BLEMessageHandlerFacadeImpl(BLEMessageHandler(), seenMessageStore);
});
final _chatManagementServiceProvider = Provider<ChatManagementService>(
  (ref) => ChatManagementService.instance,
);

/// Provider for Bluetooth state monitor
final bluetoothStateMonitorProvider = Provider<BluetoothStateMonitor>((ref) {
  return BluetoothStateMonitor.instance;
});

/// Bluetooth state stream (bridged via Riverpod for lifecycle safety)
final bluetoothStateStreamProvider = StreamProvider<BluetoothStateInfo>((ref) {
  final monitor = ref.watch(bluetoothStateMonitorProvider);
  return monitor.stateStream;
});

/// Bluetooth status message stream (bridged via Riverpod for lifecycle safety)
final bluetoothStatusMessageStreamProvider =
    StreamProvider<BluetoothStatusMessage>((ref) {
      final monitor = ref.watch(bluetoothStateMonitorProvider);
      return monitor.messageStream;
    });

/// Bluetooth state (driven by BleRuntimeNotifier)
final bluetoothStateProvider =
    Provider.autoDispose<AsyncValue<BluetoothStateInfo>>((ref) {
      return ref.watch(bluetoothStateStreamProvider);
    });

/// Bluetooth status messages (driven by BleRuntimeNotifier)
final bluetoothStatusMessageProvider =
    Provider.autoDispose<AsyncValue<BluetoothStatusMessage>>((ref) {
      return ref.watch(bluetoothStatusMessageStreamProvider);
    });

/// Provider for current Bluetooth ready state
final bluetoothReadyProvider = Provider<bool>((ref) {
  final state = ref.watch(bluetoothStateStreamProvider);
  return state.asData?.value.isReady ?? false;
});

/// Provider for MeshNetworkingService (Singleton to prevent multiple instances)
/// Phase 1 Part C: Register in DI container when created
final meshNetworkingServiceProvider = Provider<IMeshNetworkingService>((ref) {
  if (getIt.isRegistered<IMeshNetworkingService>()) {
    return getIt<IMeshNetworkingService>();
  }

  final connectionService = ref.watch(connectionServiceProvider);
  final messageHandler = ref.watch(_messageHandlerProvider);
  final chatManagementService = ref.watch(_chatManagementServiceProvider);

  _logger.info(
    '🔧 Creating MeshNetworkingService instance (fallback for tests)',
  );

  final service = MeshNetworkingService(
    bleService: connectionService,
    messageHandler: messageHandler,
    chatManagementService: chatManagementService,
  );

  _initializeServiceAsync(service, ref);

  ref.onDispose(() {
    _logger.info('🔧 Disposing fallback MeshNetworkingService');
    service.dispose();
    try {
      getIt.unregister<MeshNetworkingService>();
    } catch (_) {}
    try {
      getIt.unregister<IMeshNetworkingService>();
    } catch (_) {}
    try {
      getIt.unregister<MeshRelayCoordinator>();
    } catch (_) {}
    try {
      getIt.unregister<MeshQueueSyncCoordinator>();
    } catch (_) {}
    try {
      getIt.unregister<MeshNetworkHealthMonitor>();
    } catch (_) {}
  });

  try {
    getIt.registerSingleton<MeshNetworkingService>(service);
  } catch (_) {}

  try {
    getIt.registerSingleton<IMeshNetworkingService>(service);
  } catch (_) {}

  try {
    getIt.registerSingleton<MeshRelayCoordinator>(service.relayCoordinator);
  } catch (_) {}

  try {
    getIt.registerSingleton<MeshQueueSyncCoordinator>(service.queueCoordinator);
  } catch (_) {}

  try {
    getIt.registerSingleton<MeshNetworkHealthMonitor>(service.healthMonitor);
  } catch (_) {}

  return service;
});

/// Binary/media payload stream for UI consumption.
final binaryPayloadStreamProvider = StreamProvider<ReceivedBinaryEvent>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.binaryPayloadStream;
});

/// Simple inbox of binary payloads keyed by transferId for UI rendering.
final binaryPayloadInboxProvider =
    StateNotifierProvider<BinaryPayloadInbox, Map<String, ReceivedBinaryEvent>>(
      (ref) {
        final service = ref.watch(meshNetworkingServiceProvider);
        final notifier = BinaryPayloadInbox();
        final sub = service.binaryPayloadStream.listen(notifier.addPayload);
        ref.onDispose(sub.cancel);
        return notifier;
      },
    );

/// Pending binary send list for progress/UX.
final pendingBinaryTransfersProvider = Provider<List<PendingBinaryTransfer>>((
  ref,
) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.getPendingBinaryTransfers();
});

/// ✅ Phase 6: Mesh network status stream (bridged through Riverpod)
/// Exposes MeshNetworkingService.meshStatus via StreamProvider for proper lifecycle
final meshStatusStreamProvider = StreamProvider<MeshNetworkStatus>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.meshStatus;
});

/// ✅ Phase 6: Relay statistics stream (bridged through Riverpod)
final relayStatsStreamProvider = StreamProvider<RelayStatistics>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.relayStats;
});

/// ✅ Phase 6: Queue sync statistics stream (bridged through Riverpod)
final queueStatsStreamProvider = StreamProvider<QueueSyncManagerStats>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.queueStats;
});

/// ✅ Phase 6: Topology manager provider (singleton access)
final topologyManagerProvider = Provider<TopologyManager>((ref) {
  return TopologyManager.instance;
});

/// ✅ Phase 6: Network topology stream (bridged through Riverpod)
/// Exposes TopologyManager.topologyStream for proper lifecycle management
final topologyStreamProvider = StreamProvider<NetworkTopology>((ref) {
  final topologyManager = ref.watch(topologyManagerProvider);
  return topologyManager.topologyStream;
});

/// Provider for MeshRoutingService (optional, for routing-specific monitoring)
/// This service is created and managed by MeshNetworkingService, but can be
/// exposed here for testing or direct routing statistics access
final meshRoutingServiceProvider = Provider<IMeshRoutingService?>((ref) {
  _logger.fine('🧠 Mesh routing service provider accessed');
  // Note: Routing service is internally managed by MeshNetworkingService
  // This provider would return the service if it were exposed via a getter
  // For now, return null as the service is not directly exposed
  return null;
});

/// Mesh runtime status provider (driven by MeshRuntimeNotifier)
final meshNetworkStatusProvider =
    Provider.autoDispose<AsyncValue<MeshNetworkStatus>>((ref) {
      return ref.watch(meshRuntimeProvider).whenData((state) => state.status);
    });

/// Relay statistics provider (driven by MeshRuntimeNotifier)
final relayStatisticsProvider =
    Provider.autoDispose<AsyncValue<RelayStatistics?>>((ref) {
      return ref
          .watch(meshRuntimeProvider)
          .whenData((state) => state.relayStatistics);
    });

/// Queue sync statistics provider (driven by MeshRuntimeNotifier)
final queueSyncStatisticsProvider =
    Provider.autoDispose<AsyncValue<QueueSyncManagerStats?>>((ref) {
      return ref
          .watch(meshRuntimeProvider)
          .whenData((state) => state.queueStatistics);
    });

/// Provider for current mesh network statistics
final meshNetworkStatisticsProvider = Provider<MeshNetworkStatistics>((ref) {
  final service = ref.watch(meshNetworkingServiceProvider);
  return service.getNetworkStatistics();
});

/// Provider for mesh networking UI state
final meshNetworkingUIStateProvider = Provider<MeshNetworkingUIState>((ref) {
  final networkStatus = ref.watch(meshNetworkStatusProvider);
  final relayStats = ref.watch(relayStatisticsProvider);
  final queueStats = ref.watch(queueSyncStatisticsProvider);

  return MeshNetworkingUIState(
    networkStatus: networkStatus,
    relayStats: relayStats,
    queueStats: queueStats,
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
  final IMeshNetworkingService _service;

  MeshNetworkingController(this._service);

  /// Send mesh message
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    try {
      _logger.info(
        'UI: Sending mesh message to ${recipientPublicKey.shortId(8)}...',
      );

      final result = await _service.sendMeshMessage(
        content: content,
        recipientPublicKey: recipientPublicKey,
        priority: priority,
      );

      _logger.info('UI: Mesh send result: ${result.type.name}');
      return result;
    } catch (e) {
      _logger.severe('UI: Failed to send mesh message: $e');
      return MeshSendResult.error('Send failed: $e');
    }
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
  final AsyncValue<RelayStatistics?> relayStats;
  final AsyncValue<QueueSyncManagerStats?> queueStats;

  const MeshNetworkingUIState({
    required this.networkStatus,
    required this.relayStats,
    required this.queueStats,
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

  /// Get relay efficiency percentage
  double get relayEfficiencyPercent {
    final efficiency = relayStats.asData?.value?.relayEfficiency ?? 0.0;
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
    return relayStats.asData?.value?.totalRelayed ?? 0;
  }

  /// Get total messages blocked by spam prevention
  int get totalBlocked {
    return relayStats.asData?.value?.totalBlocked ?? 0;
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

/// Utility provider extensions
extension MeshNetworkingProviderExtensions on WidgetRef {
  /// Send mesh message with error handling
  Future<bool> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    final controller = read(meshNetworkingControllerProvider);
    final result = await controller.sendMeshMessage(
      content: content,
      recipientPublicKey: recipientPublicKey,
      priority: priority,
    );
    return result.isSuccess;
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
    _logger.info('Initializing mesh networking service...');
    await service.initialize();

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

/// Simple in-memory implementation of ISeenMessageStore for Phase 3A
/// Phase 3B should replace with persistent SQLite-backed implementation
class BinaryPayloadInbox
    extends StateNotifier<Map<String, ReceivedBinaryEvent>> {
  BinaryPayloadInbox() : super({});

  void addPayload(ReceivedBinaryEvent event) {
    state = {...state, event.transferId: event};
  }

  void clearPayload(String transferId) {
    if (!state.containsKey(transferId)) return;
    final next = Map.of(state);
    next.remove(transferId);
    state = next;
  }
}

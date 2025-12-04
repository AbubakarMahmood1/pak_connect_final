import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../domain/services/mesh/mesh_network_health_monitor.dart';
import '../../core/di/service_locator.dart';

final _logger = Logger('MeshHealthProvider');

/// ✅ Phase 6D: Riverpod provider for MeshNetworkHealthMonitor
/// Manages lifecycle and provides Riverpod access to mesh health monitoring
final meshHealthMonitorProvider =
    Provider.autoDispose<MeshNetworkHealthMonitor>((ref) {
      final monitor = getIt<MeshNetworkHealthMonitor>();
      _logger.fine('✅ MeshNetworkHealthMonitor provider accessed');
      ref.onDispose(monitor.dispose);
      return monitor;
    });

/// ✅ Phase 6D: StreamProvider for mesh network status
/// Emits mesh connectivity and relay status changes
final meshNetworkStatusStreamProvider = StreamProvider.autoDispose((ref) {
  final monitor = ref.watch(meshHealthMonitorProvider);
  return monitor.meshStatus;
});

/// ✅ Phase 6D: StreamProvider for relay statistics
/// Emits relay performance metrics (relayed messages, hops, etc.)
final meshRelayStatsStreamProvider = StreamProvider.autoDispose((ref) {
  final monitor = ref.watch(meshHealthMonitorProvider);
  return monitor.relayStats;
});

/// ✅ Phase 6D: StreamProvider for queue sync manager stats
/// Emits queue synchronization metrics and status
final meshQueueSyncStatsStreamProvider = StreamProvider.autoDispose((ref) {
  final monitor = ref.watch(meshHealthMonitorProvider);
  return monitor.queueStats;
});

/// ✅ Phase 6D: StreamProvider for message delivery events
/// Emits debug/info messages about message delivery status
final meshMessageDeliveryStreamProvider = StreamProvider.autoDispose((ref) {
  final monitor = ref.watch(meshHealthMonitorProvider);
  return monitor.messageDeliveryStream;
});

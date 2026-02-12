import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart';
import 'package:logging/logging.dart';

import '../../domain/services/mesh/mesh_network_health_monitor.dart';

final _logger = Logger('MeshHealthProvider');

/// ✅ Phase 6D: Riverpod provider for MeshNetworkHealthMonitor
/// Provides Riverpod access to the AppCore-owned mesh health monitor.
final meshHealthMonitorProvider = Provider<MeshNetworkHealthMonitor>((ref) {
  final monitor =
      resolveFromAppServicesOrServiceLocator<MeshNetworkHealthMonitor>(
        fromServices: (services) => services.meshNetworkHealthMonitor,
        dependencyName: 'MeshNetworkHealthMonitor',
      );
  _logger.fine('✅ MeshNetworkHealthMonitor provider accessed');
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

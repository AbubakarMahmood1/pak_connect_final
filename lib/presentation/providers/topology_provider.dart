import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/routing/topology_manager.dart';
import 'package:pak_connect/domain/models/network_topology.dart';

/// Provider for TopologyManager singleton
final topologyManagerProvider = Provider.autoDispose<TopologyManager>((ref) {
  final manager = TopologyManager.instance;
  ref.onDispose(() {
    // Note: TopologyManager is a singleton, so we don't dispose it
    // Disposal is managed at application lifecycle level
  });
  return manager;
});

/// Stream provider for topology updates
final topologyStreamProvider = StreamProvider.autoDispose<NetworkTopology>((
  ref,
) async* {
  final manager = ref.watch(topologyManagerProvider);
  yield manager.getTopology();
  yield* manager.topologyStream;
});

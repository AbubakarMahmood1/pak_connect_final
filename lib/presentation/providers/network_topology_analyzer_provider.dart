import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/routing/network_topology_analyzer.dart';
import 'package:pak_connect/domain/routing/routing_models.dart';

/// Provider for NetworkTopologyAnalyzer instance
final networkTopologyAnalyzerProvider =
    Provider.autoDispose<NetworkTopologyAnalyzer>((ref) {
      final analyzer = NetworkTopologyAnalyzer();
      ref.onDispose(analyzer.dispose);
      return analyzer;
    });

/// Async provider that initializes and manages the NetworkTopologyAnalyzer
final networkTopologyAnalyzerInitializedProvider =
    FutureProvider.autoDispose<NetworkTopologyAnalyzer>((ref) async {
      final analyzer = ref.watch(networkTopologyAnalyzerProvider);
      await analyzer.initialize();
      return analyzer;
    });

/// Stream provider for topology updates
final networkTopologyUpdatesProvider =
    StreamProvider.autoDispose<NetworkTopology>((ref) async* {
      final analyzer = ref.watch(networkTopologyAnalyzerProvider);
      await analyzer.initialize();
      yield analyzer.getNetworkTopology();
      yield* analyzer.topologyUpdates;
    });

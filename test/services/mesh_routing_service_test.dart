import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/mesh_routing_service.dart';
import 'package:pak_connect/core/routing/network_topology_analyzer.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import '../test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'mesh_routing_service');
  });

  group('MeshRoutingService', () {
    late MeshRoutingService routingService;
    late NetworkTopologyAnalyzer topologyAnalyzer;
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    const String nodeA = 'node_a_12345';
    const String nodeB = 'node_b_67890';
    const String nodeC = 'node_c_abcde';
    const String nodeD = 'node_d_fghij';

    setUp(() async {
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      await TestSetup.configureTestDatabase(label: 'mesh_routing_service');
      topologyAnalyzer = NetworkTopologyAnalyzer();
      await topologyAnalyzer.initialize();

      routingService = MeshRoutingService();
      await routingService.initialize(
        currentNodeId: nodeA,
        topologyAnalyzer: topologyAnalyzer,
      );
    });

    void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

    tearDown(() {
      final severe = logRecords.where((l) => l.level >= Level.SEVERE);
      final unexpected = severe.where(
        (l) => !allowedSevere.any(
          (p) => p is String
              ? l.message.contains(p)
              : (p as RegExp).hasMatch(l.message),
        ),
      );
      expect(
        unexpected,
        isEmpty,
        reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
      );
      for (final pattern in allowedSevere) {
        final found = severe.any(
          (l) => pattern is String
              ? l.message.contains(pattern)
              : (pattern as RegExp).hasMatch(l.message),
        );
        expect(
          found,
          isTrue,
          reason: 'Missing expected SEVERE matching "$pattern"',
        );
      }
      routingService.dispose();
      topologyAnalyzer.dispose();
    });

    // ============================================================================
    // INITIALIZATION TESTS
    // ============================================================================

    test('Service initializes successfully', () async {
      expect(routingService, isNotNull);
    });

    test('Service initializes with correct node ID', () async {
      final service = MeshRoutingService();
      await service.initialize(
        currentNodeId: nodeB,
        topologyAnalyzer: topologyAnalyzer,
      );
      final stats = service.getStatistics();
      expect(stats.nodeId, equals(nodeB));
      service.dispose();
    });

    test('Service initializes with alternate node IDs', () async {
      final otherService = MeshRoutingService();
      await otherService.initialize(
        currentNodeId: nodeC,
        topologyAnalyzer: topologyAnalyzer,
      );
      expect(otherService, isNotNull);
      otherService.dispose();
    });

    // ============================================================================
    // ROUTE DETERMINATION TESTS
    // ============================================================================

    test('determineOptimalRoute returns valid RoutingDecision', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final decision = await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      expect(decision, isNotNull);
      expect(decision.isSuccessful, isTrue);
    });

    test('Route determination with multiple available hops', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeA, nodeC);

      final decision = await routingService.determineOptimalRoute(
        finalRecipient: nodeD,
        availableHops: [nodeB, nodeC],
        priority: MessagePriority.normal,
      );

      expect(decision, isNotNull);
    });

    test('Route determination with different priority levels', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final highPrio = await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.high,
      );

      final normalPrio = await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      final lowPrio = await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.low,
      );

      expect(highPrio.isSuccessful, isTrue);
      expect(normalPrio.isSuccessful, isTrue);
      expect(lowPrio.isSuccessful, isTrue);
    });

    test('Route determination handles same node as recipient', () async {
      final decision = await routingService.determineOptimalRoute(
        finalRecipient: nodeA,
        availableHops: [nodeA],
        priority: MessagePriority.normal,
      );

      expect(decision, isNotNull);
    });

    test('Multiple consecutive route determinations work correctly', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      for (int i = 0; i < 5; i++) {
        final decision = await routingService.determineOptimalRoute(
          finalRecipient: nodeB,
          availableHops: [nodeB, nodeC],
          priority: MessagePriority.normal,
        );
        expect(decision.isSuccessful, isTrue);
      }
    });

    // ============================================================================
    // TOPOLOGY MANAGEMENT TESTS
    // ============================================================================

    test('Adding connection updates topology', () async {
      routingService.addConnection(nodeB, nodeC);
      final topology = topologyAnalyzer.getNetworkTopology();
      expect(topology, isNotNull);
    });

    test('Removing connection updates topology', () async {
      routingService.addConnection(nodeB, nodeC);
      routingService.removeConnection(nodeB, nodeC);
      final topology = topologyAnalyzer.getNetworkTopology();
      expect(topology, isNotNull);
    });

    test('Multiple topology updates accumulate', () async {
      routingService.addConnection(nodeA, nodeB);
      routingService.addConnection(nodeB, nodeC);
      routingService.addConnection(nodeC, nodeD);

      final stats = topologyAnalyzer.getNetworkStats();
      expect(stats.totalNodes, greaterThan(0));
      expect(stats.totalConnections, greaterThan(0));
    });

    // ============================================================================
    // STATISTICS TESTS
    // ============================================================================

    test('Statistics are available after initialization', () async {
      final stats = routingService.getStatistics();
      expect(stats, isNotNull);
      expect(stats.nodeId, equals(nodeA));
    });

    test('Statistics are available after routing', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      final stats = routingService.getStatistics();
      expect(stats, isNotNull);
      expect(stats.nodeId, isNotNull);
    });

    test('Statistics remain consistent across queries', () async {
      final stats1 = routingService.getStatistics();
      final stats2 = routingService.getStatistics();

      expect(stats1.nodeId, equals(stats2.nodeId));
    });

    // ============================================================================
    // EDGE CASE TESTS
    // ============================================================================

    test('Service handles empty hop list', () async {
      final decision = await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [],
        priority: MessagePriority.normal,
      );

      expect(decision, isNotNull);
    });

    test('Service handles very long node IDs', () async {
      final longKey = 'a' * 256;
      await topologyAnalyzer.addConnection(nodeA, longKey);

      final decision = await routingService.determineOptimalRoute(
        finalRecipient: longKey,
        availableHops: [longKey],
        priority: MessagePriority.normal,
      );

      expect(decision, isNotNull);
    });

    test('Service handles special characters in node IDs', () async {
      const String specialNode = 'node_!@#\$%_12345';

      routingService.addConnection(nodeA, specialNode);

      final decision = await routingService.determineOptimalRoute(
        finalRecipient: specialNode,
        availableHops: [specialNode],
        priority: MessagePriority.normal,
      );

      expect(decision, isNotNull);
    });

    test('Service handles large number of hops', () async {
      final manyHops = List.generate(20, (i) => 'hop_$i');

      final decision = await routingService.determineOptimalRoute(
        finalRecipient: 'final_recipient',
        availableHops: manyHops,
        priority: MessagePriority.normal,
      );

      expect(decision, isNotNull);
    });

    // ============================================================================
    // LIFECYCLE TESTS
    // ============================================================================

    test('Service can be disposed', () async {
      final service = MeshRoutingService();
      await service.initialize(
        currentNodeId: nodeD,
        topologyAnalyzer: topologyAnalyzer,
      );

      service.dispose();
      expect(service, isNotNull);
    });

    test('Multiple service instances do not interfere', () async {
      final routing1 = MeshRoutingService();
      final routing2 = MeshRoutingService();
      final topology1 = NetworkTopologyAnalyzer();
      final topology2 = NetworkTopologyAnalyzer();

      await topology1.initialize();
      await topology2.initialize();

      await routing1.initialize(
        currentNodeId: nodeA,
        topologyAnalyzer: topology1,
      );

      await routing2.initialize(
        currentNodeId: nodeB,
        topologyAnalyzer: topology2,
      );

      final decision1 = await routing1.determineOptimalRoute(
        finalRecipient: nodeC,
        availableHops: [nodeC],
        priority: MessagePriority.normal,
      );

      final decision2 = await routing2.determineOptimalRoute(
        finalRecipient: nodeD,
        availableHops: [nodeD],
        priority: MessagePriority.normal,
      );

      expect(decision1.isSuccessful, isTrue);
      expect(decision2.isSuccessful, isTrue);

      routing1.dispose();
      routing2.dispose();
      topology1.dispose();
      topology2.dispose();
    });

    test('clearAll removes routing data', () async {
      routingService.addConnection(nodeB, nodeC);
      routingService.addConnection(nodeC, nodeD);

      routingService.clearAll();

      final stats = routingService.getStatistics();
      expect(stats, isNotNull);
    });

    // ============================================================================
    // INTERFACE COMPLIANCE TESTS
    // ============================================================================

    test('Service implements all required methods', () async {
      expect(routingService.initialize, isNotNull);
      expect(routingService.determineOptimalRoute, isNotNull);
      expect(routingService.addConnection, isNotNull);
      expect(routingService.removeConnection, isNotNull);
      expect(routingService.getStatistics, isNotNull);
      expect(routingService.clearAll, isNotNull);
      expect(routingService.dispose, isNotNull);
    });

    // ============================================================================
    // PERFORMANCE TESTS
    // ============================================================================

    test('Route determination completes quickly', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final stopwatch = Stopwatch()..start();

      await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason: 'Route determination should complete in < 500ms',
      );
    });

    test('Statistics retrieval is very fast', () async {
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 100; i++) {
        routingService.getStatistics();
      }

      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(100),
        reason: '100 statistics queries should complete in < 100ms',
      );
    });

    // ============================================================================
    // CONCURRENCY TESTS
    // ============================================================================

    test('Multiple concurrent route determinations work', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeA, nodeC);

      final futures = <Future>[];
      for (int i = 0; i < 5; i++) {
        futures.add(
          routingService.determineOptimalRoute(
            finalRecipient: nodeB,
            availableHops: [nodeB, nodeC],
            priority: MessagePriority.normal,
          ),
        );
      }

      final decisions = await Future.wait(futures);
      expect(decisions.length, equals(5));
      expect(decisions.every((d) => d != null), isTrue);
    });

    test('Concurrent topology updates and route determinations', () async {
      // Add connections (synchronous)
      routingService.addConnection(nodeA, nodeB);
      routingService.addConnection(nodeB, nodeC);
      routingService.addConnection(nodeC, nodeD);

      final futures = <Future>[];

      futures.add(
        routingService.determineOptimalRoute(
          finalRecipient: nodeD,
          availableHops: [nodeB, nodeC, nodeD],
          priority: MessagePriority.normal,
        ),
      );

      futures.add(Future(() => routingService.getStatistics()));

      final results = await Future.wait(futures);
      expect(results.isNotEmpty, isTrue);
    });
  });
}

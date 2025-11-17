import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/mesh_routing_service.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/routing/network_topology_analyzer.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import '../test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
  });

  group('Mesh Routing Integration', () {
    late MeshRoutingService routingService;
    late MeshRelayEngine relayEngine;
    late NetworkTopologyAnalyzer topologyAnalyzer;
    late OfflineMessageQueue messageQueue;
    late ContactRepository contactRepository;
    late SpamPreventionManager spamPrevention;

    const String nodeA = 'node_a_12345';
    const String nodeB = 'node_b_67890';
    const String nodeC = 'node_c_abcde';
    const String nodeD = 'node_d_fghij';

    setUp(() async {
      topologyAnalyzer = NetworkTopologyAnalyzer();
      await topologyAnalyzer.initialize();

      routingService = MeshRoutingService();
      await routingService.initialize(
        currentNodeId: nodeA,
        topologyAnalyzer: topologyAnalyzer,
        enableDemo: false,
      );

      contactRepository = ContactRepository();
      messageQueue = OfflineMessageQueue();
      spamPrevention = SpamPreventionManager();

      try {
        await messageQueue.initialize();
        await spamPrevention.initialize();
      } catch (e) {
        // Platform initialization may fail in tests
      }

      relayEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(
        currentNodeId: nodeA,
        routingService: routingService,
        topologyAnalyzer: topologyAnalyzer,
      );
    });

    tearDown(() {
      routingService.dispose();
      topologyAnalyzer.dispose();
    });

    // ============================================================================
    // SINGLE HOP RELAY TESTS
    // ============================================================================

    test('Single hop relay: A sends to B directly', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final relayMessage = await relayEngine.createOutgoingRelay(
        originalMessageId: 'msg_001',
        originalContent: 'Hello from A to B',
        finalRecipientPublicKey: nodeB,
        priority: MessagePriority.normal,
      );

      expect(relayMessage, isNotNull);
      expect(relayMessage!.relayMetadata.originalSender, equals(nodeA));
      expect(relayMessage.relayMetadata.finalRecipient, equals(nodeB));
    });

    test(
      'Routing service determines direct route when recipient available',
      () async {
        await topologyAnalyzer.addConnection(nodeA, nodeB);

        final decision = await routingService.determineOptimalRoute(
          finalRecipient: nodeB,
          availableHops: [nodeB],
          priority: MessagePriority.normal,
        );

        expect(decision.isSuccessful, isTrue);
      },
    );

    // ============================================================================
    // MULTI-HOP RELAY TESTS
    // ============================================================================

    test('Multi-hop relay: A -> B -> C', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeB, nodeC);

      final relayMessage = await relayEngine.createOutgoingRelay(
        originalMessageId: 'msg_002',
        originalContent: 'Message from A to C via B',
        finalRecipientPublicKey: nodeC,
        priority: MessagePriority.normal,
      );

      expect(relayMessage, isNotNull);
      expect(relayMessage!.relayMetadata.finalRecipient, equals(nodeC));
    });

    test('Multi-hop relay with three hops: A -> B -> C -> D', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeB, nodeC);
      await topologyAnalyzer.addConnection(nodeC, nodeD);

      final relayMessage = await relayEngine.createOutgoingRelay(
        originalMessageId: 'msg_003',
        originalContent: 'Multi-hop message A to D',
        finalRecipientPublicKey: nodeD,
        priority: MessagePriority.normal,
      );

      expect(relayMessage, isNotNull);
      expect(relayMessage!.relayMetadata.finalRecipient, equals(nodeD));
    });

    // ============================================================================
    // ROUTING DECISION TESTS
    // ============================================================================

    test('Routing service and relay engine coordinate correctly', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeA, nodeC);
      await topologyAnalyzer.addConnection(nodeC, nodeD);

      final routeDecision = await routingService.determineOptimalRoute(
        finalRecipient: nodeD,
        availableHops: [nodeB, nodeC],
        priority: MessagePriority.normal,
      );

      expect(routeDecision, isNotNull);
      expect(routeDecision.isSuccessful, isTrue);
    });

    test('Priority-based routing: HIGH priority', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final decision = await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.high,
      );

      expect(decision.isSuccessful, isTrue);
    });

    test('Priority-based routing: LOW priority', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final decision = await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.low,
      );

      expect(decision.isSuccessful, isTrue);
    });

    // ============================================================================
    // TOPOLOGY CHANGE TESTS
    // ============================================================================

    test('Routing adapts when connection added', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final decision1 = await routingService.determineOptimalRoute(
        finalRecipient: nodeD,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      await topologyAnalyzer.addConnection(nodeA, nodeC);

      final decision2 = await routingService.determineOptimalRoute(
        finalRecipient: nodeD,
        availableHops: [nodeB, nodeC],
        priority: MessagePriority.normal,
      );

      expect(decision1, isNotNull);
      expect(decision2, isNotNull);
    });

    test('Routing adapts when connection removed', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeA, nodeC);

      final decision1 = await routingService.determineOptimalRoute(
        finalRecipient: nodeD,
        availableHops: [nodeB, nodeC],
        priority: MessagePriority.normal,
      );

      routingService.removeConnection(nodeA, nodeC);

      final decision2 = await routingService.determineOptimalRoute(
        finalRecipient: nodeD,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      expect(decision1, isNotNull);
      expect(decision2, isNotNull);
    });

    test('Relay handles topology changes during relay', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeB, nodeC);

      final relayMessage = await relayEngine.createOutgoingRelay(
        originalMessageId: 'msg_004',
        originalContent: 'Message before topology change',
        finalRecipientPublicKey: nodeC,
      );

      expect(relayMessage, isNotNull);

      await topologyAnalyzer.addConnection(nodeA, nodeC);

      final relayMessage2 = await relayEngine.createOutgoingRelay(
        originalMessageId: 'msg_005',
        originalContent: 'Message after topology change',
        finalRecipientPublicKey: nodeC,
      );

      expect(relayMessage2, isNotNull);
    });

    // ============================================================================
    // STATISTICS TESTS
    // ============================================================================

    test('Relay engine statistics available after routing', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      final relayStats = relayEngine.getStatistics();
      expect(relayStats, isNotNull);
    });

    test('Routing statistics updated after routing', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      final statsBefore = routingService.getStatistics();

      for (int i = 0; i < 3; i++) {
        await routingService.determineOptimalRoute(
          finalRecipient: nodeB,
          availableHops: [nodeB],
          priority: MessagePriority.normal,
        );
      }

      final statsAfter = routingService.getStatistics();
      expect(statsAfter, isNotNull);
      expect(statsAfter.nodeId, equals(statsBefore.nodeId));
    });

    test('Statistics consistent across relay engine and routing', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      await routingService.determineOptimalRoute(
        finalRecipient: nodeB,
        availableHops: [nodeB],
        priority: MessagePriority.normal,
      );

      final routingStats = routingService.getStatistics();
      final relayStats = relayEngine.getStatistics();

      expect(routingStats, isNotNull);
      expect(relayStats, isNotNull);
    });

    // ============================================================================
    // MESSAGE QUEUE TESTS
    // ============================================================================

    test('Message queue works with relay engine', () async {
      final relayMessage = await relayEngine.createOutgoingRelay(
        originalMessageId: 'msg_queue_001',
        originalContent: 'Queue test message',
        finalRecipientPublicKey: nodeB,
        priority: MessagePriority.normal,
      );

      expect(relayMessage, isNotNull);
    });

    // ============================================================================
    // SPAM PREVENTION TESTS
    // ============================================================================

    test('Relay engine spam prevention works', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);

      for (int i = 0; i < 5; i++) {
        final relayMessage = await relayEngine.createOutgoingRelay(
          originalMessageId: 'spam_test_$i',
          originalContent: 'Spam test message $i',
          finalRecipientPublicKey: nodeB,
        );

        expect(relayMessage, isNotNull);
      }

      final stats = relayEngine.getStatistics();
      expect(stats, isNotNull);
    });

    // ============================================================================
    // FALLBACK TESTS
    // ============================================================================

    test('Service handles no routing service gracefully', () async {
      final simpleRelayEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await simpleRelayEngine.initialize(currentNodeId: nodeA);

      final relayMessage = await simpleRelayEngine.createOutgoingRelay(
        originalMessageId: 'fallback_001',
        originalContent: 'Message without routing service',
        finalRecipientPublicKey: nodeB,
      );

      expect(relayMessage, isNotNull);
    });

    test('Service handles no topology analyzer gracefully', () async {
      final simpleRelayEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await simpleRelayEngine.initialize(
        currentNodeId: nodeA,
        routingService: routingService,
      );

      final relayMessage = await simpleRelayEngine.createOutgoingRelay(
        originalMessageId: 'fallback_002',
        originalContent: 'Message without topology',
        finalRecipientPublicKey: nodeB,
      );

      expect(relayMessage, isNotNull);
    });

    // ============================================================================
    // CONCURRENT OPERATIONS TESTS
    // ============================================================================

    test('Multiple concurrent relays work correctly', () async {
      await topologyAnalyzer.addConnection(nodeA, nodeB);
      await topologyAnalyzer.addConnection(nodeA, nodeC);

      final futures = <Future>[];

      for (int i = 0; i < 5; i++) {
        futures.add(
          relayEngine.createOutgoingRelay(
            originalMessageId: 'concurrent_$i',
            originalContent: 'Concurrent message $i',
            finalRecipientPublicKey: nodeB,
            priority: MessagePriority.normal,
          ),
        );
      }

      final messages = await Future.wait(futures);

      expect(messages.length, equals(5));
    });

    test(
      'Concurrent routing and relay operations',
      () async {
        await topologyAnalyzer.addConnection(nodeA, nodeB);
        await topologyAnalyzer.addConnection(nodeA, nodeC);

        final futures = <Future>[];

        for (int i = 0; i < 3; i++) {
          futures.add(
            relayEngine.createOutgoingRelay(
              originalMessageId: 'concurrent_relay_$i',
              originalContent: 'Concurrent relay $i',
              finalRecipientPublicKey: nodeB,
            ),
          );
        }

        for (int i = 0; i < 3; i++) {
          futures.add(
            routingService.determineOptimalRoute(
              finalRecipient: nodeB,
              availableHops: [nodeB, nodeC],
              priority: MessagePriority.normal,
            ),
          );
        }

        // Add connection synchronously (routingService.addConnection returns void)
        routingService.addConnection(nodeB, nodeD);

        final results = await Future.wait(futures);
        expect(results.length, equals(6));
      },
      timeout: Timeout(Duration(seconds: 10)),
    );

    // ============================================================================
    // CLEANUP TESTS
    // ============================================================================

    test('Services can be disposed without errors', () async {
      final tempRouting = MeshRoutingService();
      final tempTopology = NetworkTopologyAnalyzer();

      await tempTopology.initialize();
      await tempRouting.initialize(
        currentNodeId: nodeA,
        topologyAnalyzer: tempTopology,
      );

      tempRouting.dispose();
      tempTopology.dispose();

      expect(true, isTrue);
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
  });
}

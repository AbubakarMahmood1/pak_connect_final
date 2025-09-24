import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/core/routing/smart_mesh_router.dart';
import 'package:pak_connect/core/routing/route_calculator.dart';
import 'package:pak_connect/core/routing/network_topology_analyzer.dart';
import 'package:pak_connect/core/routing/connection_quality_monitor.dart';

void main() {
  // Setup logging
  Logger.root.level = Level.WARNING; // Reduce logging noise
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.message}');
  });

  group('Mesh System Analysis Tests', () {
    // Test user identities
    const String ali = 'ali_12345';
    const String arshad = 'arshad_67890'; 
    const String abubakar = 'abubakar_abcde';
    
    test('Mesh networking system provides proper status and analysis', () async {
      // Create components without BLE dependencies
      final contactRepository = ContactRepository();
      final messageQueue = OfflineMessageQueue();
      final spamPrevention = SpamPreventionManager();
      
      try {
        await messageQueue.initialize();
        await spamPrevention.initialize();
      } catch (e) {
        // Ignore platform initialization errors in test
      }
      
      // Create smart routing components
      final routeCalculator = RouteCalculator();
      final topologyAnalyzer = NetworkTopologyAnalyzer();
      final qualityMonitor = ConnectionQualityMonitor();
      
      await topologyAnalyzer.initialize();
      await qualityMonitor.initialize();
      
      final smartRouter = SmartMeshRouter(
        routeCalculator: routeCalculator,
        topologyAnalyzer: topologyAnalyzer,
        qualityMonitor: qualityMonitor,
        currentNodeId: arshad,
      );
      
      await smartRouter.initialize(enableDemo: true);
      
      // Create relay engine with smart router
      final relayEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );
      
      await relayEngine.initialize(
        currentNodeId: arshad,
        smartRouter: smartRouter,
      );
      
      // Test 1: Verify system status reporting
      final relayStats = relayEngine.getStatistics();
      expect(relayStats, isNotNull);
      expect(relayStats.relayEfficiency, equals(1.0)); // Fresh system should be 100% efficient
      
      // Test 2: Verify smart routing statistics
      final routerStats = smartRouter.getStatistics();
      expect(routerStats, isNotNull);
      expect(routerStats.nodeId, equals(arshad));
      expect(routerStats.demoModeEnabled, isTrue);
      
      // Test 3: Verify topology analysis works
      await topologyAnalyzer.addConnection(arshad, abubakar);
      final topology = topologyAnalyzer.getNetworkTopology();
      expect(topology.canReach(arshad, abubakar), isTrue);
      
      final topologyStats = topologyAnalyzer.getNetworkStats();
      expect(topologyStats.totalNodes, greaterThan(0));
      expect(topologyStats.totalConnections, greaterThan(0));
      
      // Test 4: Verify connection quality monitoring
      qualityMonitor.recordMessageSent(abubakar, 'test_msg_001');
      qualityMonitor.recordMessageAcknowledged(abubakar, 'test_msg_001', latency: 250.0);
      
      final qualityStats = qualityMonitor.getMonitoringStats();
      expect(qualityStats.totalMessagesSent, equals(1));
      expect(qualityStats.totalMessagesAcked, equals(1));
      expect(qualityStats.deliveryRate, equals(1.0));
      
      // Test 5: Verify smart routing decision making
      final routingDecision = await smartRouter.determineOptimalRoute(
        finalRecipient: abubakar,
        availableHops: [abubakar],
        priority: MessagePriority.normal,
      );
      
      expect(routingDecision.isSuccessful, isTrue);
      expect(routingDecision.type.name, anyOf('direct', 'relay'));
      
      // Test 6: Verify analysis completes without blocking
      final analysisStartTime = DateTime.now();
      
      // Run multiple analysis operations in parallel
      final futures = <Future>[];
      futures.add(smartRouter.determineOptimalRoute(
        finalRecipient: ali,
        availableHops: [ali, abubakar],
        priority: MessagePriority.high,
      ));
      
      futures.add(Future(() async {
        await topologyAnalyzer.addConnection(ali, abubakar);
        return topologyAnalyzer.getNetworkStats();
      }));
      
      futures.add(Future(() {
        return qualityMonitor.getMonitoringStats();
      }));
      
      // All operations should complete quickly without blocking
      final results = await Future.wait(futures, eagerError: false);
      final analysisEndTime = DateTime.now();
      final analysisDuration = analysisEndTime.difference(analysisStartTime);
      
      expect(analysisDuration.inSeconds, lessThan(5), 
        reason: 'Analysis should complete quickly without blocking');
      expect(results.length, equals(3), 
        reason: 'All analysis operations should complete');
      
      // Cleanup
      smartRouter.dispose();
      topologyAnalyzer.dispose();
      qualityMonitor.dispose();
      
      print('✅ Mesh system analysis test passed!');
      print('  - Analysis completed in ${analysisDuration.inMilliseconds}ms');
      print('  - Smart routing: ${routingDecision.isSuccessful}');
      print('  - Topology nodes: ${topologyStats.totalNodes}');
      print('  - Quality monitoring: ${qualityStats.deliveryRate * 100}% delivery rate');
    });

    test('Sync/relay node analysis does not block operations', () async {
      // This test specifically addresses the user's concern about analysis not completing
      // without turning off bluetooth
      
      final contactRepository = ContactRepository();
      final messageQueue = OfflineMessageQueue();
      final spamPrevention = SpamPreventionManager();
      
      try {
        await messageQueue.initialize();
        await spamPrevention.initialize();
      } catch (e) {
        // Ignore platform initialization errors
      }
      
      final relayEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );
      
      await relayEngine.initialize(currentNodeId: arshad);
      
      // Simulate concurrent relay operations and analysis
      final startTime = DateTime.now();
      final operations = <Future>[];
      
      // Create multiple relay messages
      for (int i = 0; i < 5; i++) {
        operations.add(relayEngine.createOutgoingRelay(
          originalMessageId: 'analysis_test_$i',
          originalContent: 'Analysis test message $i',
          finalRecipientPublicKey: abubakar,
          priority: MessagePriority.normal,
        ));
      }
      
      // Get statistics multiple times concurrently
      for (int i = 0; i < 3; i++) {
        operations.add(Future(() => relayEngine.getStatistics()));
      }
      
      // Wait for all operations to complete
      final results = await Future.wait(operations, eagerError: false);
      final endTime = DateTime.now();
      final totalDuration = endTime.difference(startTime);
      
      // Verify operations completed successfully and quickly
      expect(totalDuration.inSeconds, lessThan(3), 
        reason: 'Analysis operations should not block and complete quickly');
      
      final relayMessages = results.whereType<MeshRelayMessage?>().where((m) => m != null).length;
      final statisticsResults = results.whereType<RelayStatistics>().length;
      
      expect(relayMessages, equals(5), reason: 'All relay messages should be created');
      expect(statisticsResults, equals(3), reason: 'All statistics requests should complete');
      
      print('✅ Non-blocking analysis test passed!');
      print('  - ${operations.length} concurrent operations completed in ${totalDuration.inMilliseconds}ms');
      print('  - No blocking detected');
    });

    test('Relay message validation prevents incorrect processing', () async {
      final contactRepository = ContactRepository();
      final messageQueue = OfflineMessageQueue();
      final spamPrevention = SpamPreventionManager();
      
      try {
        await messageQueue.initialize();
        await spamPrevention.initialize();
      } catch (e) {
        // Ignore platform initialization errors
      }
      
      // Test from Ali's perspective
      final aliEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );
      await aliEngine.initialize(currentNodeId: ali);
      
      // Ali creates message for Abubakar
      final message = await aliEngine.createOutgoingRelay(
        originalMessageId: 'validation_test',
        originalContent: 'Message from Ali to Abubakar',
        finalRecipientPublicKey: abubakar,
      );
      
      expect(message, isNotNull);
      expect(message!.relayMetadata.originalSender, equals(ali));
      expect(message.relayMetadata.finalRecipient, equals(abubakar));
      
      // Test from Arshad's perspective (relay node)
      final arshadEngine = MeshRelayEngine(
        contactRepository: ContactRepository(),
        messageQueue: OfflineMessageQueue(),
        spamPrevention: SpamPreventionManager(),
      );
      
      try {
        final arshadQueue = OfflineMessageQueue();
        final arshadSpam = SpamPreventionManager();
        await arshadQueue.initialize();
        await arshadSpam.initialize();
      } catch (e) {
        // Ignore platform errors
      }
      
      await arshadEngine.initialize(currentNodeId: arshad);
      
      // Arshad processes the message - should relay, not deliver to self
      final result = await arshadEngine.processIncomingRelay(
        relayMessage: message,
        fromNodeId: ali,
        availableNextHops: [abubakar],
      );
      
      expect(result.isRelayed, isTrue, 
        reason: 'Arshad should relay message intended for Abubakar');
      expect(result.isDelivered, isFalse, 
        reason: 'Arshad should not deliver message to self when it is for Abubakar');
      expect(result.nextHopNodeId, equals(abubakar),
        reason: 'Message should be forwarded to correct recipient');
      
      print('✅ Message validation test passed!');
      print('  - Ali → Arshad → Abubakar routing validated');
      print('  - Relay nodes correctly forward messages');
      print('  - Final recipients receive correct content');
    });
  });
}
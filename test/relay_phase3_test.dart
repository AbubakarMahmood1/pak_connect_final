// Phase 3: Network-Size Adaptive Relay Testing
// Tests probabilistic relay based on network size to prevent broadcast storms

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/routing/network_topology_analyzer.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/data/services/seen_message_store.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Initialize database factory for tests
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Enable logging for debugging
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  group('Phase 3: Network Size Tracking', () {
    test('NetworkTopologyAnalyzer returns correct network size', () async {
      final analyzer = NetworkTopologyAnalyzer();
      await analyzer.initialize();

      // Initially no nodes
      expect(analyzer.getNetworkSize(), equals(0));

      // Add some connections
      await analyzer.addConnection('node_a', 'node_b');
      expect(analyzer.getNetworkSize(), equals(2));

      await analyzer.addConnection('node_b', 'node_c');
      expect(analyzer.getNetworkSize(), equals(3));

      await analyzer.addConnection('node_c', 'node_d');
      expect(analyzer.getNetworkSize(), equals(4));

      analyzer.dispose();
    });

    test('Network size includes all unique nodes from connections', () async {
      final analyzer = NetworkTopologyAnalyzer();
      await analyzer.initialize();

      // Create a mesh with multiple connections
      await analyzer.addConnection('node_a', 'node_b');
      await analyzer.addConnection('node_a', 'node_c');
      await analyzer.addConnection('node_b', 'node_c');

      // Should have 3 unique nodes
      expect(analyzer.getNetworkSize(), equals(3));

      analyzer.dispose();
    });
  });

  group('Phase 3: Relay Probability Calculation', () {
    late MeshRelayEngine relayEngine;
    late NetworkTopologyAnalyzer topologyAnalyzer;
    late ContactRepository contactRepo;
    late OfflineMessageQueue messageQueue;
    late SpamPreventionManager spamPrevention;

    setUp(() async {
      contactRepo = ContactRepository();

      messageQueue = OfflineMessageQueue();
      await messageQueue.initialize(contactRepository: contactRepo);

      spamPrevention = SpamPreventionManager();
      await spamPrevention.initialize();

      topologyAnalyzer = NetworkTopologyAnalyzer();
      await topologyAnalyzer.initialize();

      relayEngine = MeshRelayEngine(
        contactRepository: contactRepo,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(
        currentNodeId: 'test_node',
        topologyAnalyzer: topologyAnalyzer,
      );
    });

    tearDown(() {
      topologyAnalyzer.dispose();
    });

    test('Small network (≤3 nodes) has 100% relay probability', () async {
      // Create small network
      await topologyAnalyzer.addConnection('node_1', 'node_2');
      await topologyAnalyzer.addConnection('node_2', 'node_3');

      final stats = relayEngine.getStatistics();
      expect(stats.networkSize, equals(3));
      expect(stats.currentRelayProbability, equals(1.0));
    });

    test('Medium network (≤10 nodes) has 100% relay probability', () async {
      // Create medium network with 10 nodes
      for (int i = 1; i < 10; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final stats = relayEngine.getStatistics();
      expect(stats.networkSize, equals(10));
      expect(stats.currentRelayProbability, equals(1.0));
    });

    test('Growing network (≤30 nodes) has 85% relay probability', () async {
      // Create growing network with 30 nodes
      for (int i = 1; i < 30; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final stats = relayEngine.getStatistics();
      expect(stats.networkSize, equals(30));
      expect(stats.currentRelayProbability, equals(0.85));
    });

    test('Large network (≤50 nodes) has 70% relay probability', () async {
      // Create large network with 50 nodes
      for (int i = 1; i < 50; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final stats = relayEngine.getStatistics();
      expect(stats.networkSize, equals(50));
      expect(stats.currentRelayProbability, equals(0.7));
    });

    test('Very large network (≤100 nodes) has 55% relay probability', () async {
      // Create very large network with 100 nodes
      for (int i = 1; i < 100; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final stats = relayEngine.getStatistics();
      expect(stats.networkSize, equals(100));
      expect(stats.currentRelayProbability, equals(0.55));
    });

    test('Massive network (>100 nodes) has 40% relay probability', () async {
      // Create massive network with 150 nodes
      for (int i = 1; i < 150; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final stats = relayEngine.getStatistics();
      expect(stats.networkSize, equals(150));
      expect(stats.currentRelayProbability, equals(0.4));
    });
  });

  group('Phase 3: Probabilistic Relay Behavior', () {
    late MeshRelayEngine relayEngine;
    late NetworkTopologyAnalyzer topologyAnalyzer;
    late ContactRepository contactRepo;
    late OfflineMessageQueue messageQueue;
    late SpamPreventionManager spamPrevention;

    setUp(() async {
      contactRepo = ContactRepository();

      messageQueue = OfflineMessageQueue();
      await messageQueue.initialize(contactRepository: contactRepo);

      spamPrevention = SpamPreventionManager();
      await spamPrevention.initialize();

      topologyAnalyzer = NetworkTopologyAnalyzer();
      await topologyAnalyzer.initialize();

      relayEngine = MeshRelayEngine(
        contactRepository: contactRepo,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(
        currentNodeId: 'test_node_relay',
        topologyAnalyzer: topologyAnalyzer,
      );

      // Clear seen message store for clean tests
      final seenStore = SeenMessageStore.instance;
      await seenStore.initialize();
      await seenStore.clear();
    });

    tearDown(() {
      topologyAnalyzer.dispose();
    });

    test('Small network (3 nodes) relays all messages (100%)', () async {
      // Create small network
      await topologyAnalyzer.addConnection('node_1', 'node_2');
      await topologyAnalyzer.addConnection('node_2', 'node_3');

      relayEngine.clearStatistics();

      // Process 10 relay messages
      int relayedOrDelivered = 0;
      for (int i = 0; i < 10; i++) {
        final relayMessage = MeshRelayMessage.createRelay(
          originalMessageId: 'msg_$i',
          originalContent: 'Test message $i',
          metadata: RelayMetadata.create(
            originalMessageContent: 'Test',
            priority: MessagePriority.normal,
            originalSender: 'sender_node',
            finalRecipient: 'other_node_$i',
            currentNodeId: 'sender_node',
          ),
          relayNodeId: 'relay_node',
        );

        final result = await relayEngine.processIncomingRelay(
          relayMessage: relayMessage,
          fromNodeId: 'relay_node',
          availableNextHops: ['next_hop_node'],
          messageType: ProtocolMessageType.textMessage,
        );

        if (result.isSuccess) {
          relayedOrDelivered++;
        }
      }

      // Small network should relay ALL messages (no probabilistic skip)
      final stats = relayEngine.getStatistics();
      expect(stats.totalProbabilisticSkip, equals(0));
      expect(relayedOrDelivered, equals(10));
    });

    test('Large network (50 nodes) skips some messages probabilistically', () async {
      // Create large network with 50 nodes (70% relay probability)
      for (int i = 1; i < 50; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      relayEngine.clearStatistics();

      // Process 100 relay messages to get statistical sample
      int relayedOrDelivered = 0; // Counter for successful relay/delivery
      int probabilisticSkips = 0;

      for (int i = 0; i < 100; i++) {
        final relayMessage = MeshRelayMessage.createRelay(
          originalMessageId: 'msg_large_$i',
          originalContent: 'Test message $i',
          metadata: RelayMetadata.create(
            originalMessageContent: 'Test',
            priority: MessagePriority.normal,
            originalSender: 'sender_node',
            finalRecipient: 'other_node_$i',
            currentNodeId: 'sender_node',
          ),
          relayNodeId: 'relay_node',
        );

        final result = await relayEngine.processIncomingRelay(
          relayMessage: relayMessage,
          fromNodeId: 'relay_node',
          availableNextHops: ['next_hop_node'],
          messageType: ProtocolMessageType.textMessage,
        );

        if (result.isSuccess) {
          relayedOrDelivered++;
        } else if (result.reason?.contains('Probabilistic') ?? false) {
          probabilisticSkips++;
        }
      }

      final stats = relayEngine.getStatistics();

      // With 70% relay probability, we expect ~30% to be skipped
      // Allow tolerance due to randomness (20-40% skip rate)
      expect(probabilisticSkips, greaterThan(20));
      expect(probabilisticSkips, lessThan(40));
      expect(stats.totalProbabilisticSkip, equals(probabilisticSkips));
      expect(relayedOrDelivered + probabilisticSkips, equals(100)); // All messages accounted for
    });

    test('Massive network (150 nodes) skips majority of messages', () async {
      // Create massive network with 150 nodes (40% relay probability)
      for (int i = 1; i < 150; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      relayEngine.clearStatistics();

      // Process 100 relay messages
      int probabilisticSkips = 0;

      for (int i = 0; i < 100; i++) {
        final relayMessage = MeshRelayMessage.createRelay(
          originalMessageId: 'msg_massive_$i',
          originalContent: 'Test message $i',
          metadata: RelayMetadata.create(
            originalMessageContent: 'Test',
            priority: MessagePriority.normal,
            originalSender: 'sender_node',
            finalRecipient: 'other_node_$i',
            currentNodeId: 'sender_node',
          ),
          relayNodeId: 'relay_node',
        );

        final result = await relayEngine.processIncomingRelay(
          relayMessage: relayMessage,
          fromNodeId: 'relay_node',
          availableNextHops: ['next_hop_node'],
          messageType: ProtocolMessageType.textMessage,
        );

        if (result.reason?.contains('Probabilistic') ?? false) {
          probabilisticSkips++;
        }
      }

      final stats = relayEngine.getStatistics();

      // With 40% relay probability, we expect ~60% to be skipped
      // Allow tolerance (50-70% skip rate)
      expect(probabilisticSkips, greaterThan(50));
      expect(probabilisticSkips, lessThan(70));
      expect(stats.totalProbabilisticSkip, equals(probabilisticSkips));
    });
  });

  group('Phase 3: Statistics Tracking', () {
    late MeshRelayEngine relayEngine;
    late NetworkTopologyAnalyzer topologyAnalyzer;
    late ContactRepository contactRepo;
    late OfflineMessageQueue messageQueue;
    late SpamPreventionManager spamPrevention;

    setUp(() async {
      contactRepo = ContactRepository();

      messageQueue = OfflineMessageQueue();
      await messageQueue.initialize(contactRepository: contactRepo);

      spamPrevention = SpamPreventionManager();
      await spamPrevention.initialize();

      topologyAnalyzer = NetworkTopologyAnalyzer();
      await topologyAnalyzer.initialize();

      relayEngine = MeshRelayEngine(
        contactRepository: contactRepo,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(
        currentNodeId: 'test_stats_node',
        topologyAnalyzer: topologyAnalyzer,
      );
    });

    tearDown(() {
      topologyAnalyzer.dispose();
    });

    test('Statistics include network size and relay probability', () async {
      // Create network with 30 nodes
      for (int i = 1; i < 30; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final stats = relayEngine.getStatistics();

      expect(stats.networkSize, equals(30));
      expect(stats.currentRelayProbability, equals(0.85));
      expect(stats.totalProbabilisticSkip, equals(0)); // No messages processed yet
    });

    test('Statistics track probabilistic skip count', () async {
      // Create large network
      for (int i = 1; i < 50; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      relayEngine.clearStatistics();
      final seenStore = SeenMessageStore.instance;
      await seenStore.clear();

      // Process messages until we get some probabilistic skips
      int attempts = 0;
      while (attempts < 50) {
        final relayMessage = MeshRelayMessage.createRelay(
          originalMessageId: 'msg_stats_$attempts',
          originalContent: 'Test',
          metadata: RelayMetadata.create(
            originalMessageContent: 'Test',
            priority: MessagePriority.normal,
            originalSender: 'sender',
            finalRecipient: 'other',
            currentNodeId: 'sender',
          ),
          relayNodeId: 'relay',
        );

        await relayEngine.processIncomingRelay(
          relayMessage: relayMessage,
          fromNodeId: 'relay',
          availableNextHops: ['next'],
          messageType: ProtocolMessageType.textMessage,
        );

        attempts++;
      }

      final stats = relayEngine.getStatistics();

      // With 70% relay probability, we should see some skips
      expect(stats.totalProbabilisticSkip, greaterThan(0));
    });

    test('Clear statistics resets probabilistic skip count', () async {
      for (int i = 1; i < 50; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      // Process some messages
      final seenStore = SeenMessageStore.instance;
      await seenStore.clear();

      for (int i = 0; i < 20; i++) {
        final relayMessage = MeshRelayMessage.createRelay(
          originalMessageId: 'msg_clear_$i',
          originalContent: 'Test',
          metadata: RelayMetadata.create(
            originalMessageContent: 'Test',
            priority: MessagePriority.normal,
            originalSender: 'sender',
            finalRecipient: 'other',
            currentNodeId: 'sender',
          ),
          relayNodeId: 'relay',
        );

        await relayEngine.processIncomingRelay(
          relayMessage: relayMessage,
          fromNodeId: 'relay',
          availableNextHops: ['next'],
          messageType: ProtocolMessageType.textMessage,
        );
      }

      // Clear and verify
      relayEngine.clearStatistics();
      final stats = relayEngine.getStatistics();

      expect(stats.totalProbabilisticSkip, equals(0));
      expect(stats.totalRelayed, equals(0));
      expect(stats.totalDropped, equals(0));
    });
  });

  group('Phase 3: Integration Tests', () {
    test('Probabilistic relay works with existing relay logic', () async {
      final contactRepo = ContactRepository();

      final messageQueue = OfflineMessageQueue();
      await messageQueue.initialize(contactRepository: contactRepo);

      final spamPrevention = SpamPreventionManager();
      await spamPrevention.initialize();

      final topologyAnalyzer = NetworkTopologyAnalyzer();
      await topologyAnalyzer.initialize();

      // Create large network
      for (int i = 1; i < 50; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final relayEngine = MeshRelayEngine(
        contactRepository: contactRepo,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(
        currentNodeId: 'integration_node',
        topologyAnalyzer: topologyAnalyzer,
      );

      final seenStore = SeenMessageStore.instance;
      await seenStore.clear();

      // Process a message
      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'integration_msg',
        originalContent: 'Integration test',
        metadata: RelayMetadata.create(
          originalMessageContent: 'Integration test',
          priority: MessagePriority.normal,
          originalSender: 'sender_node',
          finalRecipient: 'other_node',
          currentNodeId: 'sender_node',
        ),
        relayNodeId: 'relay_node',
      );

      final result = await relayEngine.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: 'relay_node',
        availableNextHops: ['next_hop'],
        messageType: ProtocolMessageType.textMessage,
      );

      // Result should be either relayed or probabilistically skipped
      // Both are valid outcomes with large network
      expect(
        result.isSuccess || (result.reason?.contains('Probabilistic') ?? false),
        isTrue,
      );

      final stats = relayEngine.getStatistics();
      expect(stats.networkSize, equals(50));
      expect(stats.currentRelayProbability, equals(0.7));

      topologyAnalyzer.dispose();
    });

    test('Messages for current node always delivered (bypass probabilistic skip)', () async {
      final contactRepo = ContactRepository();

      final messageQueue = OfflineMessageQueue();
      await messageQueue.initialize(contactRepository: contactRepo);

      final spamPrevention = SpamPreventionManager();
      await spamPrevention.initialize();

      final topologyAnalyzer = NetworkTopologyAnalyzer();
      await topologyAnalyzer.initialize();

      // Create massive network (40% relay probability)
      for (int i = 1; i < 150; i++) {
        await topologyAnalyzer.addConnection('node_$i', 'node_${i + 1}');
      }

      final currentNodeId = 'delivery_test_node';
      final relayEngine = MeshRelayEngine(
        contactRepository: contactRepo,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(
        currentNodeId: currentNodeId,
        topologyAnalyzer: topologyAnalyzer,
      );

      final seenStore = SeenMessageStore.instance;
      await seenStore.clear();

      // Create message FOR current node
      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'delivery_msg',
        originalContent: 'Message for me',
        metadata: RelayMetadata.create(
          originalMessageContent: 'Message for me',
          priority: MessagePriority.normal,
          originalSender: 'sender_node',
          finalRecipient: currentNodeId,  // This message is FOR us
          currentNodeId: 'sender_node',
        ),
        relayNodeId: 'relay_node',
      );

      final result = await relayEngine.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: 'relay_node',
        availableNextHops: ['next_hop'],
        messageType: ProtocolMessageType.textMessage,
      );

      // Message should ALWAYS be delivered to us, never probabilistically skipped
      expect(result.isDelivered, isTrue);

      final stats = relayEngine.getStatistics();
      expect(stats.totalDeliveredToSelf, equals(1));
      expect(stats.totalProbabilisticSkip, equals(0)); // No skip for messages to us

      topologyAnalyzer.dispose();
    });
  });
}

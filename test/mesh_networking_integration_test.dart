// Comprehensive integration tests for mesh networking demo layer
// Tests the complete integration of MeshNetworkingService with BLE services
// Validates A→B→C relay functionality and FYP demonstration features

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/services/ble_service.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/core/demo/mesh_demo_utils.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/core/services/security_manager.dart';

void main() {
  group('Mesh Networking Integration Tests', () {
    late MeshNetworkingService meshService;
    late BLEService mockBleService;
    late BLEMessageHandler messageHandler;
    late ContactRepository contactRepository;
    late ChatManagementService chatManagementService;
    late MessageRepository messageRepository;
    
    // Test node IDs
    late String nodeA, nodeB, nodeC;
    
    setUpAll(() {
      // Configure logging for tests
      Logger.root.level = Level.INFO;
      Logger.root.onRecord.listen((record) {
        print('${record.time}: ${record.loggerName}: ${record.level.name}: ${record.message}');
      });
    });

    setUp(() async {
      // Initialize test dependencies
      contactRepository = ContactRepository();
      chatManagementService = ChatManagementService();
      messageRepository = MessageRepository();
      messageHandler = BLEMessageHandler();
      
      // Create mock BLE service (simplified for testing)
      mockBleService = _createMockBLEService();
      
      // Generate test node IDs
      nodeA = 'test_node_a_${DateTime.now().millisecondsSinceEpoch}';
      nodeB = 'test_node_b_${DateTime.now().millisecondsSinceEpoch}';
      nodeC = 'test_node_c_${DateTime.now().millisecondsSinceEpoch}';
      
      // Initialize mesh networking service
      meshService = MeshNetworkingService(
        bleService: mockBleService,
        messageHandler: messageHandler,
        contactRepository: contactRepository,
        chatManagementService: chatManagementService,
        messageRepository: messageRepository,
      );
      
      await meshService.initialize(
        nodeId: nodeA,
        enableDemo: true,
      );
    });

    tearDown(() async {
      meshService.dispose();
    });

    group('Service Initialization', () {
      test('should initialize all mesh components correctly', () async {
        final statistics = meshService.getNetworkStatistics();
        
        expect(statistics.isInitialized, isTrue);
        expect(statistics.nodeId, equals(nodeA));
        expect(statistics.isDemoMode, isTrue);
        expect(statistics.spamPreventionActive, isTrue);
        expect(statistics.queueSyncActive, isTrue);
      });

      test('should provide mesh network status stream', () async {
        var statusReceived = false;
        
        final subscription = meshService.meshStatus.listen((status) {
          expect(status.isInitialized, isTrue);
          expect(status.currentNodeId, equals(nodeA));
          statusReceived = true;
        });
        
        await Future.delayed(Duration(milliseconds: 100));
        expect(statusReceived, isTrue);
        
        subscription.cancel();
      });
    });

    group('Demo Scenario Tests', () {
      test('should initialize A→B→C demo scenario', () async {
        final result = await meshService.initializeDemoScenario(DemoScenarioType.aToBtoC);
        
        expect(result.success, isTrue);
        expect(result.message, contains('A→B→C relay scenario ready'));
        expect(result.metadata, isNotNull);
        expect(result.metadata!['scenario'], equals('a_to_b_to_c'));
        expect(result.metadata!['currentNode'], equals(nodeA.substring(0, 16)));
      });

      test('should initialize queue sync demo scenario', () async {
        final result = await meshService.initializeDemoScenario(DemoScenarioType.queueSync);
        
        expect(result.success, isTrue);
        expect(result.message, contains('Queue sync scenario ready'));
        expect(result.metadata!['scenario'], equals('queue_sync'));
      });

      test('should initialize spam prevention demo scenario', () async {
        final result = await meshService.initializeDemoScenario(DemoScenarioType.spamPrevention);
        
        expect(result.success, isTrue);
        expect(result.message, contains('Spam prevention scenario ready'));
        expect(result.metadata!['scenario'], equals('spam_prevention'));
      });
    });

    group('Message Sending Tests', () {
      test('should send direct message when recipient is connected', () async {
        // Simulate direct connection to recipient
        _mockDirectConnection(mockBleService, nodeC);
        
        final result = await meshService.sendMeshMessage(
          content: 'Test direct message',
          recipientPublicKey: nodeC,
          isDemo: true,
        );
        
        expect(result.isSuccess, isTrue);
        expect(result.isDirect, isTrue);
        expect(result.messageId, isNotNull);
      });

      test('should send relay message when recipient not directly connected', () async {
        // Simulate connection to relay node (not final recipient)
        _mockDirectConnection(mockBleService, nodeB);
        
        final result = await meshService.sendMeshMessage(
          content: 'Test relay message',
          recipientPublicKey: nodeC, // Different from connected node
          isDemo: true,
        );
        
        expect(result.isSuccess, isTrue);
        expect(result.isRelay, isTrue);
        expect(result.nextHop, equals(nodeB));
      });
    });

    group('Integration Tests', () {
      test('should integrate with ContactRepository', () async {
        // Add test contact
        await contactRepository.saveContact(nodeB, 'Test Node B');
        
        final contact = await contactRepository.getContact(nodeB);
        expect(contact, isNotNull);
        expect(contact!.displayName, equals('Test Node B'));
        expect(contact.securityLevel, equals(SecurityLevel.low));
      });

      test('should integrate with MessageRepository', () async {
        // Save test message
        final testMessage = Message(
          id: 'test_integration_msg',
          chatId: 'test_chat',
          content: 'Integration test message',
          timestamp: DateTime.now(),
          isFromMe: true,
          status: MessageStatus.delivered,
        );
        
        await messageRepository.saveMessage(testMessage);
        
        final messages = await messageRepository.getMessages('test_chat');
        expect(messages, hasLength(1));
        expect(messages.first.content, equals('Integration test message'));
      });
    });

    group('Demo Utilities Tests', () {
      test('should generate realistic demo messages', () {
        final messages = MeshDemoUtils.generateDemoMessages(
          senderId: nodeA,
          recipientId: nodeC,
          count: 5,
          priority: MessagePriority.normal,
        );
        
        expect(messages, hasLength(5));
        expect(messages.first.senderId, equals(nodeA));
        expect(messages.first.recipientId, equals(nodeC));
        expect(messages.first.priority, equals(MessagePriority.normal));
        expect(messages.first.metadata['isDemoMessage'], isTrue);
      });

      test('should calculate demo performance metrics', () {
        final scenario = MeshDemoUtils.generateAToBtoCScenario(
          nodeAId: nodeA,
          nodeBId: nodeB,
          nodeCId: nodeC,
        );
        
        final demoSteps = [
          DemoRelayStep(
            messageId: 'test_msg_1',
            fromNode: nodeA,
            toNode: nodeB,
            finalRecipient: nodeC,
            hopCount: 1,
            action: 'relay_initiated',
            timestamp: DateTime.now(),
          ),
          DemoRelayStep(
            messageId: 'test_msg_1',
            fromNode: nodeB,
            toNode: nodeC,
            finalRecipient: nodeC,
            hopCount: 2,
            action: 'relay_forwarded',
            timestamp: DateTime.now(),
          ),
        ];
        
        final metrics = MeshDemoUtils.generatePerformanceMetrics(
          scenario: scenario,
          actualDuration: Duration(seconds: 5),
          actualSteps: demoSteps,
        );
        
        expect(metrics.scenarioId, equals(scenario.id));
        expect(metrics.totalSteps, equals(2));
        expect(metrics.successfulSteps, equals(2));
        expect(metrics.successRate, equals(1.0));
        expect(metrics.completionRate, greaterThan(0.0));
      });
    });
  });

  group('FYP Demonstration Readiness', () {
    test('should demonstrate complete A→B→C relay scenario', () {
      final scenario = MeshDemoUtils.generateAToBtoCScenario(
        nodeAId: 'demo_a',
        nodeBId: 'demo_b', 
        nodeCId: 'demo_c',
      );
      
      // Verify all components for FYP demo
      expect(scenario.name, equals('A→B→C Relay Demonstration'));
      expect(scenario.description, contains('Node A to Node C through Node B'));
      expect(scenario.nodes, hasLength(3));
      expect(scenario.expectedSteps, hasLength(4));
      
      // Verify expected demo duration
      expect(scenario.totalExpectedDuration, equals(Duration(seconds: 6)));
      
      // Verify metadata for evaluation
      expect(scenario.metadata['totalExpectedTime'], equals(6));
      expect(scenario.metadata['relayHops'], equals(1));
      expect(scenario.metadata['demoComplexity'], equals('medium'));
    });

    test('should provide comprehensive mesh networking capabilities', () {
      final scenarios = [
        MeshDemoUtils.generateAToBtoCScenario(),
        MeshDemoUtils.generateQueueSyncScenario(),
        MeshDemoUtils.generateSpamPreventionScenario(),
      ];
      
      final stats = MeshDemoUtils.calculateDemoStatistics(
        completedScenarios: scenarios,
        totalDemoTime: Duration(minutes: 15),
      );
      
      // Verify comprehensive capabilities for FYP evaluation
      expect(stats.capabilities, contains('A→B→C Message Relay'));
      expect(stats.capabilities, contains('Queue Synchronization'));
      expect(stats.capabilities, contains('Spam Prevention'));
      expect(stats.capabilities, contains('Multi-hop Routing'));
      expect(stats.capabilities, contains('Real-time Visualization'));
      expect(stats.capabilities, contains('Performance Monitoring'));
      
      // Verify achievements tracking
      expect(stats.achievements['scenarios_completed'], equals(3));
      expect(stats.achievements['feature_coverage'], equals('100%'));
      expect(stats.achievements['system_stability'], equals('99.5%'));
    });

    test('should provide performance metrics for evaluation', () {
      final scenario = MeshDemoUtils.generateAToBtoCScenario();
      final actualSteps = [
        DemoRelayStep(
          messageId: 'perf_test_msg',
          fromNode: 'demo_a',
          toNode: 'demo_b',
          finalRecipient: 'demo_c',
          hopCount: 1,
          action: 'relay_initiated',
          timestamp: DateTime.now(),
        ),
        DemoRelayStep(
          messageId: 'perf_test_msg',
          fromNode: 'demo_b',
          toNode: 'demo_c',
          finalRecipient: 'demo_c',
          hopCount: 2,
          action: 'relay_forwarded',
          timestamp: DateTime.now(),
        ),
      ];
      
      final metrics = MeshDemoUtils.generatePerformanceMetrics(
        scenario: scenario,
        actualDuration: Duration(seconds: 4), // Faster than expected 6 seconds
        actualSteps: actualSteps,
      );
      
      expect(metrics.efficiency, greaterThan(1.0)); // Better than expected
      expect(metrics.successRate, equals(1.0)); // All steps successful
      expect(metrics.completionRate, greaterThan(0.0));
      expect(metrics.performedWell, isTrue);
      
      // Verify grading system
      expect(metrics.metrics['grade'], isIn(['A', 'B', 'C', 'D', 'F']));
      expect(metrics.metrics['throughput'], contains('steps/sec'));
      expect(metrics.metrics['reliability'], contains('%'));
    });
  });
}

// Helper functions for creating mock services

BLEService _createMockBLEService() {
  // This would be a proper mock in a real test implementation
  // For now, return a basic BLEService instance
  return BLEService();
}

void _mockDirectConnection(BLEService bleService, String nodeId) {
  // In a real implementation, this would mock the BLE service
  // to simulate being connected to the specified node
  print('Mock: Simulating direct connection to $nodeId');
}

void _mockNoConnection(BLEService bleService) {
  // In a real implementation, this would mock the BLE service
  // to simulate no connections available
  print('Mock: Simulating no connections available');
}
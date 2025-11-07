// Tests for Phase 1: Role Awareness implementation
// Verifies relay configuration, message type filtering, and enhanced role detection

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/messaging/relay_config_manager.dart';
import 'package:pak_connect/core/messaging/relay_policy.dart';
import 'package:pak_connect/core/models/protocol_message.dart';

void main() {
  group('Phase 1: Relay Config Manager', () {
    // Reset config before each test
    setUp(() async {
      final config = RelayConfigManager.instance;
      await config.resetToDefaults();
    });

    test('Default relay config should be enabled', () async {
      final config = RelayConfigManager.instance;
      await config.initialize();

      expect(config.isRelayEnabled(), isTrue);
      expect(config.getMaxRelayHops(), equals(10));
      expect(config.getBatteryThreshold(), equals(20));
    });

    test('Should disable and enable relay within single test', () async {
      final config = RelayConfigManager.instance;
      await config.initialize();

      // Ensure we start enabled
      await config.enableRelay();
      expect(config.isRelayEnabled(), isTrue);

      // Disable
      await config.disableRelay();
      expect(config.isRelayEnabled(), isFalse);

      // Re-enable
      await config.enableRelay();
      expect(config.isRelayEnabled(), isTrue);
    });

    test('Should validate battery threshold', () async {
      final config = RelayConfigManager.instance;
      await config.initialize();

      // Set a known threshold for testing
      await config.setBatteryThreshold(20);

      // Should relay when battery is above threshold
      expect(config.shouldRelayWithBatteryLevel(50), isTrue);
      expect(config.shouldRelayWithBatteryLevel(21), isTrue);
      expect(config.shouldRelayWithBatteryLevel(20), isTrue);

      // Should NOT relay when battery is below threshold
      expect(config.shouldRelayWithBatteryLevel(19), isFalse);
      expect(config.shouldRelayWithBatteryLevel(10), isFalse);
    });

    test('Should set and get max relay hops within single test', () async {
      final config = RelayConfigManager.instance;
      await config.initialize();

      final originalHops = config.getMaxRelayHops();

      await config.setMaxRelayHops(15);
      expect(config.getMaxRelayHops(), equals(15));

      await config.setMaxRelayHops(5);
      expect(config.getMaxRelayHops(), equals(5));

      // Restore original
      await config.setMaxRelayHops(originalHops);
    });

    test('Should get config summary', () async {
      final config = RelayConfigManager.instance;
      await config.initialize();

      final summary = config.getConfigSummary();
      expect(summary, isA<Map<String, dynamic>>());
      expect(summary['relayEnabled'], isNotNull);
      expect(summary['maxRelayHops'], isNotNull);
      expect(summary['batteryThreshold'], isNotNull);
    });
  });

  group('Phase 1: Relay Policy - Message Type Filtering', () {
    test('Handshake messages should NOT be relay-eligible', () {
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.connectionReady,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.identity),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.noiseHandshake1,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.noiseHandshake2,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.noiseHandshake3,
        ),
        isFalse,
      );
    });

    test('Pairing messages should NOT be relay-eligible', () {
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.pairingRequest,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.pairingAccept,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.pairingCode),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.pairingCancel,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.contactRequest,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.contactAccept,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.contactReject,
        ),
        isFalse,
      );
    });

    test('Control messages should NOT be relay-eligible', () {
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.ping),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.ack),
        isFalse,
      );
    });

    test('Normal messages SHOULD be relay-eligible', () {
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.textMessage),
        isTrue,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.meshRelay),
        isTrue,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.queueSync),
        isTrue,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.relayAck),
        isTrue,
      );
    });

    test('Should get relay-eligible and non-relayable type lists', () {
      final eligible = RelayPolicy.getRelayEligibleTypes();
      final nonRelayable = RelayPolicy.getNonRelayableTypes();

      // Lists should not be empty
      expect(eligible.isNotEmpty, isTrue);
      expect(nonRelayable.isNotEmpty, isTrue);

      // Lists should not overlap
      for (final type in eligible) {
        expect(nonRelayable.contains(type), isFalse);
      }
    });
  });

  group('Phase 1: Relay Policy - Message Validation', () {
    test('Should reject message with non-eligible type', () {
      final result = RelayPolicy.validateMessageForRelay(
        messageType: ProtocolMessageType.pairingRequest,
        recipientId: 'node123',
      );

      expect(result.isAllowed, isFalse);
      expect(result.code, equals(RelayRejectionCode.messageTypeNotEligible));
      expect(result.reason, contains('not relay-eligible'));
    });

    test('Should reject message with no recipient', () {
      final result = RelayPolicy.validateMessageForRelay(
        messageType: ProtocolMessageType.textMessage,
        recipientId: null,
      );

      expect(result.isAllowed, isFalse);
      expect(result.code, equals(RelayRejectionCode.noRecipient));
      expect(result.reason, contains('no recipient'));
    });

    test('Should reject message with empty recipient', () {
      final result = RelayPolicy.validateMessageForRelay(
        messageType: ProtocolMessageType.textMessage,
        recipientId: '',
      );

      expect(result.isAllowed, isFalse);
      expect(result.code, equals(RelayRejectionCode.noRecipient));
    });

    test('Should reject message with TTL exceeded', () {
      final result = RelayPolicy.validateMessageForRelay(
        messageType: ProtocolMessageType.textMessage,
        recipientId: 'node123',
        currentHopCount: 10,
        maxHops: 10,
      );

      expect(result.isAllowed, isFalse);
      expect(result.code, equals(RelayRejectionCode.ttlExceeded));
      expect(result.reason, contains('TTL exceeded'));
    });

    test('Should allow valid message for relay', () {
      final result = RelayPolicy.validateMessageForRelay(
        messageType: ProtocolMessageType.textMessage,
        recipientId: 'node123',
        currentHopCount: 5,
        maxHops: 10,
      );

      expect(result.isAllowed, isTrue);
      expect(result.reason, isNull);
      expect(result.code, isNull);
    });

    test('Should allow message without TTL checks', () {
      final result = RelayPolicy.validateMessageForRelay(
        messageType: ProtocolMessageType.meshRelay,
        recipientId: 'node123',
      );

      expect(result.isAllowed, isTrue);
    });
  });

  group('Phase 1: Integration Tests', () {
    test('Relay config should handle configuration changes', () async {
      final config = RelayConfigManager.instance;
      await config.initialize();

      // Store original values
      final originalHops = config.getMaxRelayHops();
      final originalBattery = config.getBatteryThreshold();
      final originalEnabled = config.isRelayEnabled();

      // Set custom values
      await config.setMaxRelayHops(25);
      await config.setBatteryThreshold(35);
      await config.disableRelay();

      expect(config.getMaxRelayHops(), equals(25));
      expect(config.getBatteryThreshold(), equals(35));
      expect(config.isRelayEnabled(), isFalse);

      // Restore original values
      await config.setMaxRelayHops(originalHops);
      await config.setBatteryThreshold(originalBattery);
      if (originalEnabled) {
        await config.enableRelay();
      }
    });

    test('All ProtocolMessageTypes should be categorized', () {
      // Every protocol message type should have a relay eligibility decision
      for (final type in ProtocolMessageType.values) {
        final isEligible = RelayPolicy.isRelayEligibleMessageType(type);
        // Just verify it returns a boolean without error
        expect(isEligible, isA<bool>());
      }
    });

    test('Message type filtering should be consistent', () {
      // Same message type should always return same result
      for (int i = 0; i < 5; i++) {
        expect(
          RelayPolicy.isRelayEligibleMessageType(
            ProtocolMessageType.textMessage,
          ),
          isTrue,
        );
        expect(
          RelayPolicy.isRelayEligibleMessageType(
            ProtocolMessageType.pairingRequest,
          ),
          isFalse,
        );
      }
    });
  });

  group('Phase 1: BitChat Compatibility', () {
    setUp(() async {
      final config = RelayConfigManager.instance;
      await config.resetToDefaults();
    });

    test('Should match BitChat relay enablement behavior', () async {
      // BitChat has isRelayEnabled() flag
      final config = RelayConfigManager.instance;
      await config.initialize();

      // Store original state
      final originalEnabled = config.isRelayEnabled();

      // Ensure relay is enabled first
      await config.enableRelay();
      expect(config.isRelayEnabled(), isTrue);

      // Should be able to disable (like BitChat)
      await config.disableRelay();
      expect(config.isRelayEnabled(), isFalse);

      // Restore original state
      if (originalEnabled) {
        await config.enableRelay();
      }
    });

    test('Should match BitChat message type filtering behavior', () {
      // BitChat explicitly excludes handshake from relay
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.noiseHandshake1,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.noiseHandshake2,
        ),
        isFalse,
      );
      expect(
        RelayPolicy.isRelayEligibleMessageType(
          ProtocolMessageType.noiseHandshake3,
        ),
        isFalse,
      );

      // BitChat allows normal messages to be relayed
      expect(
        RelayPolicy.isRelayEligibleMessageType(ProtocolMessageType.textMessage),
        isTrue,
      );
    });

    test('Should handle broadcast messages like BitChat', () {
      // BitChat returns false for broadcast recipients
      final result = RelayPolicy.validateMessageForRelay(
        messageType: ProtocolMessageType.textMessage,
        recipientId: null, // Broadcast
      );

      expect(result.isAllowed, isFalse);
      expect(result.code, equals(RelayRejectionCode.noRecipient));
    });
  });
}

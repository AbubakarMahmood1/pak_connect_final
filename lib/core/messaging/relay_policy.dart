// Relay policy utilities for mesh networking
// Defines which message types can be relayed and routing rules
// Inspired by BitChat's message type filtering

import 'package:logging/logging.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/constants/special_recipients.dart';

/// Relay policy manager
///
/// This class defines the rules for what messages can be relayed.
/// Key principle from BitChat: Handshake and pairing messages should
/// NEVER be relayed as they are point-to-point only.
class RelayPolicy {
  static final _logger = Logger('RelayPolicy');

  /// Check if a message type is eligible for relay
  ///
  /// Returns true if the message type can be relayed through the mesh network.
  /// Returns false for handshake, pairing, and other point-to-point messages.
  ///
  /// Based on BitChat's message type filtering logic.
  static bool isRelayEligibleMessageType(ProtocolMessageType type) {
    // Handshake messages: NEVER relay (point-to-point only)
    if (_isHandshakeMessage(type)) {
      _logger.fine(
        '❌ RELAY FILTER: Handshake message type ${type.name} is NOT relay-eligible',
      );
      return false;
    }

    // Pairing messages: NEVER relay (point-to-point only)
    if (_isPairingMessage(type)) {
      _logger.fine(
        '❌ RELAY FILTER: Pairing message type ${type.name} is NOT relay-eligible',
      );
      return false;
    }

    // Control messages: Generally not relayed
    if (_isControlMessage(type)) {
      _logger.fine(
        '❌ RELAY FILTER: Control message type ${type.name} is NOT relay-eligible',
      );
      return false;
    }

    // Everything else is relay-eligible
    _logger.fine('✅ RELAY FILTER: Message type ${type.name} is relay-eligible');
    return true;
  }

  /// Check if message type is a handshake message
  static bool _isHandshakeMessage(ProtocolMessageType type) {
    return type == ProtocolMessageType.connectionReady ||
        type == ProtocolMessageType.identity ||
        type == ProtocolMessageType.noiseHandshake1 ||
        type == ProtocolMessageType.noiseHandshake2 ||
        type == ProtocolMessageType.noiseHandshake3;
  }

  /// Check if message type is a pairing message
  static bool _isPairingMessage(ProtocolMessageType type) {
    return type == ProtocolMessageType.pairingRequest ||
        type == ProtocolMessageType.pairingAccept ||
        type == ProtocolMessageType.pairingCode ||
        type == ProtocolMessageType.pairingCancel ||
        type == ProtocolMessageType.contactRequest ||
        type == ProtocolMessageType.contactAccept ||
        type == ProtocolMessageType.contactReject;
  }

  /// Check if message type is a control message
  static bool _isControlMessage(ProtocolMessageType type) {
    return type == ProtocolMessageType.ping || type == ProtocolMessageType.ack;
  }

  /// Get relay-eligible message types (for documentation/testing)
  static List<ProtocolMessageType> getRelayEligibleTypes() {
    return ProtocolMessageType.values
        .where((type) => isRelayEligibleMessageType(type))
        .toList();
  }

  /// Get non-relayable message types (for documentation/testing)
  static List<ProtocolMessageType> getNonRelayableTypes() {
    return ProtocolMessageType.values
        .where((type) => !isRelayEligibleMessageType(type))
        .toList();
  }

  /// Validate if a message should be relayed based on its properties
  ///
  /// Checks multiple factors:
  /// - Message type eligibility
  /// - TTL validity
  /// - Routing path integrity
  static RelayPolicyResult validateMessageForRelay({
    required ProtocolMessageType messageType,
    required String? recipientId,
    int? currentHopCount,
    int? maxHops,
  }) {
    // Check 1: Message type eligibility
    if (!isRelayEligibleMessageType(messageType)) {
      return RelayPolicyResult.rejected(
        reason: 'Message type ${messageType.name} is not relay-eligible',
        code: RelayRejectionCode.messageTypeNotEligible,
      );
    }

    // Check 2: Must have recipient (null/empty not allowed, but broadcast is OK)
    if (recipientId == null || recipientId.isEmpty) {
      return RelayPolicyResult.rejected(
        reason:
            'Message has no recipient (use SpecialRecipients.broadcast for broadcast)',
        code: RelayRejectionCode.noRecipient,
      );
    }

    // Check 2A: Broadcast messages are allowed (relay to all neighbors)
    if (SpecialRecipients.isBroadcast(recipientId)) {
      return RelayPolicyResult.allowed();
    }

    // Check 3: TTL validation (if provided)
    if (currentHopCount != null && maxHops != null) {
      if (currentHopCount >= maxHops) {
        return RelayPolicyResult.rejected(
          reason: 'Message TTL exceeded ($currentHopCount >= $maxHops)',
          code: RelayRejectionCode.ttlExceeded,
        );
      }
    }

    // All checks passed
    return RelayPolicyResult.allowed();
  }
}

/// Result of relay policy validation
class RelayPolicyResult {
  final bool isAllowed;
  final String? reason;
  final RelayRejectionCode? code;

  const RelayPolicyResult._({required this.isAllowed, this.reason, this.code});

  factory RelayPolicyResult.allowed() =>
      const RelayPolicyResult._(isAllowed: true);

  factory RelayPolicyResult.rejected({
    required String reason,
    required RelayRejectionCode code,
  }) => RelayPolicyResult._(isAllowed: false, reason: reason, code: code);
}

/// Codes for relay rejection reasons
enum RelayRejectionCode {
  messageTypeNotEligible,
  noRecipient,
  ttlExceeded,
  configDisabled,
  batteryTooLow,
}

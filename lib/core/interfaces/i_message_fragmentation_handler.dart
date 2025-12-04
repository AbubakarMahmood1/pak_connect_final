import 'dart:typed_data';
import '../../core/utils/message_fragmenter.dart';
import '../../core/models/protocol_message.dart';
import '../../domain/values/id_types.dart';

class ForwardReassembledPayload {
  ForwardReassembledPayload({
    required this.bytes,
    required this.originalType,
    required this.recipient,
    required this.ttl,
  });

  final Uint8List bytes;
  final int originalType;
  final String? recipient;
  final int ttl;
}

class ReassembledPayload {
  ReassembledPayload({
    required this.bytes,
    required this.receivedAt,
    this.isBinary = false,
    this.originalType,
    this.recipient,
    this.ttl,
    this.suppressForwarding = false,
  });

  final Uint8List bytes;
  final DateTime receivedAt;
  final bool isBinary;
  final int? originalType;
  final String? recipient;
  final int? ttl;
  final bool suppressForwarding;
}

/// Interface for message fragmentation and reassembly handling
///
/// Responsibilities:
/// - Detecting fragmented messages (multi-chunk messages)
/// - Reassembling chunks into complete messages
/// - Managing fragment timeouts and cleanup
/// - Handling ACK messages for reliable delivery
/// - Periodic cleanup of stale reassembly state
abstract interface class IMessageFragmentationHandler {
  /// Set the local node ID for recipient-aware fragment reassembly.
  void setLocalNodeId(String nodeId);

  /// Detects if raw bytes look like a fragmented message chunk
  ///
  /// Returns true if the bytes contain fragmentation markers (e.g., chunk index/total)
  bool looksLikeChunkString(Uint8List bytes);

  /// Main entry point for processing received data from BLE
  ///
  /// Handles:
  /// - Fragment detection and reassembly
  /// - Timeout management for partial messages
  /// - ACK message handling
  /// - Returns complete message content when all chunks received
  ///
  /// Returns:
  /// - Complete message content if reassembly successful
  /// - null if message is still partial or reassembly failed
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  });

  /// Registers an ACK callback for a specific message
  ///
  /// Called when a message is sent to wait for delivery confirmation
  Future<bool> registerMessageAck({
    required String messageId,
    required Duration timeout,
  });

  Future<bool> registerMessageAckWithId({
    required MessageId messageId,
    required Duration timeout,
  });

  /// Acknowledges successful message receipt
  ///
  /// Called when ACK is received for a previously sent message
  void acknowledgeMessage(String messageId);

  void acknowledgeMessageWithId(MessageId messageId);

  /// Gets current reassembly state for debugging
  ///
  /// Returns map of messageId → partial chunk progress
  Map<String, int> getReassemblyState();

  /// Cleans up old partial messages that have timed out
  ///
  /// Called periodically (every 2 minutes) to prevent memory leaks
  void cleanupOldMessages();

  /// Retrieves and removes a forwarded binary fragment envelope by id + index.
  Uint8List? takeForwardFragment(String fragmentId, int index);

  /// Retrieves and removes a fully reassembled binary payload for forwarding
  /// (used when downstream MTU is smaller than incoming fragments).
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId);

  /// Disposes resources (timers, etc.)
  void dispose();
}

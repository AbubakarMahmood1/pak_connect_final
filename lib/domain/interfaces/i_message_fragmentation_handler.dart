import 'dart:typed_data';

import '../values/id_types.dart';

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
abstract interface class IMessageFragmentationHandler {
  /// Set the local node ID for recipient-aware fragment reassembly.
  void setLocalNodeId(String nodeId);

  /// Detects if raw bytes look like a fragmented message chunk.
  bool looksLikeChunkString(Uint8List bytes);

  /// Main entry point for processing received data from BLE.
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  });

  /// Registers an ACK callback for a specific message.
  Future<bool> registerMessageAck({
    required String messageId,
    required Duration timeout,
  });

  Future<bool> registerMessageAckWithId({
    required MessageId messageId,
    required Duration timeout,
  });

  /// Acknowledges successful message receipt.
  void acknowledgeMessage(String messageId);

  void acknowledgeMessageWithId(MessageId messageId);

  /// Gets current reassembly state for debugging.
  Map<String, int> getReassemblyState();

  /// Cleans up old partial messages that have timed out.
  void cleanupOldMessages();

  /// Retrieves and removes a forwarded binary fragment envelope by id + index.
  Uint8List? takeForwardFragment(String fragmentId, int index);

  /// Retrieves and removes a fully reassembled binary payload for forwarding
  /// (used when downstream MTU is smaller than incoming fragments).
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId);

  /// Disposes resources (timers, etc.)
  void dispose();
}

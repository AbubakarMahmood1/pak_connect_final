import 'dart:typed_data';

import '../models/binary_payload.dart';
import '../models/mesh_relay_models.dart';
import '../models/protocol_message.dart';

export '../models/binary_payload.dart' show BinaryPayload;

/// Manages BLE message transmission and reception including:
/// - Chat message encryption and sending (central & peripheral modes)
/// - Protocol message fragmentation and write queue serialization
/// - Message decryption and event emission
/// - Identity exchange protocol messages
///
/// Single responsibility: Handle all messaging-related operations
/// Dependencies: BLEMessageHandler, MessageFragmenter, SecurityManager
/// Consumers: MeshNetworkingService, BLEProviders, HomeScreen
abstract class IBLEMessagingService {
  // ============================================================================
  // MESSAGE SENDING
  // ============================================================================

  /// Send a chat message from central role
  /// Encrypts, fragments, and queues message for transmission
  ///
  /// Args:
  ///   message - Plain text chat message
  ///   messageId - Optional pre-generated message ID (for relay tracking)
  ///   originalIntendedRecipient - Original recipient for relay messages
  /// Returns:
  ///   true if message queued successfully, false if error (offline queue handles failures)
  /// Throws:
  ///   StateError if not in central mode or identity not established
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  });

  /// Send a chat message from peripheral role
  /// Same as sendMessage() but uses peripheral-mode connection
  ///
  /// Args:
  ///   message - Plain text chat message
  ///   messageId - Optional pre-generated message ID
  /// Returns:
  ///   true if message queued successfully, false if error
  /// Throws:
  ///   StateError if not in peripheral mode or identity not established
  Future<bool> sendPeripheralMessage(String message, {String? messageId});

  /// Send mesh network queue sync message (for relay network discovery)
  /// Used by MeshNetworkingService to coordinate message routing
  ///
  /// Args:
  ///   queueMessage - Queue sync message with routing info
  /// Throws:
  ///   StateError if not connected or handshake not complete
  Future<void> sendQueueSyncMessage(QueueSyncMessage queueMessage);

  /// Send binary/media payload; returns transferId for retry tracking.
  /// Implementation attempts Noise encryption when a session is available.
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  });

  /// Retry a previously persisted binary/media payload using the latest MTU.
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  });

  // ============================================================================
  // IDENTITY EXCHANGE (PROTOCOL LEVEL)
  // ============================================================================

  /// Send identity exchange message from central role
  /// Includes ephemeralId, displayName, noisePublicKey
  ///
  /// Throws:
  ///   StateError if not in central mode
  Future<void> sendIdentityExchange();

  /// Send identity exchange message from peripheral role
  /// Same as sendIdentityExchange() but for peripheral mode
  ///
  /// Throws:
  ///   StateError if not in peripheral mode
  Future<void> sendPeripheralIdentityExchange();

  /// Send handshake protocol message (Noise XX/KK)
  /// Fragments and queues for transmission
  ///
  /// Args:
  ///   message - Protocol message (ephemeral data)
  /// Throws:
  ///   StateError if not in active handshake
  Future<void> sendHandshakeMessage(covariant ProtocolMessage message);

  // ============================================================================
  // IDENTITY MANAGEMENT (USER-LEVEL)
  // ============================================================================

  /// Request manual identity re-exchange with peer
  /// Useful for recovering from identity desync
  ///
  /// Throws:
  ///   StateError if not connected
  Future<void> requestIdentityExchange();

  /// Trigger identity re-exchange after username change
  /// Propagates updated identity to peer in real-time
  ///
  /// Args:
  ///   newUsername - Updated display name (propagated to peer)
  /// Throws:
  ///   StateError if not connected
  Future<void> triggerIdentityReExchange();

  // ============================================================================
  // MESSAGE RECEPTION & STREAM
  // ============================================================================

  /// Stream of decrypted chat messages received from peer
  /// Emits message content for UI display
  Stream<String> get receivedMessagesStream;

  /// Stream of binary/media payloads received (already reassembled).
  Stream<BinaryPayload> get receivedBinaryStream;

  /// Latest extracted message ID (for ACK tracking in relay)
  String? get lastExtractedMessageId;

  /// Route inbound GATT writes (central → our peripheral) into the messaging
  /// pipeline so protocol/handshake messages are parsed.
  Future<void> processIncomingPeripheralData(
    Uint8List data, {
    required String senderDeviceId,
    String? senderNodeId,
  });

  // ============================================================================
  // MESH RELAY INTEGRATION
  // ============================================================================

  /// Register callback for queue sync message interception
  /// Called by MeshNetworkingService to intercept and process relay messages
  ///
  /// Args:
  ///   handler - Callback that returns true if message was handled by mesh layer
  void registerQueueSyncMessageHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  );
}

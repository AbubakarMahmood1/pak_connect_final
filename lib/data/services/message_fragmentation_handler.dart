import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_message_fragmentation_handler.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/models/protocol_message.dart';

/// Handles message fragmentation, reassembly, and ACK management
///
/// Responsibilities:
/// - Detecting fragmented messages (multi-chunk format)
/// - Reassembling chunks into complete messages
/// - Managing ACK callbacks for delivery confirmation
/// - Timeout management for partial messages
/// - Periodic cleanup of stale reassembly state
class MessageFragmentationHandler implements IMessageFragmentationHandler {
  final _logger = Logger('MessageFragmentationHandler');

  // Message fragmentation and reassembly
  final MessageReassembler _messageReassembler = MessageReassembler();
  final Map<String, _ReassembledMessage> _completedMessages = {};

  // ACK management
  final Map<String, Timer> _messageTimeouts = {};
  final Map<String, Completer<bool>> _messageAcks = {};

  Timer? _cleanupTimer;
  bool _cleanupInProgress = false;

  MessageFragmentationHandler({bool enableCleanupTimer = false}) {
    // Setup periodic cleanup of old partial messages
    if (enableCleanupTimer) {
      _cleanupTimer ??= Timer.periodic(
        Duration(minutes: 2),
        (_) => cleanupOldMessages(),
      );
    }
  }

  /// Detects if raw bytes look like a fragmented message chunk
  ///
  /// Fragmented messages have format: id|idx|total|isBinary|content
  /// This method checks for 4+ pipe characters and valid ASCII-like content
  @override
  bool looksLikeChunkString(Uint8List bytes) {
    final max = bytes.length < 128 ? bytes.length : 128;
    int pipes = 0;
    for (var i = 0; i < max; i++) {
      final b = bytes[i];
      if (b == 0x7C) pipes++; // '|'
      // Reject most control chars except TAB(9), LF(10), CR(13)
      if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return false;
      // Reject extended binary (our chunk strings are ASCII)
      if (b > 0x7E) return false;
    }
    return pipes >= 4; // id|idx|total|isBinary|content
  }

  /// Main entry point for processing received data from BLE
  ///
  /// Pipeline:
  /// 1. Skip single-byte pings
  /// 2. Check for direct protocol messages (non-fragmented)
  /// 3. Process fragmented chunks if applicable
  /// 4. Return complete message when all chunks received
  @override
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  }) async {
    try {
      _logger.fine('📥 Processing ${data.length} bytes from BLE');

      // Skip single-byte pings
      if (data.length == 1 && data[0] == 0x00) {
        _logger.fine('📥 Skipping single-byte ping');
        return null;
      }

      // Check for direct protocol messages (non-fragmented)
      try {
        final directMessage = String.fromCharCodes(data);
        if (ProtocolMessage.isProtocolMessage(directMessage)) {
          _logger.fine('📥 Detected direct protocol message (non-chunked)');
          // Signal that we found a direct message (not fragmented)
          // The caller will handle the actual processing
          return 'DIRECT_PROTOCOL_MESSAGE'; // Marker to indicate fragment handler completes
        }
      } catch (e) {
        // Not a direct message, try chunk processing
        _logger.fine(
          '📥 Not a direct protocol message, checking for fragments: $e',
        );
      }

      // Process as message chunk ONLY if it looks like chunk format
      if (looksLikeChunkString(data)) {
        try {
          _logger.fine('📥 Parsing as MessageChunk');
          final chunk = MessageChunk.fromBytes(data);
          _logger.fine(
            '📥 Parsed chunk: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}',
          );

          // Add chunk to reassembler
          final completeMessageBytes = _messageReassembler.addChunkBytes(chunk);
          _logger.fine(
            '📥 Reassembler: ${completeMessageBytes != null ? "MESSAGE COMPLETE ✅" : "waiting for more chunks ⏳"}',
          );

          if (completeMessageBytes != null) {
            _logger.fine(
              '📥 Processing complete message (${completeMessageBytes.length} bytes)',
            );
            _completedMessages[chunk.messageId] = _ReassembledMessage(
              bytes: completeMessageBytes,
              receivedAt: DateTime.now(),
            );
            // Return complete message marker with length
            // Caller will reconstruct from reassembler
            return 'REASSEMBLY_COMPLETE:${chunk.messageId}';
          }
        } catch (e) {
          _logger.warning('Chunk processing failed: $e');
        }
      } else {
        _logger.fine('📥 Not a chunk-string payload');
        return null;
      }
    } catch (e) {
      _logger.severe('Error processing received data: $e');
    }

    return null;
  }

  /// Registers an ACK callback for a specific message
  @override
  Future<bool> registerMessageAck({
    required String messageId,
    required Duration timeout,
  }) async {
    final completer = Completer<bool>();
    _messageAcks[messageId] = completer;

    // Start timeout timer
    _messageTimeouts[messageId] = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
        _messageAcks.remove(messageId);
        _messageTimeouts.remove(messageId);
        _logger.warning('⏱️ ACK timeout for message: $messageId');
      }
    });

    try {
      return await completer.future;
    } finally {
      // Cleanup
      _messageTimeouts[messageId]?.cancel();
      _messageTimeouts.remove(messageId);
    }
  }

  /// Acknowledges successful message receipt
  @override
  void acknowledgeMessage(String messageId) {
    final completer = _messageAcks[messageId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
      _messageAcks.remove(messageId);
      _messageTimeouts[messageId]?.cancel();
      _messageTimeouts.remove(messageId);
      _logger.fine('✅ ACK received for message: $messageId');
    }
  }

  /// Gets current reassembly state for debugging
  @override
  Map<String, int> getReassemblyState() {
    // Get state from reassembler
    // This would require a getter in MessageReassembler
    return {};
  }

  /// Retrieves and removes completed reassembled message bytes by ID.
  Uint8List? takeReassembledMessageBytes(String messageId) {
    final completed = _completedMessages.remove(messageId);
    if (completed == null) {
      _logger.fine('📥 No completed message found for id: $messageId');
      return null;
    }

    return completed.bytes;
  }

  /// Cleans up old partial messages that have timed out
  @override
  void cleanupOldMessages() {
    if (_cleanupInProgress) return;
    _cleanupInProgress = true;
    try {
      _messageReassembler.cleanupOldMessages();
      final cutoff = DateTime.now().subtract(Duration(minutes: 2));
      _completedMessages.removeWhere(
        (_, completed) => completed.receivedAt.isBefore(cutoff),
      );
      _logger.fine('🧹 Cleaned up old partial messages');
    } finally {
      _cleanupInProgress = false;
    }
  }

  /// Disposes resources (timers, etc.)
  @override
  void dispose() {
    _cleanupTimer?.cancel();

    // Cancel all pending ACK timers
    for (var timer in _messageTimeouts.values) {
      timer.cancel();
    }
    _messageTimeouts.clear();

    // Complete any pending ACK completers
    for (var completer in _messageAcks.values) {
      if (!completer.isCompleted) {
        completer.completeError('Handler disposed');
      }
    }
    _messageAcks.clear();

    _completedMessages.clear();

    _logger.info('🔌 MessageFragmentationHandler disposed');
  }
}

class _ReassembledMessage {
  final Uint8List bytes;
  final DateTime receivedAt;

  _ReassembledMessage({required this.bytes, required this.receivedAt});
}

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../utils/message_fragmenter.dart';

/// Sends message fragments over BLE via a provided write callback.
class MessageChunkSender {
  MessageChunkSender({
    this.logger,
    this.interChunkDelay = const Duration(milliseconds: 100),
  });

  final Logger? logger;
  final Duration interChunkDelay;

  Future<void> sendChunks({
    required String messageId,
    required List<MessageChunk> fragments,
    required Future<void> Function(Uint8List data) sendChunk,
    void Function(int index, MessageChunk fragment)? onBeforeSend,
    void Function(int index, MessageChunk fragment)? onAfterSend,
  }) async {
    for (int i = 0; i < fragments.length; i++) {
      final fragment = fragments[i];
      onBeforeSend?.call(i, fragment);
      await sendChunk(fragment.toBytes());
      onAfterSend?.call(i, fragment);

      if (i < fragments.length - 1) {
        await Future.delayed(interChunkDelay);
      }
    }

    logger?.fine('Sent ${fragments.length} chunks for message: $messageId');
  }
}

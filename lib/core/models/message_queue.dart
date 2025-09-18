import 'dart:typed_data';

class QueuedMessage {
  final String id;
  final String targetPublicKey;
  final String senderPublicKey;
  final Uint8List encryptedContent;
  final DateTime queuedAt;
  final int retryCount;
  
  QueuedMessage({
    required this.id,
    required this.targetPublicKey,
    required this.senderPublicKey,
    required this.encryptedContent,
    required this.queuedAt,
    this.retryCount = 0,
  });
}
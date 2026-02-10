// Queue message status and exception types
//
// Extracted from offline_message_queue.dart for better separation of concerns.
// These enums and exceptions are used across multiple layers.

/// Queue message status
enum QueuedMessageStatus {
  pending,
  sending,
  awaitingAck, // Waiting for final recipient ACK in mesh relay
  retrying,
  delivered,
  failed,
}

/// Exception for queue operations
class MessageQueueException implements Exception {
  final String message;
  const MessageQueueException(this.message);

  @override
  String toString() => 'MessageQueueException: $message';
}

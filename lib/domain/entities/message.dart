import '../values/id_types.dart';

class Message {
  final MessageId id;
  final String chatId; // device UUID for now, group ID later
  final String content;
  final DateTime timestamp;
  final bool isFromMe;
  final MessageStatus status;

  Message({
    required this.id,
    required this.chatId,
    required this.content,
    required this.timestamp,
    required this.isFromMe,
    required this.status,
  });

  // Convert to/from JSON for storage
  Map<String, dynamic> toJson() => {
    'id': id.value,
    'chatId': chatId,
    'content': content,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'isFromMe': isFromMe,
    'status': status.index,
  };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    id: MessageId(json['id']),
    chatId: json['chatId'],
    content: json['content'],
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
    isFromMe: json['isFromMe'],
    status: MessageStatus.values[json['status']],
  );

  Message copyWith({MessageStatus? status}) => Message(
    id: id,
    chatId: chatId,
    content: content,
    timestamp: timestamp,
    isFromMe: isFromMe,
    status: status ?? this.status,
  );
}

enum MessageStatus { sending, sent, delivered, failed }

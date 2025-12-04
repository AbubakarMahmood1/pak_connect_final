import 'package:meta/meta.dart';

/// Base class for all string-based value objects to ensure type safety.
///
/// This prevents accidental swapping of IDs (e.g., passing a ChatId where a MessageId is expected).
@immutable
abstract class EntityId<T> {
  final String value;

  const EntityId(this.value) : assert(value.length > 0, 'ID cannot be empty');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EntityId<T> &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Strongly typed ID for Messages
class MessageId extends EntityId<MessageId> {
  const MessageId(super.value);
}

/// Strongly typed ID for Chats (based on Public Key or UUID)
class ChatId extends EntityId<ChatId> {
  const ChatId(super.value);
}

/// Strongly typed ID for Users/Contacts (Public Key)
class UserId extends EntityId<UserId> {
  const UserId(super.value);
}

/// Strongly typed ID for Archives
class ArchiveId extends EntityId<ArchiveId> {
  const ArchiveId(super.value);
}

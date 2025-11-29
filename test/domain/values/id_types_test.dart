import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('EntityId Value Objects', () {
    test('should enforce equality based on value', () {
      const id1 = MessageId('msg_123');
      const id2 = MessageId('msg_123');
      const id3 = MessageId('msg_456');

      expect(id1, equals(id2));
      expect(id1, isNot(equals(id3)));
    });

    test('should differentiate between different ID types with same value', () {
      const msgId = MessageId('123');
      const chatId = ChatId('123');

      // They have different runtime types, so they should not be equal
      expect(msgId, isNot(equals(chatId)));
    });

    test('should return value string in toString', () {
      const id = UserId('user_abc');
      expect(id.toString(), 'user_abc');
    });

    test('should throw assertion error for empty ID', () {
      expect(() => MessageId(''), throwsAssertionError);
    });
  });
}

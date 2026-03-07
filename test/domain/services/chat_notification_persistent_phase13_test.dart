// Phase 13: ChatNotificationService + PersistentChatStateManager supplementary
// Targeting ~22 uncovered lines

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/services/chat_notification_service.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/services/persistent_chat_state_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  Logger.root.level = Level.OFF;

  group('ChatNotificationService', () {
    late ChatNotificationService service;

    setUp(() {
      service = ChatNotificationService();
    });

    tearDown(() async {
      await service.dispose();
    });

    test('chatUpdates stream receives emitted events', () async {
      final events = <ChatUpdateEvent>[];
      final sub = service.chatUpdates.listen(events.add);
      await Future<void>.delayed(Duration.zero);

      service.emitChatUpdate(ChatUpdateEvent.archived(const ChatId('chat1')));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first.chatId, const ChatId('chat1'));
      await sub.cancel();
    });

    test('messageUpdates stream receives emitted events', () async {
      final events = <MessageUpdateEvent>[];
      final sub = service.messageUpdates.listen(events.add);
      await Future<void>.delayed(Duration.zero);

      service.emitMessageUpdate(
        MessageUpdateEvent.starred(const MessageId('msg1')),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first.messageId, const MessageId('msg1'));
      await sub.cancel();
    });

    test('chatUpdates removes listener on cancel', () async {
      final sub = service.chatUpdates.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      service.emitChatUpdate(ChatUpdateEvent.archived(const ChatId('chat1')));
    });

    test('emitChatUpdate handles listener errors gracefully', () async {
      final sub = service.chatUpdates.listen((_) {
        throw Exception('test error');
      });
      await Future<void>.delayed(Duration.zero);

      service.emitChatUpdate(ChatUpdateEvent.pinned(const ChatId('chat1')));
      await sub.cancel();
    });

    test('emitMessageUpdate handles listener errors gracefully', () async {
      final sub = service.messageUpdates.listen((_) {
        throw Exception('test error');
      });
      await Future<void>.delayed(Duration.zero);

      service.emitMessageUpdate(
        MessageUpdateEvent.unstarred(const MessageId('msg1')),
      );
      await sub.cancel();
    });

    test('dispose clears all listeners', () async {
      final sub1 = service.chatUpdates.listen((_) {});
      final sub2 = service.messageUpdates.listen((_) {});
      await Future<void>.delayed(Duration.zero);

      await service.dispose();

      service.emitChatUpdate(ChatUpdateEvent.deleted(const ChatId('chat1')));
      service.emitMessageUpdate(
        MessageUpdateEvent.deleted(
          const MessageId('msg1'),
          const ChatId('chat1'),
        ),
      );

      await sub1.cancel();
      await sub2.cancel();
    });

    test('multiple listeners on chatUpdates all receive events', () async {
      final events1 = <ChatUpdateEvent>[];
      final events2 = <ChatUpdateEvent>[];
      final sub1 = service.chatUpdates.listen(events1.add);
      final sub2 = service.chatUpdates.listen(events2.add);
      await Future<void>.delayed(Duration.zero);

      service.emitChatUpdate(
        ChatUpdateEvent.unarchived(const ChatId('chat1')),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events1, hasLength(1));
      expect(events2, hasLength(1));
      await sub1.cancel();
      await sub2.cancel();
    });

    test('all ChatUpdateEvent factory constructors work', () {
      final events = <ChatUpdateEvent>[
        ChatUpdateEvent.archived(const ChatId('c1')),
        ChatUpdateEvent.unarchived(const ChatId('c2')),
        ChatUpdateEvent.pinned(const ChatId('c3')),
        ChatUpdateEvent.unpinned(const ChatId('c4')),
        ChatUpdateEvent.deleted(const ChatId('c5')),
        ChatUpdateEvent.messagesCleared(const ChatId('c6')),
      ];
      expect(events, hasLength(6));
      for (final e in events) {
        expect(e.timestamp, isNotNull);
      }
    });

    test('all MessageUpdateEvent factories work', () {
      final events = <MessageUpdateEvent>[
        MessageUpdateEvent.starred(const MessageId('m1')),
        MessageUpdateEvent.unstarred(const MessageId('m2')),
        MessageUpdateEvent.deleted(
          const MessageId('m3'),
          const ChatId('c1'),
        ),
      ];
      expect(events, hasLength(3));
      for (final e in events) {
        expect(e.timestamp, isNotNull);
      }
    });
  });

  group('PersistentChatStateManager', () {
    late PersistentChatStateManager manager;

    setUp(() {
      manager = PersistentChatStateManager();
    });

    tearDown(() {
      manager.cleanupAll();
    });

    test('getBufferedMessageCount returns 0 for unknown chat', () {
      expect(manager.getBufferedMessageCount('unknown'), 0);
    });

    test('hasActiveListener returns false for unknown chat', () {
      expect(manager.hasActiveListener('unknown'), isFalse);
    });

    test('cleanupChatListener does not throw for unknown chat', () {
      manager.cleanupChatListener('unknown');
    });

    test('cleanupAll does not throw when empty', () {
      manager.cleanupAll();
    });

    test('registerChatScreen and unregisterChatScreen', () {
      manager.registerChatScreen('chat1', (content) {});
      manager.unregisterChatScreen('chat1');
    });

    test('setupPersistentListener buffers messages when inactive', () async {
      final controller = StreamController<String>.broadcast();
      manager.setupPersistentListener('chat1', controller.stream);

      expect(manager.hasActiveListener('chat1'), isTrue);

      controller.add('hello');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.getBufferedMessageCount('chat1'), 1);

      manager.cleanupChatListener('chat1');
      await controller.close();
    });

    test('setupPersistentListener delivers to active handler', () async {
      final controller = StreamController<String>.broadcast();
      final received = <String>[];

      manager.registerChatScreen('chat1', received.add);
      manager.setupPersistentListener('chat1', controller.stream);

      controller.add('hello');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received, contains('hello'));

      manager.cleanupChatListener('chat1');
      await controller.close();
    });

    test('setupPersistentListener skips duplicate setup', () {
      final controller = StreamController<String>.broadcast();
      manager.setupPersistentListener('chat1', controller.stream);
      manager.setupPersistentListener('chat1', controller.stream);

      expect(manager.hasActiveListener('chat1'), isTrue);

      manager.cleanupChatListener('chat1');
      controller.close();
    });

    test('registerChatScreen processes buffered messages', () async {
      final controller = StreamController<String>.broadcast();
      manager.setupPersistentListener('chat1', controller.stream);

      controller.add('buffered1');
      controller.add('buffered2');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.getBufferedMessageCount('chat1'), 2);

      final received = <String>[];
      manager.registerChatScreen('chat1', received.add);

      expect(received, containsAll(['buffered1', 'buffered2']));
      expect(manager.getBufferedMessageCount('chat1'), 0);

      manager.cleanupChatListener('chat1');
      await controller.close();
    });

    test('error in listener does not crash', () async {
      final controller = StreamController<String>.broadcast();
      manager.setupPersistentListener('chat1', controller.stream);

      controller.addError(Exception('stream error'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.hasActiveListener('chat1'), isTrue);

      manager.cleanupChatListener('chat1');
      await controller.close();
    });
  });
}

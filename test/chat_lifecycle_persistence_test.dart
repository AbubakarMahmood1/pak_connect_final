
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/core/services/persistent_chat_state_manager.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'chat_lifecycle_persistence',
    );
  });

  group('ChatScreen Lifecycle Persistence Tests', () {
    late ProviderContainer container;
    late PersistentChatStateManager persistentManager;
    late StreamController<String> mockMessageStreamController;
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      container = ProviderContainer();
      persistentManager = PersistentChatStateManager();
      mockMessageStreamController = StreamController<String>.broadcast();
    });

    tearDown(() {
      container.dispose();
      persistentManager.cleanupAll();
      mockMessageStreamController.close();
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    testWidgets('Messages survive ChatScreen dispose/recreate cycles', (
      WidgetTester tester,
    ) async {
      const chatId = 'persistent_chat_survival';
      final streamController = StreamController<String>.broadcast();
      final received = <String>[];

      persistentManager.setupPersistentListener(
        chatId,
        streamController.stream,
      );

      persistentManager.registerChatScreen(chatId, received.add);
      streamController.add('live message');
      await tester.pump(const Duration(milliseconds: 50));
      expect(received, contains('live message'));

      persistentManager.unregisterChatScreen(chatId);
      streamController.add('buffered message');
      await tester.pump(const Duration(milliseconds: 50));
      expect(persistentManager.getBufferedMessageCount(chatId), equals(1));

      persistentManager.registerChatScreen(chatId, received.add);
      await tester.pump(const Duration(milliseconds: 50));
      expect(received, contains('buffered message'));
      expect(persistentManager.getBufferedMessageCount(chatId), equals(0));

      streamController.close();
    });

    testWidgets(
      'SecurityStateProvider caching prevents excessive recreations',
      (WidgetTester tester) async {
        const chatId = 'security_state_chat';
        final streamController = StreamController<String>.broadcast();

        // Multiple setup calls should not recreate listeners
        persistentManager.setupPersistentListener(
          chatId,
          streamController.stream,
        );
        persistentManager.setupPersistentListener(
          chatId,
          streamController.stream,
        );

        final debugInfo = persistentManager.getDebugInfo();
        expect(debugInfo['activeListeners'], contains(chatId));

        persistentManager.unregisterChatScreen(chatId);
        streamController.add('cached message');
        await tester.pump(const Duration(milliseconds: 50));
        expect(persistentManager.getBufferedMessageCount(chatId), equals(1));

        persistentManager.registerChatScreen(chatId, (_) {});
        await tester.pump(const Duration(milliseconds: 50));
        expect(persistentManager.getBufferedMessageCount(chatId), equals(0));

        streamController.close();
      },
    );

    test(
      'PersistentChatStateManager handles multiple chats correctly',
      () async {
        const chat1Id = 'chat_1';
        const chat2Id = 'chat_2';

        final stream1Controller = StreamController<String>.broadcast();
        final stream2Controller = StreamController<String>.broadcast();

        final receivedMessages1 = <String>[];
        final receivedMessages2 = <String>[];

        // Setup persistent listeners for both chats
        persistentManager.setupPersistentListener(
          chat1Id,
          stream1Controller.stream,
        );
        persistentManager.setupPersistentListener(
          chat2Id,
          stream2Controller.stream,
        );

        // Register handlers
        persistentManager.registerChatScreen(
          chat1Id,
          (message) => receivedMessages1.add(message),
        );
        persistentManager.registerChatScreen(
          chat2Id,
          (message) => receivedMessages2.add(message),
        );

        // Send messages to both chats
        stream1Controller.add('Message to chat 1');
        stream2Controller.add('Message to chat 2');

        await Future.delayed(Duration(milliseconds: 100));

        expect(receivedMessages1, contains('Message to chat 1'));
        expect(receivedMessages2, contains('Message to chat 2'));
        expect(receivedMessages1.length, equals(1));
        expect(receivedMessages2.length, equals(1));

        // Unregister chat 1 (simulate navigation away)
        persistentManager.unregisterChatScreen(chat1Id);

        // Send more messages
        stream1Controller.add('Buffered message to chat 1');
        stream2Controller.add('Direct message to chat 2');

        await Future.delayed(Duration(milliseconds: 100));

        // Chat 1 message should be buffered, chat 2 delivered directly
        expect(persistentManager.getBufferedMessageCount(chat1Id), equals(1));
        expect(receivedMessages2, contains('Direct message to chat 2'));
        expect(receivedMessages2.length, equals(2));

        // Re-register chat 1
        receivedMessages1.clear();
        persistentManager.registerChatScreen(
          chat1Id,
          (message) => receivedMessages1.add(message),
        );

        await Future.delayed(Duration(milliseconds: 100));

        // Buffered message should now be delivered
        expect(receivedMessages1, contains('Buffered message to chat 1'));
        expect(persistentManager.getBufferedMessageCount(chat1Id), equals(0));

        stream1Controller.close();
        stream2Controller.close();

        debugPrint('✅ Multi-chat persistence verified');
      },
    );

    test('Debug info provides accurate state information', () async {
      const testChatId = 'debug_chat_db';
      final streamController = StreamController<String>.broadcast();
      final buffered = <String>[];

      persistentManager.setupPersistentListener(
        testChatId,
        streamController.stream,
      );
      persistentManager.registerChatScreen(testChatId, buffered.add);
      persistentManager.unregisterChatScreen(testChatId);

      streamController.add('buffer-for-debug');
      await Future.delayed(const Duration(milliseconds: 50));

      final debugInfo = persistentManager.getDebugInfo();
      expect(debugInfo['activeListeners'], contains(testChatId));
      expect(debugInfo['activeChatIds'], isNot(contains(testChatId)));
      expect(debugInfo['bufferedMessages'][testChatId], equals(1));

      persistentManager.registerChatScreen(testChatId, buffered.add);
      await Future.delayed(const Duration(milliseconds: 50));
      final updatedInfo = persistentManager.getDebugInfo();
      expect(updatedInfo['activeHandlers'], contains(testChatId));

      streamController.close();
    });

    test('Debug info provides accurate state information - NO DB VERSION', () {
      const testChatId = 'debug_chat_no_db';
      final streamController = StreamController<String>.broadcast();

      persistentManager.setupPersistentListener(
        testChatId,
        streamController.stream,
      );
      persistentManager.registerChatScreen(testChatId, (message) {});

      final debugInfo = persistentManager.getDebugInfo();

      expect(debugInfo['activeListeners'], contains(testChatId));
      expect(debugInfo['activeChatIds'], contains(testChatId));
      expect(debugInfo['activeHandlers'], contains(testChatId));
      expect(debugInfo['bufferedMessages'][testChatId], equals(0));

      // Unregister without sending messages (avoid database operations)
      persistentManager.unregisterChatScreen(testChatId);

      final updatedDebugInfo = persistentManager.getDebugInfo();
      expect(updatedDebugInfo['activeChatIds'], isNot(contains(testChatId)));

      streamController.close();

      debugPrint('✅ Debug info accuracy verified');
    });
  });
}

// ignore_for_file: avoid_print

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/core/services/persistent_chat_state_manager.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
  });

  group('ChatScreen Lifecycle Persistence Tests', () {
    late ProviderContainer container;
    late PersistentChatStateManager persistentManager;
    late StreamController<String> mockMessageStreamController;

    setUp(() {
      container = ProviderContainer();
      persistentManager = PersistentChatStateManager();
      mockMessageStreamController = StreamController<String>.broadcast();
    });

    tearDown(() {
      container.dispose();
      persistentManager.cleanupAll();
      mockMessageStreamController.close();
    });

    testWidgets(
      'Messages survive ChatScreen dispose/recreate cycles',
      (WidgetTester tester) async {},
      skip: true,
    ); // Requires full BLE infrastructure

    testWidgets(
      'SecurityStateProvider caching prevents excessive recreations',
      (WidgetTester tester) async {},
      skip: true,
    ); // Requires full BLE infrastructure

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

        print('✅ Multi-chat persistence verified');
      },
    );

    test(
      'Debug info provides accurate state information',
      () {},
      skip: true,
    ); // Database persistence not fully mocked

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

      print('✅ Debug info accuracy verified');
    });
  });
}

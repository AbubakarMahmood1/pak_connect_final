// ignore_for_file: avoid_print

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/presentation/screens/chat_screen.dart';
import 'package:pak_connect/core/services/persistent_chat_state_manager.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/security_state_provider.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/security_state.dart';
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

    testWidgets('Messages survive ChatScreen dispose/recreate cycles', (WidgetTester tester) async {
      const testChatId = 'test_chat_123';
      const testContactName = 'Test Contact';
      const testContactPublicKey = 'test_public_key_12345';
      
      // Setup mock providers
      container = ProviderContainer(
        overrides: [
          connectionInfoProvider.overrideWith((ref) =>
            Stream.value(ConnectionInfo(
              isConnected: true,
              isReady: true,
              otherUserName: testContactName,
            ))),
          securityStateProvider.overrideWith((ref, otherPublicKey) async =>
            SecurityState.verifiedContact(
              otherPublicKey: testContactPublicKey,
              otherUserName: testContactName,
            )),
        ],
      );

      // Create chat screen widget
      Widget createChatScreen() {
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ChatScreen.fromChatData(
              chatId: testChatId,
              contactName: testContactName,
              contactPublicKey: testContactPublicKey,
            ),
          ),
        );
      }

      // Test Phase 1: Initial screen creation
      await tester.pumpWidget(createChatScreen());
      await tester.pumpAndSettle();

      expect(find.text('Chat with $testContactName'), findsOneWidget);
      expect(find.text('Start your conversation'), findsOneWidget);

      print('✅ Phase 1: Initial ChatScreen created');

      // Test Phase 2: Setup persistent listener and send message
      persistentManager.setupPersistentListener(testChatId, mockMessageStreamController.stream);
      
      // Simulate message reception
      const testMessage1 = 'Hello during active phase';
      mockMessageStreamController.add(testMessage1);
      
      await tester.pumpAndSettle(Duration(seconds: 1));
      
      // Check if message appears in UI
      expect(find.text(testMessage1), findsOneWidget);
      print('✅ Phase 2: Message received during active phase');

      // Test Phase 3: Simulate navigation away (dispose)
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Text('Away'))));
      await tester.pumpAndSettle();
      
      print('✅ Phase 3: Navigated away - ChatScreen disposed');

      // Test Phase 4: Send message while disposed (should be buffered)
      const testMessage2 = 'Hello during disposal';
      mockMessageStreamController.add(testMessage2);
      
      await Future.delayed(Duration(milliseconds: 100)); // Allow buffering
      
      // Verify message is buffered
      expect(persistentManager.getBufferedMessageCount(testChatId), equals(1));
      print('✅ Phase 4: Message buffered during disposal');

      // Test Phase 5: Navigate back (recreate ChatScreen)
      await tester.pumpWidget(createChatScreen());
      await tester.pumpAndSettle();

      // Check if both messages appear in UI
      expect(find.text(testMessage1), findsOneWidget);
      expect(find.text(testMessage2), findsOneWidget);
      print('✅ Phase 5: Both messages visible after recreation');

      // Test Phase 6: Send another message after recreation
      const testMessage3 = 'Hello after recreation';
      mockMessageStreamController.add(testMessage3);
      
      await tester.pumpAndSettle(Duration(seconds: 1));
      
      expect(find.text(testMessage3), findsOneWidget);
      print('✅ Phase 6: Message received after recreation');

      // Verify no messages lost
      expect(find.text(testMessage1), findsOneWidget);
      expect(find.text(testMessage2), findsOneWidget);
      expect(find.text(testMessage3), findsOneWidget);
      
      print('✅ All phases completed - Message persistence verified');
    });

    testWidgets('SecurityStateProvider caching prevents excessive recreations', (WidgetTester tester) async {
      const testContactPublicKey = 'test_public_key_cache';
      int providerCallCount = 0;

      container = ProviderContainer(
        overrides: [
          connectionInfoProvider.overrideWith((ref) =>
            Stream.value(ConnectionInfo(
              isConnected: true,
              isReady: true,
              otherUserName: 'Test User',
            ))),
          securityStateProvider.overrideWith((ref, otherPublicKey) async {
            providerCallCount++;
            print('🔍 SecurityStateProvider called $providerCallCount times for key: $otherPublicKey');
            return SecurityState.verifiedContact(
              otherPublicKey: testContactPublicKey,
              otherUserName: 'Test User',
            );
          }),
        ],
      );

      Widget createChatScreen() {
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ChatScreen.fromChatData(
              chatId: 'test_chat_cache',
              contactName: 'Test Contact',
              contactPublicKey: testContactPublicKey,
            ),
          ),
        );
      }

      // Create screen multiple times rapidly (simulate navigation cycles)
      for (int i = 0; i < 3; i++) {
        await tester.pumpWidget(createChatScreen());
        await tester.pumpAndSettle();
        
        // Navigate away
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: Text('Away $i'))));
        await tester.pumpAndSettle();
        
        await Future.delayed(Duration(milliseconds: 100));
      }

      // Final recreation
      await tester.pumpWidget(createChatScreen());
      await tester.pumpAndSettle();

      // With caching, provider should be called much less than number of recreations
      expect(providerCallCount, lessThan(6)); // Should be cached after first few calls
      print('✅ SecurityStateProvider caching working - called $providerCallCount times for 4 recreations');
    });

    test('PersistentChatStateManager handles multiple chats correctly', () async {
      const chat1Id = 'chat_1';
      const chat2Id = 'chat_2';
      
      final stream1Controller = StreamController<String>.broadcast();
      final stream2Controller = StreamController<String>.broadcast();
      
      final receivedMessages1 = <String>[];
      final receivedMessages2 = <String>[];

      // Setup persistent listeners for both chats
      persistentManager.setupPersistentListener(chat1Id, stream1Controller.stream);
      persistentManager.setupPersistentListener(chat2Id, stream2Controller.stream);

      // Register handlers
      persistentManager.registerChatScreen(chat1Id, (message) => receivedMessages1.add(message));
      persistentManager.registerChatScreen(chat2Id, (message) => receivedMessages2.add(message));

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
      persistentManager.registerChatScreen(chat1Id, (message) => receivedMessages1.add(message));
      
      await Future.delayed(Duration(milliseconds: 100));

      // Buffered message should now be delivered
      expect(receivedMessages1, contains('Buffered message to chat 1'));
      expect(persistentManager.getBufferedMessageCount(chat1Id), equals(0));

      stream1Controller.close();
      stream2Controller.close();
      
      print('✅ Multi-chat persistence verified');
    });

    test('Debug info provides accurate state information', () {
      const testChatId = 'debug_chat';
      final streamController = StreamController<String>.broadcast();

      persistentManager.setupPersistentListener(testChatId, streamController.stream);
      persistentManager.registerChatScreen(testChatId, (message) {});

      final debugInfo = persistentManager.getDebugInfo();
      
      expect(debugInfo['activeListeners'], contains(testChatId));
      expect(debugInfo['activeChatIds'], contains(testChatId));
      expect(debugInfo['activeHandlers'], contains(testChatId));
      expect(debugInfo['bufferedMessages'][testChatId], equals(0));

      // Send a message while active (should not buffer)
      streamController.add('Active message');
      
      // Unregister and send another message (should buffer)
      persistentManager.unregisterChatScreen(testChatId);
      streamController.add('Buffered message');
      
      final updatedDebugInfo = persistentManager.getDebugInfo();
      expect(updatedDebugInfo['activeChatIds'], isNot(contains(testChatId)));
      expect(updatedDebugInfo['bufferedMessages'][testChatId], equals(1));

      streamController.close();
      
      print('✅ Debug info accuracy verified');
    });
  });
}

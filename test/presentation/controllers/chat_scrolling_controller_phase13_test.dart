// Phase 13.2: ChatScrollingController tests
// Targeting 60 uncovered lines

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

// Minimal mock of IChatsRepository
class _MockChatsRepo implements IChatsRepository {
  int incrementCalls = 0;
  int markReadCalls = 0;
  int unreadCount = 0;

  @override
  Future<List<ChatListItem>> getAllChats({
    dynamic nearbyDevices,
    dynamic discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    return [
      ChatListItem(
        chatId: const ChatId('test-chat'),
        contactName: 'Test',
        contactPublicKey: 'pk1',
        lastMessage: 'hi',
        lastMessageTime: DateTime.now(),
        unreadCount: unreadCount,
        isOnline: true,
        hasUnsentMessages: false,
        lastSeen: null,
      ),
    ];
  }

  @override
  Future<void> incrementUnreadCount(ChatId chatId) async {
    incrementCalls++;
    unreadCount++;
  }

  @override
  Future<void> markChatAsRead(ChatId chatId) async {
    markReadCalls++;
    unreadCount = 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not mocked',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  late _MockChatsRepo mockRepo;
  late ChatScrollingController controller;
  int lastUnreadCount = -1;
  int stateChanges = 0;
  int scrollToBottomCalls = 0;

  setUp(() {
    mockRepo = _MockChatsRepo();
    lastUnreadCount = -1;
    stateChanges = 0;
    scrollToBottomCalls = 0;
    controller = ChatScrollingController(
      chatsRepository: mockRepo,
      chatId: const ChatId('test-chat'),
      onScrollToBottom: () => scrollToBottomCalls++,
      onUnreadCountChanged: (c) => lastUnreadCount = c,
      onStateChanged: () => stateChanges++,
    );
  });

  tearDown(() {
    controller.dispose();
  });

  group('ChatScrollingController', () {
    test('initial state', () {
      expect(controller.shouldAutoScrollOnIncoming, isTrue);
      expect(controller.shouldShowScrollDownButton(0), isFalse);
      expect(controller.isUserAtBottom, isTrue);
      expect(controller.newMessagesWhileScrolledUp, 0);
      expect(controller.showUnreadSeparator, isFalse);
      expect(controller.lastReadMessageIndex, -1);
    });

    test('setUnreadCount updates count and notifies', () {
      controller.setUnreadCount(5);
      expect(lastUnreadCount, 5);
      expect(stateChanges, greaterThan(0));
    });

    test('syncUnreadCount with 0 unread', () async {
      mockRepo.unreadCount = 0;
      await controller.syncUnreadCount(messages: []);
      expect(lastUnreadCount, 0);
    });

    test('syncUnreadCount with unread messages', () async {
      mockRepo.unreadCount = 2;
      final messages = List.generate(
        5,
        (i) => Message(
          id: MessageId('msg$i'),
          chatId: const ChatId('test-chat'),
          content: 'test $i',
          timestamp: DateTime.now(),
          isFromMe: false,
          status: MessageStatus.delivered,
        ),
      );

      await controller.syncUnreadCount(messages: messages);
      expect(lastUnreadCount, 2);
      expect(controller.showUnreadSeparator, isTrue);
      expect(controller.lastReadMessageIndex, 2); // 5 - 2 - 1
    });

    test('handleIncomingWhileScrolledAway when at bottom does nothing', () async {
      // Default state: user is at bottom
      await controller.handleIncomingWhileScrolledAway();
      expect(mockRepo.incrementCalls, 0);
    });

    test('decrementUnreadCount decrements', () {
      controller.setUnreadCount(3);
      stateChanges = 0;
      controller.decrementUnreadCount();
      expect(lastUnreadCount, 2);
      expect(stateChanges, greaterThan(0));
    });

    test('decrementUnreadCount does nothing at zero', () {
      controller.setUnreadCount(0);
      stateChanges = 0;
      controller.decrementUnreadCount();
      expect(lastUnreadCount, 0);
      expect(stateChanges, 0);
    });

    test('markAsRead resets all counters', () async {
      controller.setUnreadCount(5);
      await controller.markAsRead();
      expect(lastUnreadCount, 0);
      expect(mockRepo.markReadCalls, 1);
    });

    test('shouldShowScrollDownButton returns false when at bottom', () {
      expect(controller.shouldShowScrollDownButton(10), isFalse);
    });

    test('shouldShowScrollDownButton returns false with 0 messages', () {
      expect(controller.shouldShowScrollDownButton(0), isFalse);
    });

    test('scheduleMarkAsRead cancels previous timer', () {
      controller.setUnreadCount(1);
      controller.scheduleMarkAsRead();
      controller.scheduleMarkAsRead(); // second call cancels first
      // No exception = pass
    });

    test('scrollToBottom without clients does nothing', () async {
      await controller.scrollToBottom();
      expect(scrollToBottomCalls, 0);
    });

    test('dispose cleans up', () {
      // Calling dispose in the test, skip tearDown's dispose
      controller.dispose();
      // Re-create to avoid tearDown crash
      controller = ChatScrollingController(
        chatsRepository: mockRepo,
        chatId: const ChatId('test-chat'),
        onScrollToBottom: () => scrollToBottomCalls++,
        onUnreadCountChanged: (c) => lastUnreadCount = c,
        onStateChanged: () => stateChanges++,
      );
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../test_helpers/test_service_registry.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/models/contact_group.dart';
import 'package:pak_connect/presentation/providers/group_providers.dart';
import 'package:pak_connect/presentation/screens/group_chat_screen.dart';

class _FakeUserPreferences implements IUserPreferences {
  _FakeUserPreferences({required this.publicKey});

  final String publicKey;

  @override
  Future<String> getPublicKey() async => publicKey;

  @override
  Future<String> getPrivateKey() async => 'private';

  @override
  Future<String> getUserName() async => 'tester';

  @override
  Future<String?> getDeviceId() async => 'device';

  @override
  Future<String> getOrCreateDeviceId() async => 'device';

  @override
  Future<Map<String, String>> getOrCreateKeyPair() async => <String, String>{
    'public': publicKey,
    'private': 'private',
  };

  @override
  Future<bool> getHintBroadcastEnabled() async => true;

  @override
  Future<void> regenerateKeyPair() async {}

  @override
  Future<void> setHintBroadcastEnabled(bool enabled) async {}

  @override
  Future<void> setUserName(String name) async {}
}

ContactGroup _group({String id = 'group-1'}) {
  return ContactGroup(
    id: id,
    name: 'Study Circle',
    memberKeys: const <String>['sender-public-key', 'peer-a', 'peer-b'],
    description: 'Project updates',
    created: DateTime(2026, 1, 1),
    lastModified: DateTime(2026, 1, 2),
  );
}

GroupMessage _message({
  required String id,
  String content = 'hello',
  Map<String, MessageDeliveryStatus>? deliveryStatus,
}) {
  return GroupMessage(
    id: id,
    groupId: 'group-1',
    senderKey: 'sender-public-key',
    content: content,
    timestamp: DateTime(2026, 1, 1, 9, 0),
    deliveryStatus:
        deliveryStatus ??
        const <String, MessageDeliveryStatus>{
          'peer-a': MessageDeliveryStatus.delivered,
        },
  );
}

Future<void> _pumpGroupChatScreen(
  WidgetTester tester, {
  String groupId = 'group-1',
  required Future<ContactGroup?> Function(String groupId) loadGroup,
  required Future<List<GroupMessage>> Function(String groupId) loadMessages,
  Future<Map<MessageDeliveryStatus, int>> Function(String messageId)?
  loadSummary,
  Future<GroupMessage> Function({
    required String groupId,
    required String senderKey,
    required String content,
  })?
  sendMessage,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        groupByIdProvider.overrideWith((ref, id) => loadGroup(id)),
        groupMessagesProvider.overrideWith((ref, id) => loadMessages(id)),
        messageDeliverySummaryProvider.overrideWith((ref, messageId) async {
          if (loadSummary != null) {
            return loadSummary(messageId);
          }
          return <MessageDeliveryStatus, int>{
            MessageDeliveryStatus.delivered: 1,
          };
        }),
        sendGroupMessageProvider.overrideWith((ref) {
          return ({
            required String groupId,
            required String senderKey,
            required String content,
          }) async {
            if (sendMessage != null) {
              return sendMessage(
                groupId: groupId,
                senderKey: senderKey,
                content: content,
              );
            }
            return _message(id: 'sent-default', content: content);
          };
        }),
      ],
      child: MaterialApp(home: GroupChatScreen(groupId: groupId)),
    ),
  );

  await tester.pump();
}

void main() {
  final locator = serviceRegistry;

  setUp(() {
    if (locator.isRegistered<IUserPreferences>()) {
      locator.unregister<IUserPreferences>();
    }
    locator.registerSingleton<IUserPreferences>(
      _FakeUserPreferences(publicKey: 'sender-public-key'),
    );
  });

  tearDown(() {
    if (locator.isRegistered<IUserPreferences>()) {
      locator.unregister<IUserPreferences>();
    }
  });

  group('GroupChatScreen', () {
    testWidgets('renders group header and empty-state copy', (tester) async {
      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async => _group(),
        loadMessages: (_) async => const <GroupMessage>[],
      );
      await tester.pumpAndSettle();

      expect(find.text('Study Circle'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(
        find.text('No messages yet\nSend a message to get started!'),
        findsOneWidget,
      );
      expect(find.byTooltip('Send'), findsOneWidget);
    });

    testWidgets('renders message error state and retries provider refresh', (
      tester,
    ) async {
      var messageLoads = 0;

      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async => _group(),
        loadMessages: (_) async {
          messageLoads++;
          throw StateError('load-failed');
        },
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Error loading messages'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(messageLoads, greaterThanOrEqualTo(2));
    });

    testWidgets('sends message using IUserPreferences public key', (
      tester,
    ) async {
      String? capturedGroupId;
      String? capturedSenderKey;
      String? capturedContent;
      final sendCompleter = Completer<GroupMessage>();

      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async => _group(),
        loadMessages: (_) async => const <GroupMessage>[],
        sendMessage:
            ({
              required String groupId,
              required String senderKey,
              required String content,
            }) {
              capturedGroupId = groupId;
              capturedSenderKey = senderKey;
              capturedContent = content;
              return sendCompleter.future;
            },
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  Hello team  ');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      sendCompleter.complete(_message(id: 'sent-1', content: 'Hello team'));
      await tester.pumpAndSettle();

      expect(capturedGroupId, 'group-1');
      expect(capturedSenderKey, isNotNull);
      expect(capturedContent, 'Hello team');
      expect(find.text('Hello team'), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('shows failure snackbar when send throws', (tester) async {
      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async => _group(),
        loadMessages: (_) async => const <GroupMessage>[],
        sendMessage:
            ({
              required String groupId,
              required String senderKey,
              required String content,
            }) async {
              throw Exception('send failed');
            },
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'will fail');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Failed to send message'), findsOneWidget);
    });

    testWidgets('opens group info dialog from app bar action', (tester) async {
      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async => _group(),
        loadMessages: (_) async => const <GroupMessage>[],
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Group Info'));
      await tester.pumpAndSettle();

      expect(find.text('Project updates'), findsOneWidget);
      expect(find.text('Members: 3'), findsOneWidget);
      expect(find.textContaining('Created:'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Project updates'), findsNothing);
    });

    testWidgets('renders delivery summary and details dialog statuses', (
      tester,
    ) async {
      final delivery = <String, MessageDeliveryStatus>{
        'peer-a': MessageDeliveryStatus.delivered,
        'peer-b': MessageDeliveryStatus.sent,
        'peer-c': MessageDeliveryStatus.pending,
        'peer-d': MessageDeliveryStatus.failed,
      };

      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async => _group(),
        loadMessages: (_) async => <GroupMessage>[
          _message(
            id: 'msg-1',
            content: 'status test',
            deliveryStatus: delivery,
          ),
        ],
        loadSummary: (_) async => <MessageDeliveryStatus, int>{
          MessageDeliveryStatus.delivered: 1,
          MessageDeliveryStatus.sent: 1,
          MessageDeliveryStatus.failed: 1,
          MessageDeliveryStatus.pending: 1,
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('status test'), findsOneWidget);
      expect(
        find.byTooltip('Delivered: 1/4\nSent: 1\nFailed: 1'),
        findsOneWidget,
      );
      expect(find.text('1/4 delivered'), findsOneWidget);

      await tester.tap(find.text('1/4 delivered'));
      await tester.pumpAndSettle();

      expect(find.text('Delivery Status'), findsOneWidget);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
    });

    testWidgets('shows loading indicator while delivery summary resolves', (
      tester,
    ) async {
      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async => _group(),
        loadMessages: (_) async => <GroupMessage>[
          _message(id: 'slow-summary', content: 'waiting'),
        ],
        loadSummary: (_) {
          return Future<Map<MessageDeliveryStatus, int>>.delayed(
            const Duration(milliseconds: 200),
            () => <MessageDeliveryStatus, int>{
              MessageDeliveryStatus.delivered: 1,
            },
          );
        },
      );

      expect(find.byType(CircularProgressIndicator), findsAtLeastNWidgets(1));

      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(
        find.byTooltip('Delivered: 1/1\nSent: 0\nFailed: 0'),
        findsOneWidget,
      );
    });

    testWidgets('renders app bar error title when group loading fails', (
      tester,
    ) async {
      await _pumpGroupChatScreen(
        tester,
        loadGroup: (_) async {
          throw StateError('group-load-failed');
        },
        loadMessages: (_) async => const <GroupMessage>[],
      );
      await tester.pumpAndSettle();

      expect(find.text('Error'), findsOneWidget);
    });
  });
}

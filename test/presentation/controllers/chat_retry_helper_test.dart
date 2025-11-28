import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/presentation/controllers/chat_retry_helper.dart';
import 'package:pak_connect/presentation/models/chat_screen_config.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';

class _FakeMessageRepository extends MessageRepository {
  final List<Message> updatedMessages = [];

  @override
  Future<void> updateMessage(Message message) async {
    updatedMessages.add(message);
  }
}

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('ChatRetryHelper Tests', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
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

    testWidgets('fallback retry updates message state before resend', (
      tester,
    ) async {
      final repo = _FakeMessageRepository();
      final messages = <Message>[
        Message(
          id: 'm1',
          chatId: 'chat-1',
          content: 'hello',
          timestamp: DateTime.now(),
          isFromMe: true,
          status: MessageStatus.failed,
        ),
      ];

      late ChatRetryHelper helper;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                helper = ChatRetryHelper(
                  ref: ref,
                  config: const ChatScreenConfig(chatId: 'chat-1'),
                  chatId: () => 'chat-1',
                  contactPublicKey: () => 'pk-123',
                  displayContactName: () => 'Alice',
                  messageRepository: repo,
                  repositoryRetryHandler: (message) async {
                    await repo.updateMessage(
                      message.copyWith(status: MessageStatus.delivered),
                    );
                  },
                  showSuccess: (_) {},
                  showError: (_) {},
                  showInfo: (_) {},
                  scrollToBottom: () {},
                  getMessages: () => messages,
                  logger: Logger('test'),
                  initialCoordinator: null,
                  fallbackRetryDelay: Duration.zero,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      // Allow widget tree to settle.
      await tester.pump();

      await helper.fallbackRetryFailedMessages();

      expect(repo.updatedMessages.length, 2);
      expect(repo.updatedMessages.first.status, MessageStatus.sending);
      expect(repo.updatedMessages.last.status, MessageStatus.delivered);
    });
  });
}

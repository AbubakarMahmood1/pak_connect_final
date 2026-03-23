import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/pinning_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/chat_notification_providers.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart'
    show clearRuntimeAppServicesForTesting;
import 'package:pak_connect/presentation/providers/pinning_service_provider.dart'
    as pinning;

class _FakeChatManagementService extends Fake implements ChatManagementService {
  _FakeChatManagementService({this.throwOnInitialize = false});

  final bool throwOnInitialize;
  int initializeCalls = 0;
  final StreamController<ChatUpdateEvent> chatUpdatesController =
      StreamController<ChatUpdateEvent>.broadcast();
  final StreamController<MessageUpdateEvent> messageUpdatesController =
      StreamController<MessageUpdateEvent>.broadcast();

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (throwOnInitialize) {
      throw StateError('init failure');
    }
  }

  @override
  Stream<ChatUpdateEvent> get chatUpdates => chatUpdatesController.stream;

  @override
  Stream<MessageUpdateEvent> get messageUpdates =>
      messageUpdatesController.stream;

  Future<void> close() async {
    await chatUpdatesController.close();
    await messageUpdatesController.close();
  }
}

class _FakePinningService extends Fake implements PinningService {
  final StreamController<MessageUpdateEvent> messageUpdatesController =
      StreamController<MessageUpdateEvent>.broadcast();

  @override
  Stream<MessageUpdateEvent> get messageUpdates =>
      messageUpdatesController.stream;

  Future<void> close() async {
    await messageUpdatesController.close();
  }
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    clearRuntimeAppServicesForTesting();
  });

  tearDown(() async {
    await getIt.reset();
    clearRuntimeAppServicesForTesting();
  });

  group('chatNotificationProviders', () {
    test(
      'chatManagementServiceProvider resolves from locator and initializes',
      () async {
        final service = _FakeChatManagementService();
        addTearDown(service.close);
        getIt.registerSingleton<ChatManagementService>(service);

        final container = ProviderContainer();
        addTearDown(container.dispose);

        final resolved = container.read(chatManagementServiceProvider);
        expect(resolved, same(service));

        await Future<void>.delayed(Duration.zero);
        expect(service.initializeCalls, 1);
      },
    );

    test(
      'chatManagementServiceProvider swallows initialization errors',
      () async {
        final service = _FakeChatManagementService(throwOnInitialize: true);
        addTearDown(service.close);
        getIt.registerSingleton<ChatManagementService>(service);

        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(
          () => container.read(chatManagementServiceProvider),
          returnsNormally,
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));
        expect(service.initializeCalls, 1);
      },
    );

    test('chatUpdatesStreamProvider relays chat updates stream', () async {
      final service = _FakeChatManagementService();
      addTearDown(service.close);

      final container = ProviderContainer(
        overrides: [
          chatManagementServiceProvider.overrideWith((ref) => service),
        ],
      );
      addTearDown(container.dispose);

      final completer = Completer<ChatUpdateEvent>();
      final subscription = container.listen(chatUpdatesStreamProvider, (
        previous,
        next,
      ) {
        next.whenData((event) {
          if (!completer.isCompleted) {
            completer.complete(event);
          }
        });
      }, fireImmediately: true);
      addTearDown(subscription.close);

      final event = ChatUpdateEvent.archived(const ChatId('chat-1'));
      service.chatUpdatesController.add(event);

      expect(await completer.future, same(event));
    });

    test(
      'messageUpdatesStreamProvider relays message updates stream',
      () async {
        final service = _FakeChatManagementService();
        addTearDown(service.close);

        final container = ProviderContainer(
          overrides: [
            chatManagementServiceProvider.overrideWith((ref) => service),
          ],
        );
        addTearDown(container.dispose);

        final completer = Completer<MessageUpdateEvent>();
        final subscription = container.listen(messageUpdatesStreamProvider, (
          previous,
          next,
        ) {
          next.whenData((event) {
            if (!completer.isCompleted) {
              completer.complete(event);
            }
          });
        }, fireImmediately: true);
        addTearDown(subscription.close);

        final event = MessageUpdateEvent.starred(const MessageId('msg-1'));
        service.messageUpdatesController.add(event);

        expect(await completer.future, same(event));
      },
    );

    test(
      'networkTopologyAnalyzerUpdatesProvider can be subscribed and disposed',
      () {
        final container = ProviderContainer();
        container.read(networkTopologyAnalyzerUpdatesProvider);
        container.dispose();
      },
    );

    test('pinningServiceUpdatesProvider relays pinning stream', () async {
      final service = _FakePinningService();
      addTearDown(service.close);

      final container = ProviderContainer(
        overrides: [
          pinning.pinningServiceProvider.overrideWith((ref) => service),
        ],
      );
      addTearDown(container.dispose);

      final completer = Completer<MessageUpdateEvent>();
      final subscription = container.listen(pinningServiceUpdatesProvider, (
        previous,
        next,
      ) {
        next.whenData((event) {
          if (!completer.isCompleted) {
            completer.complete(event);
          }
        });
      }, fireImmediately: true);
      addTearDown(subscription.close);

      final event = MessageUpdateEvent.unstarred(const MessageId('msg-2'));
      service.messageUpdatesController.add(event);

      expect(await completer.future, same(event));
    });
  });
}

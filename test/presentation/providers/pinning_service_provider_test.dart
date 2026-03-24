import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../test_helpers/test_service_registry.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart'
    show clearRuntimeAppServicesForTesting;
import 'package:pak_connect/presentation/providers/pinning_service_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class _MockChatsRepository extends Mock implements IChatsRepository {}

class _MockMessageRepository extends Mock implements IMessageRepository {}

void main() {
  final locator = serviceRegistry;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await locator.reset();
    clearRuntimeAppServicesForTesting();
  });

  tearDown(() async {
    await locator.reset();
    clearRuntimeAppServicesForTesting();
  });

  group('pinningServiceProvider', () {
    test('builds service from locator and supports star toggle', () async {
      locator.registerSingleton<IChatsRepository>(_MockChatsRepository());
      locator.registerSingleton<IMessageRepository>(_MockMessageRepository());

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(pinningServiceProvider);
      await Future<void>.delayed(Duration.zero);

      final result = await service.toggleMessageStar(const MessageId('m1'));
      expect(result.success, isTrue);
      expect(service.isMessageStarred(const MessageId('m1')), isTrue);
    });

    test(
      'messageUpdatesProvider forwards updates from service stream',
      () async {
        locator.registerSingleton<IChatsRepository>(_MockChatsRepository());
        locator.registerSingleton<IMessageRepository>(_MockMessageRepository());

        final container = ProviderContainer();
        addTearDown(container.dispose);

        final service = container.read(pinningServiceProvider);
        final completer = Completer<dynamic>();
        final subscription = container.listen(messageUpdatesProvider, (
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

        await service.toggleMessageStar(const MessageId('m2'));

        final event = await completer.future;
        expect(event.messageId, const MessageId('m2'));
      },
    );

    test('disposes provider without throwing', () {
      locator.registerSingleton<IChatsRepository>(_MockChatsRepository());
      locator.registerSingleton<IMessageRepository>(_MockMessageRepository());

      final container = ProviderContainer();
      container.read(pinningServiceProvider);

      expect(container.dispose, returnsNormally);
    });
  });
}

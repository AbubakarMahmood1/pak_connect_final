import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/interfaces/i_chat_interaction_handler.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade_factory.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/chat_list_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/home_screen_providers.dart';
import 'package:pak_connect/presentation/services/chat_interaction_handler.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

class _FakeChatsRepository extends Fake implements IChatsRepository {}

class _FakeChatManagementService extends Fake
    implements ChatManagementService {}

class _FakeInteractionHandler extends ChatInteractionHandler {
  _FakeInteractionHandler();

  final StreamController<ChatInteractionIntent> _intentController =
      StreamController<ChatInteractionIntent>.broadcast();
  int disposeCalls = 0;

  @override
  Stream<ChatInteractionIntent> get interactionIntentStream =>
      _intentController.stream;

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  void emit(ChatInteractionIntent intent) {
    _intentController.add(intent);
  }

  Future<void> close() async {
    await _intentController.close();
  }
}

class _FakeHomeScreenFacade extends Fake implements IHomeScreenFacade {
  int loadChatsCalls = 0;
  int disposeCalls = 0;
  final StreamController<int> _unreadController =
      StreamController<int>.broadcast();
  final StreamController<ConnectionStatus> _connectionController =
      StreamController<ConnectionStatus>.broadcast();

  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) async {
    loadChatsCalls++;
    return <ChatListItem>[];
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  List<ChatListItem> get chats => const <ChatListItem>[];

  @override
  bool get isLoading => false;

  @override
  Stream<int> get unreadCountStream => _unreadController.stream;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionController.stream;

  Future<void> close() async {
    await _unreadController.close();
    await _connectionController.close();
  }
}

class _FakeHomeScreenFacadeFactory implements IHomeScreenFacadeFactory {
  _FakeHomeScreenFacadeFactory(this.facade);

  final IHomeScreenFacade facade;
  int createCalls = 0;
  bool? lastEnableInternalIntentListener;

  @override
  IHomeScreenFacade create({
    IChatsRepository? chatsRepository,
    dynamic bleService,
    ChatManagementService? chatManagementService,
    BuildContext? context,
    WidgetRef? ref,
    HomeScreenInteractionHandlerBuilder? interactionHandlerBuilder,
    bool enableListCoordinatorInitialization = true,
    bool enableInternalIntentListener = true,
  }) {
    createCalls++;
    lastEnableInternalIntentListener = enableInternalIntentListener;
    return facade;
  }
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  group('homeScreenProviders', () {
    test('chatListControllerProvider returns ChatListController', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final controller = container.read(chatListControllerProvider);
      expect(controller, isA<ChatListController>());
    });

    testWidgets('chatInteractionHandlerProvider builds default handler', (
      tester,
    ) async {
      final chatsRepository = _FakeChatsRepository();
      final chatManagementService = _FakeChatManagementService();
      late ProviderContainer container;
      late ChatInteractionHandlerArgs args;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                args = ChatInteractionHandlerArgs(
                  context: context,
                  ref: ref,
                  chatsRepository: chatsRepository,
                  chatManagementService: chatManagementService,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final handler = container.read(chatInteractionHandlerProvider(args));
      expect(
        handler.runtimeType.toString(),
        contains('ChatInteractionHandler'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('chatInteractionIntentProvider relays handler intents', (
      tester,
    ) async {
      final chatsRepository = _FakeChatsRepository();
      final chatManagementService = _FakeChatManagementService();
      final fakeHandler = _FakeInteractionHandler();
      addTearDown(fakeHandler.close);
      late ProviderContainer container;
      late ChatInteractionHandlerArgs args;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatInteractionHandlerProvider.overrideWith((ref, args) {
              return fakeHandler;
            }),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                args = ChatInteractionHandlerArgs(
                  context: context,
                  ref: ref,
                  chatsRepository: chatsRepository,
                  chatManagementService: chatManagementService,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final completer = Completer<ChatInteractionIntent>();
      final subscription = container.listen(
        chatInteractionIntentProvider(args),
        (previous, next) {
          next.whenData((intent) {
            if (!completer.isCompleted) {
              completer.complete(intent);
            }
          });
        },
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final intent = ChatOpenedIntent('chat-1');
      fakeHandler.emit(intent);

      expect(await completer.future, isA<ChatOpenedIntent>());
    });

    testWidgets('homeScreenFacadeProvider returns injected facade instance', (
      tester,
    ) async {
      final chatsRepository = _FakeChatsRepository();
      final chatManagementService = _FakeChatManagementService();
      final injectedFacade = _FakeHomeScreenFacade();
      addTearDown(injectedFacade.close);
      late ProviderContainer container;
      late HomeScreenProviderArgs args;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                args = HomeScreenProviderArgs(
                  context: context,
                  ref: ref,
                  chatsRepository: chatsRepository,
                  chatManagementService: chatManagementService,
                  homeScreenFacade: injectedFacade,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final resolved = container.read(homeScreenFacadeProvider(args));
      expect(resolved, same(injectedFacade));
    });

    testWidgets(
      'homeScreenFacadeProvider factory path creates and disposes facade',
      (tester) async {
        final chatsRepository = _FakeChatsRepository();
        final chatManagementService = _FakeChatManagementService();
        final fakeFacade = _FakeHomeScreenFacade();
        final factory = _FakeHomeScreenFacadeFactory(fakeFacade);
        final connectionService = MockConnectionService();
        addTearDown(connectionService.dispose);
        addTearDown(fakeFacade.close);
        getIt.registerSingleton<IHomeScreenFacadeFactory>(factory);

        late ProviderContainer container;
        late HomeScreenProviderArgs args;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              connectionServiceProvider.overrideWith(
                (ref) => connectionService,
              ),
            ],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context);
                  args = HomeScreenProviderArgs(
                    context: context,
                    ref: ref,
                    chatsRepository: chatsRepository,
                    chatManagementService: chatManagementService,
                  );
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );

        final resolvedFacade = container.read(homeScreenFacadeProvider(args));
        expect(resolvedFacade, same(fakeFacade));
        expect(factory.createCalls, 1);
        expect(factory.lastEnableInternalIntentListener, isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(fakeFacade.disposeCalls, 1);
      },
    );
  });
}

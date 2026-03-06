import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/navigation_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

Widget _appWithNavigator({required Widget home}) {
  return MaterialApp(navigatorKey: NavigationService.navigatorKey, home: home);
}

void main() {
  testWidgets('gracefully no-ops when navigator/context are unavailable', (
    tester,
  ) async {
    final service = NavigationService();

    expect(service.context, isNull);
    expect(service.navigator, isNull);

    await service.navigateToChatById(chatId: 'chat-1', contactName: 'Ali');
    await service.navigateToContactRequest(
      publicKey: 'pk-1',
      contactName: 'Ali',
    );
    await service.navigateToHome();
    service.showMessage('hello');
  });

  testWidgets('no-ops when builders are not registered', (tester) async {
    await tester.pumpWidget(
      _appWithNavigator(home: const Scaffold(body: Text('root-no-builders'))),
    );

    final service = NavigationService();
    await service.navigateToChatById(chatId: 'chat-2', contactName: 'Sara');
    await service.navigateToContactRequest(
      publicKey: 'pk-2',
      contactName: 'Sara',
    );

    expect(find.text('root-no-builders'), findsOneWidget);
  });

  group('registered builders', () {
    setUp(() {
      NavigationService.setChatScreenBuilder(({
        required ChatId chatId,
        required String contactName,
        required String contactPublicKey,
      }) {
        return Scaffold(
          body: Text(
            'chat:${chatId.value}|name:$contactName|key:$contactPublicKey',
          ),
        );
      });
      NavigationService.setContactsScreenBuilder(
        () => const Scaffold(body: Text('contacts-screen')),
      );
    });

    testWidgets('navigateToChatById pushes route and defaults missing key', (
      tester,
    ) async {
      await tester.pumpWidget(
        _appWithNavigator(home: const Scaffold(body: Text('home-root'))),
      );

      final service = NavigationService();
      final navFuture = service.navigateToChatById(
        chatId: 'chat-42',
        contactName: 'Zain',
      );

      await tester.pumpAndSettle();
      expect(find.text('chat:chat-42|name:Zain|key:'), findsOneWidget);

      NavigationService.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await navFuture;
    });

    testWidgets('navigateToContactRequest pushes contacts route', (
      tester,
    ) async {
      await tester.pumpWidget(
        _appWithNavigator(
          home: const Scaffold(body: Text('root-for-contacts')),
        ),
      );

      final service = NavigationService();
      final navFuture = service.navigateToContactRequest(
        publicKey: 'pk-contact',
        contactName: 'Maya',
      );

      await tester.pumpAndSettle();
      expect(find.text('contacts-screen'), findsOneWidget);

      NavigationService.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await navFuture;
    });

    testWidgets('navigateToHome pops stacked routes back to first route', (
      tester,
    ) async {
      await tester.pumpWidget(
        _appWithNavigator(home: const Scaffold(body: Text('home-stack-root'))),
      );

      final nav = NavigationService.navigatorKey.currentState!;
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('stack-level-1')),
        ),
      );
      await tester.pumpAndSettle();

      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('stack-level-2')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('stack-level-2'), findsOneWidget);

      await NavigationService().navigateToHome();
      await tester.pumpAndSettle();

      expect(find.text('home-stack-root'), findsOneWidget);
      expect(find.text('stack-level-1'), findsNothing);
      expect(find.text('stack-level-2'), findsNothing);
    });

    testWidgets('showMessage displays snackbar when context is available', (
      tester,
    ) async {
      await tester.pumpWidget(
        _appWithNavigator(home: const Scaffold(body: Text('snackbar-home'))),
      );

      NavigationService().showMessage('snackbar-text');
      await tester.pump();

      expect(find.text('snackbar-text'), findsOneWidget);
    });

    testWidgets(
      'notification handler adapter delegates to navigation service',
      (tester) async {
        await tester.pumpWidget(
          _appWithNavigator(home: const Scaffold(body: Text('adapter-root'))),
        );

        final handler = NavigationServiceNotificationHandler();

        final chatFuture = handler.navigateToChat(
          chatId: 'chat-99',
          contactName: 'Noor',
          contactPublicKey: 'pk-99',
        );
        await tester.pumpAndSettle();
        expect(find.text('chat:chat-99|name:Noor|key:pk-99'), findsOneWidget);
        NavigationService.navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await chatFuture;

        final contactsFuture = handler.navigateToContactRequest(
          publicKey: 'pk-adapter',
          contactName: 'Noor',
        );
        await tester.pumpAndSettle();
        expect(find.text('contacts-screen'), findsOneWidget);
        NavigationService.navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await contactsFuture;

        await handler.navigateToHome();
        await tester.pumpAndSettle();
        expect(find.text('adapter-root'), findsOneWidget);
      },
    );
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/contact_group.dart';
import 'package:pak_connect/presentation/providers/group_providers.dart';
import 'package:pak_connect/presentation/screens/group_list_screen.dart';

void main() {
  group('GroupListScreen', () {
    testWidgets('shows loading and empty states', (tester) async {
      final completer = Completer<List<ContactGroup>>();

      await _pumpGroupScreen(
        tester,
        groupsLoader: () => completer.future,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete(<ContactGroup>[]);
      await tester.pumpAndSettle();

      expect(find.text('No groups yet'), findsOneWidget);
      expect(find.text('Create a group to get started'), findsOneWidget);
    });

    testWidgets('shows error state with retry action', (tester) async {
      await _pumpGroupScreen(
        tester,
        groupsLoader: () async => throw StateError('boom'),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Error loading groups:'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Retry'), findsOneWidget);
    });

    testWidgets('renders groups and navigates to create/chat/edit routes', (
      tester,
    ) async {
      final observer = _TestNavigatorObserver();
      final groups = <ContactGroup>[
        ContactGroup(
          id: 'grp-1',
          name: 'Family',
          memberKeys: const <String>['a', 'b', 'c'],
          description: 'Private family group',
          created: DateTime(2026, 1, 1),
          lastModified: DateTime(2026, 1, 2),
        ),
      ];

      await _pumpGroupScreen(
        tester,
        groupsLoader: () async => groups,
        observer: observer,
      );
      await tester.pumpAndSettle();

      expect(find.text('Family'), findsOneWidget);
      expect(find.text('Private family group'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(observer.pushedRouteNames, contains('/edit-group'));

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();
      expect(observer.pushedRouteNames, contains('/group-chat'));
      expect(observer.pushedArguments, contains('grp-1'));

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(observer.pushedRouteNames, contains('/create-group'));
    });

    testWidgets('deletes group successfully and shows snackbar', (tester) async {
      final deleted = <String>[];
      final groups = <ContactGroup>[
        ContactGroup(
          id: 'grp-2',
          name: 'Friends',
          memberKeys: const <String>['a', 'b'],
          description: null,
          created: DateTime(2026, 1, 1),
          lastModified: DateTime(2026, 1, 2),
        ),
      ];

      await _pumpGroupScreen(
        tester,
        groupsLoader: () async => groups,
        deleteGroup: (groupId) async => deleted.add(groupId),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(deleted, <String>['grp-2']);
      expect(find.text('Group deleted'), findsOneWidget);
    });

    testWidgets('shows failure snackbar when delete throws', (tester) async {
      final groups = <ContactGroup>[
        ContactGroup(
          id: 'grp-3',
          name: 'Work',
          memberKeys: const <String>['x'],
          description: null,
          created: DateTime(2026, 1, 1),
          lastModified: DateTime(2026, 1, 2),
        ),
      ];

      await _pumpGroupScreen(
        tester,
        groupsLoader: () async => groups,
        deleteGroup: (_) async => throw StateError('delete failed'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Failed to delete group:'), findsOneWidget);
    });
  });
}

Future<void> _pumpGroupScreen(
  WidgetTester tester, {
  required Future<List<ContactGroup>> Function() groupsLoader,
  Future<void> Function(String groupId)? deleteGroup,
  _TestNavigatorObserver? observer,
}) {
  final navObserver = observer ?? _TestNavigatorObserver();
  final delete = deleteGroup ?? (_) async {};

  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        allGroupsProvider.overrideWith((ref) => groupsLoader()),
        deleteGroupProvider.overrideWith((ref) => delete),
      ],
      child: MaterialApp(
        navigatorObservers: <NavigatorObserver>[navObserver],
        routes: <String, WidgetBuilder>{
          '/create-group': (_) => const Scaffold(body: Text('create-group')),
          '/edit-group': (_) => const Scaffold(body: Text('edit-group')),
          '/group-chat': (_) => const Scaffold(body: Text('group-chat')),
        },
        home: const GroupListScreen(),
      ),
    ),
  );
}

class _TestNavigatorObserver extends NavigatorObserver {
  final List<String?> pushedRouteNames = <String?>[];
  final List<Object?> pushedArguments = <Object?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedRouteNames.add(route.settings.name);
    pushedArguments.add(route.settings.arguments);
    super.didPush(route, previousRoute);
  }
}

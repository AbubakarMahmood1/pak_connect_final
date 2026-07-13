import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/identity_reveal_info.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/widgets/spy_mode_listener.dart';

final _identityEventStreamProvider = Provider<Stream<IdentityRevealInfo>>(
  (ref) => const Stream.empty(),
);
final _identityEventProvider = StreamProvider<IdentityRevealInfo>(
  (ref) => ref.watch(_identityEventStreamProvider),
);

IdentityRevealInfo _reveal(String suffix) => IdentityRevealInfo(
  contactName: 'Same Name',
  persistentPublicKey: 'persistent-$suffix',
  contactPublicKey: 'first-$suffix',
  chatId: ChatId('persistent-$suffix'),
);

Future<
  ({ProviderContainer container, StreamController<IdentityRevealInfo> events})
>
_pumpListener(WidgetTester tester) async {
  final events = StreamController<IdentityRevealInfo>.broadcast();
  final container = ProviderContainer(
    overrides: [
      _identityEventStreamProvider.overrideWithValue(events.stream),
      identityRevealedProvider.overrideWith(
        (ref) => ref.watch(_identityEventProvider),
      ),
      spyModeDetectedProvider.overrideWith(
        (ref) => const AsyncValue<SpyModeInfo>.loading(),
      ),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SpyModeListener(
          identityRevealDestinationBuilder: (context, reveal) => Scaffold(
            body: Text(
              '${reveal.persistentPublicKey}|${reveal.chatId.value}',
              key: const Key('identity-destination'),
            ),
          ),
          child: const Scaffold(body: Text('home')),
        ),
      ),
    ),
  );
  return (container: container, events: events);
}

void main() {
  testWidgets('VIEW uses stable identity when display names are duplicated', (
    tester,
  ) async {
    final harness = await _pumpListener(tester);
    addTearDown(() async {
      harness.container.dispose();
      if (!harness.events.isClosed) await harness.events.close();
    });

    final duplicateA = _reveal('a');
    final duplicateB = _reveal('b');
    expect(duplicateA.contactName, duplicateB.contactName);
    harness.events.add(duplicateB);
    await tester.pump();
    await tester.pump();

    expect(find.text('Same Name revealed their identity!'), findsOneWidget);
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('identity-destination')), findsOneWidget);
    expect(find.text('persistent-b|persistent-b'), findsOneWidget);
  });

  testWidgets(
    'VIEW retains captured identity after reveal stream disconnects',
    (tester) async {
      final harness = await _pumpListener(tester);
      addTearDown(() async {
        harness.container.dispose();
        if (!harness.events.isClosed) await harness.events.close();
      });

      harness.events.add(_reveal('captured'));
      await tester.pump();
      await harness.events.close();
      await tester.pump();

      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('persistent-captured|persistent-captured'),
        findsOneWidget,
      );
    },
  );
}

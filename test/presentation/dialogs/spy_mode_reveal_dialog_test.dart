import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/presentation/dialogs/spy_mode_reveal_dialog.dart';

void main() {
  group('SpyModeRevealDialog', () {
    testWidgets('renders contact details and invokes both callbacks', (tester) async {
      var revealed = false;
      var stayedAnonymous = false;
      final info = SpyModeInfo(
        contactName: 'Alice',
        ephemeralID: 'ephemeral-a',
        persistentKey: 'pk-a',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpyModeRevealDialog(
              info: info,
              onReveal: () => revealed = true,
              onStayAnonymous: () => stayedAnonymous = true,
            ),
          ),
        ),
      );

      expect(find.textContaining('Alice'), findsNWidgets(2));
      expect(find.text('Stay Anonymous'), findsOneWidget);
      expect(find.text('Reveal Identity'), findsOneWidget);

      await tester.tap(find.text('Stay Anonymous'));
      await tester.pump();
      expect(stayedAnonymous, isTrue);
      expect(revealed, isFalse);

      await tester.tap(find.text('Reveal Identity'));
      await tester.pump();
      expect(revealed, isTrue);
    });

    testWidgets('static show helper returns user choice', (tester) async {
      bool? dialogResult;
      final info = SpyModeInfo(
        contactName: 'Bob',
        ephemeralID: 'ephemeral-b',
        persistentKey: 'pk-b',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  dialogResult = await SpyModeRevealDialog.show(
                    context: context,
                    info: info,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('Reveal Identity'));
      await tester.pumpAndSettle();

      expect(dialogResult, isTrue);
    });
  });
}

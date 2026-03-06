import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/widgets/pairing_dialog.dart';

void main() {
  group('PairingDialog', () {
    testWidgets('shows pairing code and auto-submits when 4 digits entered', (
      tester,
    ) async {
      String? submitted;
      var cancelled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PairingDialog(
              myCode: '1234',
              onCodeEntered: (value) => submitted = value,
              onCancel: () => cancelled = true,
            ),
          ),
        ),
      );

      expect(find.text('Secure Pairing'), findsOneWidget);
      expect(find.text('1234'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '9999');
      await tester.pump();

      expect(submitted, '9999');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(cancelled, isFalse);
    });

    testWidgets('verify button stays disabled until exactly 4 digits', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PairingDialog(
              myCode: '5555',
              onCodeEntered: (_) {},
              onCancel: () {},
            ),
          ),
        ),
      );

      final verifyFinder = find.widgetWithText(FilledButton, 'Verify');
      FilledButton verifyButton = tester.widget<FilledButton>(verifyFinder);
      expect(verifyButton.onPressed, isNull);

      await tester.enterText(find.byType(TextField), '123');
      await tester.pump();
      verifyButton = tester.widget<FilledButton>(verifyFinder);
      expect(verifyButton.onPressed, isNull);
    });

    testWidgets('cancel callback fires before verification starts', (tester) async {
      var cancelCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PairingDialog(
              myCode: '0000',
              onCodeEntered: (_) {},
              onCancel: () => cancelCount++,
            ),
          ),
        ),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();

      expect(cancelCount, 1);
    });
  });
}

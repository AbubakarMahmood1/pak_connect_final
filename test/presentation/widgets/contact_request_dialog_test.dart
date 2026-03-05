import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/widgets/contact_request_dialog.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  group('ContactRequestDialog', () {
    testWidgets('renders incoming request and triggers accept/reject', (
      tester,
    ) async {
      var accepted = 0;
      var rejected = 0;

      await tester.pumpWidget(
        wrap(
          ContactRequestDialog(
            senderName: 'Alice',
            senderPublicKey: '0123456789ABCDEF0123456789ABCDEF',
            onAccept: () => accepted++,
            onReject: () => rejected++,
          ),
        ),
      );

      expect(find.text('Contact Request'), findsOneWidget);
      expect(
        find.textContaining('wants to add you as a contact'),
        findsOneWidget,
      );
      expect(find.textContaining('Device ID:'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.tap(find.text('Reject'));
      await tester.pump();

      expect(accepted, 1);
      expect(rejected, 1);
    });

    testWidgets('renders outgoing request copy and actions', (tester) async {
      await tester.pumpWidget(
        wrap(
          ContactRequestDialog(
            senderName: 'Bob',
            senderPublicKey: 'short-key',
            onAccept: () {},
            onReject: () {},
            isOutgoing: true,
          ),
        ),
      );

      expect(find.text('Add Contact?'), findsOneWidget);
      expect(find.textContaining('Do you want to add "Bob"'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Send Request'), findsOneWidget);
      expect(find.textContaining('Device ID:'), findsNothing);
    });
  });

  group('ContactRequestPendingDialog', () {
    testWidgets('renders wait state and cancel action', (tester) async {
      var cancelled = 0;

      await tester.pumpWidget(
        wrap(
          ContactRequestPendingDialog(
            recipientName: 'Charlie',
            onCancel: () => cancelled++,
          ),
        ),
      );

      expect(find.text('Contact Request Sent'), findsOneWidget);
      expect(find.textContaining('Waiting for "Charlie"'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(cancelled, 1);
    });
  });

  group('ContactRequestResultDialog', () {
    testWidgets('renders accepted state and close action', (tester) async {
      var closed = 0;
      await tester.pumpWidget(
        wrap(
          ContactRequestResultDialog(
            contactName: 'Dora',
            wasAccepted: true,
            onClose: () => closed++,
          ),
        ),
      );

      expect(find.text('Contact Added!'), findsOneWidget);
      expect(
        find.textContaining('accepted your contact request'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('renders rejected state', (tester) async {
      await tester.pumpWidget(
        wrap(
          ContactRequestResultDialog(
            contactName: 'Eve',
            wasAccepted: false,
            onClose: () {},
          ),
        ),
      );

      expect(find.text('Request Rejected'), findsOneWidget);
      expect(
        find.textContaining('rejected your contact request'),
        findsOneWidget,
      );
    });
  });
}

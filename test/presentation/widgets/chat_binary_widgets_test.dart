import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/widgets/chat_binary_widgets.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show ReceivedBinaryEvent, PendingBinaryTransfer;

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  ReceivedBinaryEvent event0({
    required String id,
    required String path,
    required int size,
    int originalType = 7,
    int ttl = 2,
    String? recipient,
  }) {
    return ReceivedBinaryEvent(
      fragmentId: 'frag-$id',
      originalType: originalType,
      filePath: path,
      size: size,
      transferId: id,
      ttl: ttl,
      recipient: recipient,
      senderNodeId: 'sender-node',
    );
  }

  testWidgets('BinaryInboxList renders sorted entries and dismiss callback', (
    tester,
  ) async {
    final dismissed = <String>[];

    final inbox = <String, ReceivedBinaryEvent>{
      'small': event0(id: 'small', path: '/tmp/small.bin', size: 512),
      'large': event0(
        id: 'large',
        path: '/tmp/large.bin',
        size: 2 * 1024 * 1024,
      ),
    };

    await tester.pumpWidget(
      wrap(BinaryInboxList(inbox: inbox, onDismiss: dismissed.add)),
    );

    expect(find.text('New media received'), findsOneWidget);
    expect(find.textContaining('2.0 MB'), findsOneWidget);
    expect(find.textContaining('512 B'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss').first);
    await tester.pump();
    expect(dismissed.length, 1);
    expect(dismissed.first, isNotEmpty);
  });

  testWidgets('BinaryInboxList opens viewer on tile tap', (tester) async {
    final inbox = <String, ReceivedBinaryEvent>{
      'one': event0(id: 'one', path: '/tmp/one.jpg', size: 2048),
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BinaryInboxList(inbox: inbox, onDismiss: (_) {}),
        ),
      ),
    );

    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();

    expect(find.byType(BinaryPayloadViewer), findsOneWidget);
    expect(find.textContaining('transferId: one'), findsOneWidget);
    expect(find.textContaining('Recipient: broadcast'), findsOneWidget);
  });

  testWidgets('PendingBinaryBanner renders count and retry callback', (
    tester,
  ) async {
    var retries = 0;
    final transfers = [
      PendingBinaryTransfer(
        transferId: 't1',
        recipientId: 'alice',
        originalType: 1,
      ),
      PendingBinaryTransfer(
        transferId: 't2',
        recipientId: 'bob',
        originalType: 2,
      ),
    ];

    await tester.pumpWidget(
      wrap(
        PendingBinaryBanner(
          transfers: transfers,
          onRetryNow: () async {
            retries++;
          },
        ),
      ),
    );

    expect(find.textContaining('Pending media sends: 2'), findsOneWidget);
    await tester.tap(find.text('Retry now'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('BinaryPayloadViewer falls back to file icon for non-image', (
    tester,
  ) async {
    final event = event0(
      id: 'doc',
      path: '/tmp/report.pdf',
      size: 1024,
      recipient: 'node-z',
    );

    await tester.pumpWidget(
      MaterialApp(home: BinaryPayloadViewer(event: event)),
    );

    expect(find.text('Media 7'), findsOneWidget);
    expect(find.textContaining('Recipient: node-z'), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file), findsWidgets);
  });

  testWidgets('BinaryPayloadViewer shows image widget when image exists', (
    tester,
  ) async {
    final event = event0(
      id: 'img',
      path: '/tmp/sample.png',
      size: 4096,
      originalType: 3,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BinaryPayloadViewer(
          event: event,
          imagePreviewBuilder:
              (_) => const SizedBox(key: Key('binary-image-preview')),
          fileExists: (_) => true,
        ),
      ),
    );

    expect(find.byKey(const Key('binary-image-preview')), findsOneWidget);
    expect(find.textContaining('transferId: img'), findsOneWidget);
  });
}

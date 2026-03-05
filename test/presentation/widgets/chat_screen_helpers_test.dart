import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/widgets/chat_screen_helpers.dart';

class _FakeBleService {
  _FakeBleService({required this.state, this.isActivelyReconnecting = false});

  BluetoothLowEnergyState state;
  bool isActivelyReconnecting;
}

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  group('ReconnectionBanner', () {
    testWidgets('shows bluetooth-off warning', (tester) async {
      final ble = _FakeBleService(state: BluetoothLowEnergyState.poweredOff);

      await tester.pumpWidget(
        wrap(
          ReconnectionBanner(
            bleService: ble,
            isPeripheralMode: false,
            onReconnect: () {},
          ),
        ),
      );

      expect(find.textContaining('Bluetooth is off'), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
    });

    testWidgets('shows peripheral advertising banner', (tester) async {
      final ble = _FakeBleService(state: BluetoothLowEnergyState.poweredOn);
      await tester.pumpWidget(
        wrap(
          ReconnectionBanner(
            bleService: ble,
            isPeripheralMode: true,
            onReconnect: () {},
          ),
        ),
      );

      expect(find.textContaining('Advertising - Waiting'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);
    });

    testWidgets('shows reconnecting banner and button callback', (
      tester,
    ) async {
      var reconnectTapped = 0;
      final ble = _FakeBleService(
        state: BluetoothLowEnergyState.poweredOn,
        isActivelyReconnecting: true,
      );
      await tester.pumpWidget(
        wrap(
          ReconnectionBanner(
            bleService: ble,
            isPeripheralMode: false,
            onReconnect: () => reconnectTapped++,
          ),
        ),
      );

      expect(find.text('Searching for device...'), findsOneWidget);
      expect(find.text('Reconnect Now'), findsOneWidget);
      await tester.tap(find.text('Reconnect Now'));
      await tester.pump();
      expect(reconnectTapped, 1);
    });

    testWidgets('renders nothing when no banner conditions match', (
      tester,
    ) async {
      final ble = _FakeBleService(state: BluetoothLowEnergyState.poweredOn);
      await tester.pumpWidget(
        wrap(
          ReconnectionBanner(
            bleService: ble,
            isPeripheralMode: false,
            onReconnect: () {},
          ),
        ),
      );

      expect(find.textContaining('Bluetooth is off'), findsNothing);
      expect(find.textContaining('Advertising - Waiting'), findsNothing);
      expect(find.text('Reconnect Now'), findsNothing);
    });
  });

  testWidgets('InitializationStatusPanel renders status text', (tester) async {
    await tester.pumpWidget(
      wrap(
        const InitializationStatusPanel(statusText: 'Bootstrapping nodes...'),
      ),
    );

    expect(find.text('Smart Routing Mesh Network'), findsOneWidget);
    expect(find.text('Bootstrapping nodes...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('EmptyChatPlaceholder renders empty-state copy', (tester) async {
    await tester.pumpWidget(wrap(const EmptyChatPlaceholder()));

    expect(find.text('Start your conversation'), findsOneWidget);
    expect(find.text('Send a message to begin chatting'), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
  });

  group('RetryIndicator', () {
    testWidgets('hides itself when failedCount is zero', (tester) async {
      await tester.pumpWidget(
        wrap(RetryIndicator(failedCount: 0, onRetry: () {})),
      );

      expect(find.textContaining('failed'), findsNothing);
      expect(find.text('retry'), findsNothing);
    });

    testWidgets('shows retry chip and invokes callback on tap', (tester) async {
      var retryTapped = 0;
      await tester.pumpWidget(
        wrap(RetryIndicator(failedCount: 3, onRetry: () => retryTapped++)),
      );

      expect(find.text('3 failed'), findsOneWidget);
      expect(find.text('retry'), findsOneWidget);
      await tester.tap(find.text('3 failed'));
      await tester.pump();
      expect(retryTapped, 1);
    });
  });

  testWidgets('UnreadSeparator renders gradient divider', (tester) async {
    await tester.pumpWidget(wrap(const UnreadSeparator()));
    expect(find.byType(Container), findsWidgets);
  });
}

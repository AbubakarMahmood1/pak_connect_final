import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_header.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_peripheral_view.dart';

class _FakeCentral implements Central {
  _FakeCentral(String uuid) : _uuid = UUID.fromString(uuid);

  final UUID _uuid;

  @override
  UUID get uuid => _uuid;
}

Future<void> _pumpHarness(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  group('DiscoveryHeader', () {
    testWidgets('renders scanner-mode title/icon and handles actions', (
      tester,
    ) async {
      var toggleCalls = 0;
      var closeCalls = 0;

      await _pumpHarness(
        tester,
        DiscoveryHeader(
          showScannerMode: true,
          isPeripheralMode: false,
          onToggleMode: () => toggleCalls++,
          onClose: () => closeCalls++,
        ),
      );

      expect(find.text('Discovered Devices'), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);
      expect(find.byTooltip('Show connected centrals'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump();
      expect(toggleCalls, 1);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closeCalls, 1);
    });

    testWidgets('renders peripheral-mode title/icon and alternate tooltip', (
      tester,
    ) async {
      await _pumpHarness(
        tester,
        DiscoveryHeader(
          showScannerMode: false,
          isPeripheralMode: true,
          onToggleMode: () {},
          onClose: () {},
        ),
      );

      expect(find.text('Connected Centrals'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);
      expect(find.byTooltip('Show discovered devices'), findsOneWidget);
    });
  });

  group('DiscoveryPeripheralView', () {
    testWidgets('renders empty state when no centrals are connected', (
      tester,
    ) async {
      await _pumpHarness(
        tester,
        DiscoveryPeripheralView(
          serverConnections: const [],
          onOpenChat: (_) {},
        ),
      );

      expect(find.text('Peripheral Mode'), findsOneWidget);
      expect(find.text('0 device(s) connected to you'), findsOneWidget);
      expect(find.text('No devices connected'), findsOneWidget);
      expect(
        find.text('Waiting for others to discover you...'),
        findsOneWidget,
      );
    });

    testWidgets('renders connected centrals metadata and opens chat on tap', (
      tester,
    ) async {
      final centralOne = _FakeCentral('77777777-7777-7777-7777-777777777777');
      final centralTwo = _FakeCentral('88888888-8888-8888-8888-888888888888');
      Central? tappedCentral;

      final subscribedCharacteristic = GATTCharacteristic.mutable(
        uuid: UUID.short(0x2A37),
        properties: const [GATTCharacteristicProperty.notify],
        permissions: const [GATTCharacteristicPermission.read],
        descriptors: const [],
      );

      final connections = [
        BLEServerConnection(
          address: 'AA:BB:CC:DD:EE:FF',
          central: centralOne,
          connectedAt: DateTime.now().subtract(const Duration(minutes: 2)),
          mtu: 185,
          subscribedCharacteristic: subscribedCharacteristic,
        ),
        BLEServerConnection(
          address: '11:22:33:44:55:66',
          central: centralTwo,
          connectedAt: DateTime.now().subtract(const Duration(seconds: 40)),
        ),
      ];

      await _pumpHarness(
        tester,
        DiscoveryPeripheralView(
          serverConnections: connections,
          onOpenChat: (central) => tappedCentral = central,
        ),
      );

      expect(find.text('2 device(s) connected to you'), findsOneWidget);
      expect(find.text('Device AA:BB:CC:DD:EE:FF'), findsOneWidget);
      expect(find.text('Device 11:22:33:44:55:66'), findsOneWidget);
      expect(find.textContaining('Connected for:'), findsNWidgets(2));
      expect(find.text('MTU: 185 bytes'), findsOneWidget);
      expect(find.text('Subscribed to notifications'), findsOneWidget);
      expect(find.text('Not subscribed'), findsOneWidget);

      await tester.tap(find.text('Device 11:22:33:44:55:66'));
      await tester.pump();
      expect(tappedCentral, same(centralTwo));
    });
  });
}

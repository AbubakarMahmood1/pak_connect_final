import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_device_tile.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_types.dart';

class _FakePeripheral implements Peripheral {
  _FakePeripheral(String uuid) : _uuid = UUID.fromString(uuid);

  final UUID _uuid;

  @override
  UUID get uuid => _uuid;
}

Contact _contact({
  required String displayName,
  required String publicKey,
  TrustStatus trustStatus = TrustStatus.newContact,
  SecurityLevel securityLevel = SecurityLevel.low,
}) {
  final now = DateTime.now();
  return Contact(
    publicKey: publicKey,
    displayName: displayName,
    trustStatus: trustStatus,
    securityLevel: securityLevel,
    firstSeen: now,
    lastSeen: now,
  );
}

EnhancedContact _enhancedContact(Contact contact) {
  return EnhancedContact(
    contact: contact,
    lastSeenAgo: const Duration(minutes: 2),
    isRecentlyActive: true,
    interactionCount: 4,
    averageResponseTime: const Duration(minutes: 1),
    groupMemberships: const [],
  );
}

DiscoveredEventArgs _discovered(_FakePeripheral peripheral, {int rssi = -55}) {
  return DiscoveredEventArgs(
    peripheral,
    rssi,
    Advertisement(name: 'Test Device'),
  );
}

DiscoveredDevice _dedupDevice({
  required _FakePeripheral peripheral,
  required EnhancedContact contact,
  required DiscoveredEventArgs advertisement,
}) {
  return DiscoveredDevice(
      deviceId: peripheral.uuid.toString(),
      ephemeralHint: DeviceDeduplicationManager.noHintValue,
      peripheral: peripheral,
      rssi: advertisement.rssi,
      advertisement: advertisement.advertisement,
      firstSeen: DateTime.now().subtract(const Duration(minutes: 1)),
      lastSeen: DateTime.now(),
    )
    ..isKnownContact = true
    ..contactInfo = contact;
}

Future<void> _pumpTile(WidgetTester tester, DiscoveryDeviceTile tile) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: tile)));
  await tester.pump();
}

void main() {
  const loggerName = 'DiscoveryDeviceTileTest';

  group('DiscoveryDeviceTile', () {
    testWidgets('unknown device shows default connect state and taps connect', (
      tester,
    ) async {
      final device = _FakePeripheral('11111111-1111-1111-1111-111111111111');
      var connectCalls = 0;
      var retryCalls = 0;
      var openChatCalls = 0;
      final errors = <String>[];

      await _pumpTile(
        tester,
        DiscoveryDeviceTile(
          device: device,
          advertisement: null,
          isKnownContact: false,
          dedupDevice: null,
          contacts: const {},
          attemptState: ConnectionAttemptState.none,
          isConnectedAsCentral: false,
          isConnectedAsPeripheral: false,
          connectionReady: false,
          onConnect: () async => connectCalls++,
          onRetry: () => retryCalls++,
          onOpenChat: () => openChatCalls++,
          onError: errors.add,
          logger: Logger(loggerName),
        ),
      );

      expect(find.textContaining('Device '), findsOneWidget);
      expect(find.text('Signal: Poor'), findsOneWidget);
      expect(find.text('TAP TO CONNECT'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.byType(ListTile));
      await tester.pump();

      expect(connectCalls, 1);
      expect(retryCalls, 0);
      expect(openChatCalls, 0);
      expect(errors, isEmpty);
    });

    testWidgets(
      'connecting attempt blocks connect and reports in-progress error',
      (tester) async {
        final device = _FakePeripheral('22222222-2222-2222-2222-222222222222');
        var connectCalls = 0;
        final errors = <String>[];

        await _pumpTile(
          tester,
          DiscoveryDeviceTile(
            device: device,
            advertisement: _discovered(device, rssi: -56),
            isKnownContact: false,
            dedupDevice: null,
            contacts: const {},
            attemptState: ConnectionAttemptState.connecting,
            isConnectedAsCentral: false,
            isConnectedAsPeripheral: false,
            connectionReady: false,
            onConnect: () async => connectCalls++,
            onRetry: () {},
            onOpenChat: () {},
            onError: errors.add,
            logger: Logger(loggerName),
          ),
        );

        expect(find.text('CONNECTING'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.tap(find.byType(ListTile));
        await tester.pump();

        expect(connectCalls, 0);
        expect(errors, ['Connection in progress, please wait...']);
      },
    );

    testWidgets('failed attempt triggers retry path', (tester) async {
      final device = _FakePeripheral('33333333-3333-3333-3333-333333333333');
      var retryCalls = 0;

      await _pumpTile(
        tester,
        DiscoveryDeviceTile(
          device: device,
          advertisement: _discovered(device, rssi: -68),
          isKnownContact: false,
          dedupDevice: null,
          contacts: const {},
          attemptState: ConnectionAttemptState.failed,
          isConnectedAsCentral: false,
          isConnectedAsPeripheral: false,
          connectionReady: false,
          onConnect: () async {},
          onRetry: () => retryCalls++,
          onOpenChat: () {},
          onError: (_) {},
          logger: Logger(loggerName),
        ),
      );

      expect(find.text('RETRY'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsWidgets);

      await tester.tap(find.byType(ListTile));
      await tester.pump();

      expect(retryCalls, 1);
    });

    testWidgets('connected dual-role device opens chat immediately', (
      tester,
    ) async {
      final device = _FakePeripheral('44444444-4444-4444-4444-444444444444');
      var openChatCalls = 0;
      var connectCalls = 0;

      await _pumpTile(
        tester,
        DiscoveryDeviceTile(
          device: device,
          advertisement: _discovered(device, rssi: -48),
          isKnownContact: false,
          dedupDevice: null,
          contacts: const {},
          attemptState: ConnectionAttemptState.none,
          isConnectedAsCentral: true,
          isConnectedAsPeripheral: true,
          connectionReady: true,
          onConnect: () async => connectCalls++,
          onRetry: () {},
          onOpenChat: () => openChatCalls++,
          onError: (_) {},
          logger: Logger(loggerName),
        ),
      );

      expect(find.text('BOTH ROLES'), findsOneWidget);
      expect(find.text('CONNECTED'), findsOneWidget);
      expect(find.byIcon(Icons.chat), findsOneWidget);

      await tester.tap(find.byType(ListTile));
      await tester.pump();

      expect(openChatCalls, 1);
      expect(connectCalls, 0);
    });

    testWidgets('resolved dedup contact shows verified high-security chips', (
      tester,
    ) async {
      final device = _FakePeripheral('55555555-5555-5555-5555-555555555555');
      final ad = _discovered(device, rssi: -45);
      final contact = _contact(
        displayName: 'Alice Verified',
        publicKey: 'public-key-alice',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.high,
      );

      await _pumpTile(
        tester,
        DiscoveryDeviceTile(
          device: device,
          advertisement: ad,
          isKnownContact: false,
          dedupDevice: _dedupDevice(
            peripheral: device,
            contact: _enhancedContact(contact),
            advertisement: ad,
          ),
          contacts: const {},
          attemptState: ConnectionAttemptState.none,
          isConnectedAsCentral: false,
          isConnectedAsPeripheral: false,
          connectionReady: false,
          onConnect: () async {},
          onRetry: () {},
          onOpenChat: () {},
          onError: (_) {},
          logger: Logger(loggerName),
        ),
      );

      expect(find.text('Alice Verified'), findsOneWidget);
      expect(find.text('CONTACT'), findsOneWidget);
      expect(find.text('VERIFIED'), findsOneWidget);
      expect(find.text('ECDH'), findsOneWidget);
      expect(find.byIcon(Icons.verified_user), findsWidgets);
    });

    testWidgets(
      'known-contact fallback resolves by public key and uses paired chip',
      (tester) async {
        final device = _FakePeripheral('66666666-6666-6666-6666-666666666666');
        final contact = _contact(
          displayName: 'Known Bob',
          publicKey: 'user-${device.uuid}-suffix',
          securityLevel: SecurityLevel.medium,
        );
        var connectCalls = 0;

        await _pumpTile(
          tester,
          DiscoveryDeviceTile(
            device: device,
            advertisement: _discovered(device, rssi: -62),
            isKnownContact: true,
            dedupDevice: null,
            contacts: {'known-bob': contact},
            attemptState: ConnectionAttemptState.connected,
            isConnectedAsCentral: false,
            isConnectedAsPeripheral: false,
            connectionReady: false,
            onConnect: () async => connectCalls++,
            onRetry: () {},
            onOpenChat: () {},
            onError: (_) {},
            logger: Logger(loggerName),
          ),
        );

        expect(find.text('Known Bob'), findsOneWidget);
        expect(find.text('PAIRED'), findsOneWidget);
        expect(find.text('CONNECTED'), findsOneWidget);

        await tester.tap(find.byType(ListTile));
        await tester.pump();

        expect(connectCalls, 1);
      },
    );
  });
}

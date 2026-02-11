import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/core/services/chat_connection_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/ble_service.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';

import '../../helpers/ble/ble_fakes.dart';
import '../../test_helpers/test_setup.dart';
import 'package:pak_connect/domain/models/security_level.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'chat_connection_manager',
    );
  });

  group('ChatConnectionManager.determineConnectionStatus', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('returns connected when session is ready for the contact', () {
      final manager = _createManager();

      final status = manager.determineConnectionStatus(
        contactPublicKey: 'alice-key',
        contactName: 'Alice',
        currentConnectionInfo: const ConnectionInfo(
          isConnected: true,
          isReady: true,
          otherUserName: 'Alice',
        ),
        discoveredDevices: const [],
        discoveryData: const {},
        lastSeenTime: null,
      );

      expect(status, ConnectionStatus.connected);
    });

    test(
      'returns connected when active session id matches even if names differ',
      () {
        final manager = _createManager(
          bleService: _StubBleService(sessionId: 'session-key'),
        );

        final status = manager.determineConnectionStatus(
          contactPublicKey: 'session-key',
          contactName: 'Custom Alias',
          currentConnectionInfo: const ConnectionInfo(
            isConnected: true,
            isReady: true,
            otherUserName: 'Handshake Name',
          ),
          discoveredDevices: const [],
          discoveryData: const {},
          lastSeenTime: null,
        );

        expect(status, ConnectionStatus.connected);
      },
    );

    test('returns connecting when BLE service is still negotiating', () async {
      final bleService = _StubBleService(persistentKey: 'contact-123');
      final manager = _createManager(bleService: bleService);

      final status = manager.determineConnectionStatus(
        contactPublicKey: 'contact-123',
        contactName: 'Contact 123',
        currentConnectionInfo: const ConnectionInfo(
          isConnected: true,
          isReady: false,
          otherUserName: 'Contact 123',
        ),
        discoveredDevices: const [],
        discoveryData: const {},
        lastSeenTime: null,
      );

      expect(status, ConnectionStatus.connecting);
    });

    test('returns nearby when discovery hash matches a known contact', () {
      final manager = _createManager();
      final contact = _buildEnhancedContact(
        publicKey: 'base-key',
        ephemeralId: 'session-abc',
        displayName: 'Hash Match',
      );

      final device = _buildDiscoveredDevice(
        uuid: '11111111-2222-3333-4444-555555555555',
        contact: contact,
      );

      final status = manager.determineConnectionStatus(
        contactPublicKey: 'session-abc',
        contactName: 'Hash Match',
        currentConnectionInfo: null,
        discoveredDevices: const [],
        discoveryData: {device.deviceId: device},
        lastSeenTime: null,
      );

      expect(status, ConnectionStatus.nearby);
    });

    test('returns nearby when device UUID appears in discovery list', () {
      final manager = _createManager();
      final uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      final peripheral = fakePeripheralFromString(uuid);

      final status = manager.determineConnectionStatus(
        contactPublicKey: 'contact-$uuid',
        contactName: 'Peripheral Match',
        currentConnectionInfo: null,
        discoveredDevices: [peripheral],
        discoveryData: const {},
        lastSeenTime: null,
      );

      expect(status, ConnectionStatus.nearby);
    });

    test('returns recent when contact seen within five minutes', () {
      final manager = _createManager();
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 3));

      final status = manager.determineConnectionStatus(
        contactPublicKey: 'recent-contact',
        contactName: 'Recent',
        currentConnectionInfo: null,
        discoveredDevices: const [],
        discoveryData: const {},
        lastSeenTime: lastSeen,
      );

      expect(status, ConnectionStatus.recent);
    });

    test('returns offline when no signals are present', () {
      final manager = _createManager();

      final status = manager.determineConnectionStatus(
        contactPublicKey: 'offline-contact',
        contactName: 'Offline',
        currentConnectionInfo: null,
        discoveredDevices: const [],
        discoveryData: const {},
        lastSeenTime: null,
      );

      expect(status, ConnectionStatus.offline);
    });
  });

  group('ChatConnectionManager hash detection', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('detects contact via current ephemeral ID', () {
      final manager = _createManager();
      final contact = _buildEnhancedContact(
        publicKey: 'base',
        ephemeralId: 'match-ephemeral',
        displayName: 'Ephemeral',
      );
      final device = _buildDiscoveredDevice(
        uuid: 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff',
        contact: contact,
      );

      final result = manager.isContactOnlineViaHash(
        contactPublicKey: 'match-ephemeral',
        discoveryData: {device.deviceId: device},
      );

      expect(result, isTrue);
    });

    test('detects contact via persistent key for paired contact', () {
      final manager = _createManager();
      final contact = _buildEnhancedContact(
        publicKey: 'transient',
        persistentKey: 'persistent-key',
        displayName: 'Paired',
      );
      final device = _buildDiscoveredDevice(
        uuid: 'cccccccc-dddd-eeee-ffff-000000000000',
        contact: contact,
      );

      final result = manager.isContactOnlineViaHash(
        contactPublicKey: 'persistent-key',
        discoveryData: {device.deviceId: device},
      );

      expect(result, isTrue);
    });

    test('returns false when no known contacts are in the map', () {
      final manager = _createManager();

      final result = manager.isContactOnlineViaHash(
        contactPublicKey: 'missing',
        discoveryData: const {},
      );

      expect(result, isFalse);
    });
  });

  group('ChatConnectionManager helpers', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('getKnownContactsFromDiscovery filters unknown devices', () {
      final manager = _createManager();
      final known = _buildDiscoveredDevice(
        uuid: 'dddddddd-eeee-ffff-0000-111111111111',
        contact: _buildEnhancedContact(publicKey: 'known'),
      );
      final unknown = _buildDiscoveredDevice(
        uuid: 'eeeeeeee-ffff-0000-1111-222222222222',
        markKnown: false,
        contact: null,
      );

      final filtered = manager.getKnownContactsFromDiscovery({
        known.deviceId: known,
        unknown.deviceId: unknown,
      });

      expect(filtered.length, 1);
      expect(filtered.values.first.contactInfo, isNotNull);
      expect(filtered.values.first.contactInfo!.contact.publicKey, 'known');
    });

    test('isDeviceDiscovered matches UUID substring', () {
      final manager = _createManager();
      final uuid = 'ffffffff-0000-1111-2222-333333333333';
      final peripheral = fakePeripheralFromString(uuid);

      final result = manager.isDeviceDiscovered(
        contactPublicKey: 'abc$uuid',
        discoveredDevices: [peripheral],
      );

      expect(result, isTrue);
    });
  });
}

ChatConnectionManager _createManager({BLEService? bleService}) {
  final manager = ChatConnectionManager(bleService: bleService);
  addTearDown(() async {
    await manager.dispose();
  });
  return manager;
}

EnhancedContact _buildEnhancedContact({
  required String publicKey,
  String? persistentKey,
  String? ephemeralId,
  String displayName = 'Contact',
}) {
  final now = DateTime.now();
  final contact = Contact(
    publicKey: publicKey,
    persistentPublicKey: persistentKey,
    currentEphemeralId: ephemeralId ?? publicKey,
    displayName: displayName,
    trustStatus: TrustStatus.verified,
    securityLevel: persistentKey != null
        ? SecurityLevel.medium
        : SecurityLevel.low,
    firstSeen: now.subtract(const Duration(days: 30)),
    lastSeen: now.subtract(const Duration(minutes: 1)),
  );

  return EnhancedContact(
    contact: contact,
    lastSeenAgo: const Duration(minutes: 1),
    isRecentlyActive: true,
    interactionCount: 0,
    averageResponseTime: const Duration(minutes: 2),
    groupMemberships: const [],
  );
}

DiscoveredDevice _buildDiscoveredDevice({
  required String uuid,
  EnhancedContact? contact,
  bool markKnown = true,
}) {
  final device = DiscoveredDevice(
    deviceId: uuid,
    ephemeralHint: 'hint-$uuid',
    peripheral: fakePeripheralFromString(uuid),
    rssi: -45,
    advertisement: Advertisement(name: contact?.contact.displayName),
    firstSeen: DateTime.now().subtract(const Duration(minutes: 1)),
    lastSeen: DateTime.now(),
  );
  device.isKnownContact = markKnown;
  device.contactInfo = contact;
  return device;
}

class _StubBleService extends BLEService {
  _StubBleService({this.persistentKey, this.sessionId});

  final String? persistentKey;
  final String? sessionId;

  @override
  String? get theirPersistentKey => persistentKey;

  @override
  String? get theirPersistentPublicKey => persistentKey;

  @override
  String? get currentSessionId => sessionId;

  @override
  String? get theirEphemeralId => sessionId;
}

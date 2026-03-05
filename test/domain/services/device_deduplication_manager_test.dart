import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';
import 'package:pak_connect/domain/entities/ephemeral_discovery_hint.dart';
import 'package:pak_connect/domain/interfaces/i_intro_hint_repository.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/domain/services/hint_cache_manager.dart';
import 'package:pak_connect/domain/utils/hint_advertisement_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DeviceDeduplicationManager.onKnownContactDiscovered = null;
    DeviceDeduplicationManager.shouldAutoConnect = null;
    DeviceDeduplicationManager.myEphemeralHintProvider = null;
    DeviceDeduplicationManager.clearIntroHintRepository();
    DeviceDeduplicationManager.setStaleTimeout(const Duration(minutes: 2));
    DeviceDeduplicationManager.clearAll();
    HintCacheManager.dispose();
  });

  tearDown(() {
    DeviceDeduplicationManager.onKnownContactDiscovered = null;
    DeviceDeduplicationManager.shouldAutoConnect = null;
    DeviceDeduplicationManager.myEphemeralHintProvider = null;
    DeviceDeduplicationManager.clearIntroHintRepository();
    DeviceDeduplicationManager.clearAll();
    HintCacheManager.dispose();
  });

  group('DeviceDeduplicationManager', () {
    test(
      'adds anonymous devices, streams updates, and supports removal helpers',
      () async {
        final snapshots = <Map<String, DiscoveredDevice>>[];
        final sub = DeviceDeduplicationManager.uniqueDevicesStream.listen(
          snapshots.add,
        );

        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '11111111-1111-1111-1111-111111111111',
            rssi: -65,
            payload: null,
          ),
        );
        await _settleAsync();

        expect(DeviceDeduplicationManager.deviceCount, 1);
        expect(DeviceDeduplicationManager.noHintValue, 'NO_HINT');

        final device = DeviceDeduplicationManager.getDevice(
          '11111111-1111-1111-1111-111111111111',
        );
        expect(device, isNotNull);
        expect(device!.ephemeralHint, 'NO_HINT');

        DeviceDeduplicationManager.markRetired(device.deviceId);
        expect(device.isRetired, isTrue);

        DeviceDeduplicationManager.removeDevice(device.deviceId);
        expect(DeviceDeduplicationManager.deviceCount, 0);

        expect(snapshots, isNotEmpty);
        await sub.cancel();
      },
    );

    test(
      'ignores self advertisement when ephemeral hint matches provider',
      () async {
        final nonce = Uint8List.fromList(<int>[0xAB, 0xCD]);
        final hintBytes = HintAdvertisementService.computeHintBytes(
          identifier: 'self',
          nonce: nonce,
        );
        final payload = HintAdvertisementService.packAdvertisement(
          nonce: nonce,
          hintBytes: hintBytes,
        );
        final myHint =
            '${HintAdvertisementService.bytesToHex(nonce)}:${HintAdvertisementService.bytesToHex(hintBytes)}';

        DeviceDeduplicationManager.myEphemeralHintProvider = () => myHint;
        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '22222222-2222-2222-2222-222222222222',
            rssi: -50,
            payload: payload,
          ),
        );
        await _settleAsync();

        expect(DeviceDeduplicationManager.deviceCount, 0);
      },
    );

    test(
      'merges duplicate rotating addresses when hint payload is identical',
      () async {
        final nonce = Uint8List.fromList(<int>[0x10, 0x20]);
        final hintBytes = HintAdvertisementService.computeHintBytes(
          identifier: 'contact-123',
          nonce: nonce,
        );
        final payload = HintAdvertisementService.packAdvertisement(
          nonce: nonce,
          hintBytes: hintBytes,
        );

        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '33333333-3333-3333-3333-333333333333',
            rssi: -80,
            payload: payload,
          ),
        );
        await _settleAsync();

        final first = DeviceDeduplicationManager.getDevice(
          '33333333-3333-3333-3333-333333333333',
        )!;
        first.isKnownContact = true;
        first.contactInfo = _enhancedContact(
          publicKey: 'pk-3333',
          chatKey: 'chat-shared',
          displayName: 'Merged Contact',
        );
        final originalFirstSeen = first.firstSeen;

        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '44444444-4444-4444-4444-444444444444',
            rssi: -45,
            payload: payload,
          ),
        );
        await _settleAsync();

        expect(
          DeviceDeduplicationManager.getDevice(
            '33333333-3333-3333-3333-333333333333',
          ),
          isNull,
        );

        final merged = DeviceDeduplicationManager.getDevice(
          '44444444-4444-4444-4444-444444444444',
        );
        expect(merged, isNotNull);
        expect(merged!.isKnownContact, isTrue);
        expect(merged.contactInfo?.displayName, 'Merged Contact');
        expect(merged.firstSeen, originalFirstSeen);
      },
    );

    test(
      'autoConnectStrongestRssi selects strongest eligible device and honors gating',
      () async {
        final connected = <String>[];
        DeviceDeduplicationManager.onKnownContactDiscovered =
            (peripheral, name) async {
              connected.add('${peripheral.uuid}:$name');
            };

        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '55555555-5555-5555-5555-555555555555',
            rssi: -90,
            payload: null,
          ),
        );
        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '66666666-6666-6666-6666-666666666666',
            rssi: -40,
            payload: null,
          ),
        );
        await _settleAsync();
        connected.clear();
        for (final id in <String>[
          '55555555-5555-5555-5555-555555555555',
          '66666666-6666-6666-6666-666666666666',
        ]) {
          final device = DeviceDeduplicationManager.getDevice(id);
          if (device != null) {
            device.autoConnectAttempted = false;
            device.nextRetryAt = null;
          }
        }

        await DeviceDeduplicationManager.autoConnectStrongestRssi();
        expect(connected.length, 1);
        expect(
          connected.single,
          contains('66666666-6666-6666-6666-666666666666'),
        );

        DeviceDeduplicationManager.shouldAutoConnect = (_) => false;
        await DeviceDeduplicationManager.autoConnectStrongestRssi();
        expect(connected.length, 1);
      },
    );

    test(
      'intro hint match marks device as known and invokes callback',
      () async {
        final scannedHint = EphemeralDiscoveryHint(
          hintBytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
          createdAt: DateTime(2026, 1, 1),
          expiresAt: DateTime(2027, 1, 1),
          displayName: 'Intro Friend',
        );
        final repo = _FakeIntroHintRepository(
          scannedHints: <String, EphemeralDiscoveryHint>{'intro': scannedHint},
        );
        DeviceDeduplicationManager.setIntroHintRepository(repo);

        final nonce = Uint8List.fromList(<int>[0x01, 0x99]);
        final hintBytes = HintAdvertisementService.computeHintBytes(
          identifier: scannedHint.hintHex,
          nonce: nonce,
        );
        final payload = HintAdvertisementService.packAdvertisement(
          nonce: nonce,
          hintBytes: hintBytes,
          isIntro: true,
        );

        final connected = <String>[];
        DeviceDeduplicationManager.onKnownContactDiscovered =
            (peripheral, name) async {
              connected.add(name);
            };

        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '77777777-7777-7777-7777-777777777777',
            rssi: -42,
            payload: payload,
          ),
        );
        await _settleAsync();

        final matched = DeviceDeduplicationManager.getDevice(
          '77777777-7777-7777-7777-777777777777',
        );
        expect(matched, isNotNull);
        expect(matched!.isKnownContact, isTrue);
        expect(connected, contains('Intro Friend'));
      },
    );

    test(
      'updateResolvedContact propagates to peers sharing resolved chat identity',
      () async {
        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '88888888-8888-8888-8888-888888888888',
            rssi: -55,
            payload: null,
          ),
        );
        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: '99999999-9999-9999-9999-999999999999',
            rssi: -60,
            payload: null,
          ),
        );
        await _settleAsync();

        final second = DeviceDeduplicationManager.getDevice(
          '99999999-9999-9999-9999-999999999999',
        )!;
        second.contactInfo = _enhancedContact(
          publicKey: 'other-key',
          chatKey: 'shared-chat',
          displayName: 'Second Contact',
        );

        final resolved = _enhancedContact(
          publicKey: 'resolved-key',
          chatKey: 'shared-chat',
          displayName: 'Resolved Contact',
        );

        DeviceDeduplicationManager.updateResolvedContact(
          '88888888-8888-8888-8888-888888888888',
          resolved,
        );

        final first = DeviceDeduplicationManager.getDevice(
          '88888888-8888-8888-8888-888888888888',
        )!;
        final updatedSecond = DeviceDeduplicationManager.getDevice(
          '99999999-9999-9999-9999-999999999999',
        )!;

        expect(first.isKnownContact, isTrue);
        expect(first.contactInfo?.displayName, 'Resolved Contact');
        expect(updatedSecond.isKnownContact, isTrue);
        expect(updatedSecond.contactInfo?.displayName, 'Resolved Contact');
      },
    );

    test(
      'stale cleanup honors configurable timeout and clears old entries',
      () async {
        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            rssi: -58,
            payload: null,
          ),
        );
        await _settleAsync();

        final tracked = DeviceDeduplicationManager.getDevice(
          'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        )!;
        tracked.lastSeen = DateTime.now().subtract(const Duration(minutes: 3));

        DeviceDeduplicationManager.removeStaleDevices();
        expect(DeviceDeduplicationManager.deviceCount, 0);

        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(
            uuid: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            rssi: -59,
            payload: null,
          ),
        );
        await _settleAsync();

        final second = DeviceDeduplicationManager.getDevice(
          'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        )!;
        second.lastSeen = DateTime.now().subtract(const Duration(seconds: 3));

        DeviceDeduplicationManager.setStaleTimeout(const Duration(seconds: 1));
        DeviceDeduplicationManager.removeStaleDevicesWithConfigurableTimeout();
        expect(DeviceDeduplicationManager.deviceCount, 0);
      },
    );
  });
}

Future<void> _settleAsync() async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

DiscoveredEventArgs _event({
  required String uuid,
  required int rssi,
  required Uint8List? payload,
}) {
  final advertisement = Advertisement(
    name: 'device-$uuid',
    manufacturerSpecificData: payload == null
        ? const <ManufacturerSpecificData>[]
        : <ManufacturerSpecificData>[
            ManufacturerSpecificData(id: 0x2E19, data: payload),
          ],
  );

  return DiscoveredEventArgs(
    _FakePeripheral(UUID.fromString(uuid)),
    rssi,
    advertisement,
  );
}

EnhancedContact _enhancedContact({
  required String publicKey,
  required String chatKey,
  required String displayName,
}) {
  final now = DateTime(2026, 1, 1, 10);
  return EnhancedContact(
    contact: Contact(
      publicKey: publicKey,
      persistentPublicKey: chatKey,
      currentEphemeralId: 'ephemeral-$publicKey',
      displayName: displayName,
      trustStatus: TrustStatus.verified,
      securityLevel: SecurityLevel.high,
      firstSeen: now,
      lastSeen: now,
      lastSecuritySync: now,
    ),
    lastSeenAgo: const Duration(minutes: 1),
    isRecentlyActive: true,
    interactionCount: 3,
    averageResponseTime: const Duration(seconds: 30),
    groupMemberships: const <String>[],
  );
}

class _FakePeripheral implements Peripheral {
  @override
  final UUID uuid;

  const _FakePeripheral(this.uuid);
}

class _FakeIntroHintRepository implements IIntroHintRepository {
  _FakeIntroHintRepository({
    required Map<String, EphemeralDiscoveryHint> scannedHints,
  }) : _scannedHints = Map<String, EphemeralDiscoveryHint>.from(scannedHints);

  final Map<String, EphemeralDiscoveryHint> _scannedHints;

  @override
  Future<void> cleanupExpiredHints() async {}

  @override
  Future<void> clearAll() async => _scannedHints.clear();

  @override
  Future<Map<String, EphemeralDiscoveryHint>> getScannedHints() async =>
      Map<String, EphemeralDiscoveryHint>.from(_scannedHints);

  @override
  Future<EphemeralDiscoveryHint?> getMostRecentActiveHint() async => null;

  @override
  Future<List<EphemeralDiscoveryHint>> getMyActiveHints() async =>
      _scannedHints.values.toList();

  @override
  Future<void> removeScannedHint(String key) async {
    _scannedHints.remove(key);
  }

  @override
  Future<void> saveMyActiveHint(EphemeralDiscoveryHint hint) async {}

  @override
  Future<void> saveScannedHint(String key, EphemeralDiscoveryHint hint) async {
    _scannedHints[key] = hint;
  }
}

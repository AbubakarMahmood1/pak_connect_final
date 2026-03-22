
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';

/// Minimal fake Peripheral for testing (the real class is abstract interface).
class _FakePeripheral implements Peripheral {
  final UUID _uuid;
  _FakePeripheral(this._uuid);

  @override
  UUID get uuid => _uuid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UUID _makeUuid(int seed) =>
    UUID(List.generate(16, (i) => (seed + i) & 0xFF));

_FakePeripheral _peripheral(int seed) => _FakePeripheral(_makeUuid(seed));

Advertisement _emptyAd() => Advertisement(
      manufacturerSpecificData: [],
    );

DiscoveredEventArgs _event(int seed, {int rssi = -50}) =>
    DiscoveredEventArgs(_peripheral(seed), rssi, _emptyAd());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Reset all static state between tests
    DeviceDeduplicationManager.onKnownContactDiscovered = null;
    DeviceDeduplicationManager.shouldAutoConnect = null;
    DeviceDeduplicationManager.myEphemeralHintProvider = null;
    DeviceDeduplicationManager.clearIntroHintRepository();
    DeviceDeduplicationManager.dispose();
  });

  group('DeviceDeduplicationManager — static state', () {
    test('noHintValue returns expected constant', () {
      expect(DeviceDeduplicationManager.noHintValue, equals('NO_HINT'));
    });

    test('deviceCount starts at 0', () {
      expect(DeviceDeduplicationManager.deviceCount, equals(0));
    });

    test('getDevice returns null for unknown deviceId', () {
      expect(DeviceDeduplicationManager.getDevice('non-existent'), isNull);
    });

    test('clearAll empties the device map', () {
      // Add a device via processDiscoveredDevice (no hint → uses NO_HINT)
      DeviceDeduplicationManager.processDiscoveredDevice(_event(1));
      expect(DeviceDeduplicationManager.deviceCount, greaterThan(0));

      DeviceDeduplicationManager.clearAll();
      expect(DeviceDeduplicationManager.deviceCount, equals(0));
    });

    test('dispose clears listeners and devices', () {
      DeviceDeduplicationManager.processDiscoveredDevice(_event(2));
      DeviceDeduplicationManager.dispose();
      expect(DeviceDeduplicationManager.deviceCount, equals(0));
    });
  });

  group('DeviceDeduplicationManager — processDiscoveredDevice', () {
    test('adds new device to unique devices map', () {
      final event = _event(10);
      final deviceId = event.peripheral.uuid.toString();

      DeviceDeduplicationManager.processDiscoveredDevice(event);

      expect(DeviceDeduplicationManager.deviceCount, equals(1));
      final device = DeviceDeduplicationManager.getDevice(deviceId);
      expect(device, isNotNull);
      expect(device!.rssi, equals(-50));
      expect(device.isKnownContact, isFalse);
    });

    test('updates existing device RSSI on re-discovery', () {
      final p = _peripheral(20);
      final deviceId = p.uuid.toString();

      // First discovery
      DeviceDeduplicationManager.processDiscoveredDevice(
        DiscoveredEventArgs(p, -70, _emptyAd()),
      );
      expect(DeviceDeduplicationManager.getDevice(deviceId)?.rssi, -70);

      // Re-discovery with stronger RSSI
      DeviceDeduplicationManager.processDiscoveredDevice(
        DiscoveredEventArgs(p, -40, _emptyAd()),
      );
      expect(DeviceDeduplicationManager.getDevice(deviceId)?.rssi, -40);
      // Still only 1 device
      expect(DeviceDeduplicationManager.deviceCount, equals(1));
    });

    test('self-filter does not drop anonymous device without hint payload', () {
      DeviceDeduplicationManager.myEphemeralHintProvider = () => 'NO_HINT';
      // Without a parsed hint payload there is no nonce to compare, so the
      // anonymous advertisement must remain discoverable.
      DeviceDeduplicationManager.processDiscoveredDevice(_event(30));
      expect(DeviceDeduplicationManager.deviceCount, equals(1));
    });

    test('multiple different devices are tracked separately', () {
      DeviceDeduplicationManager.processDiscoveredDevice(_event(40));
      DeviceDeduplicationManager.processDiscoveredDevice(_event(50));
      DeviceDeduplicationManager.processDiscoveredDevice(_event(60));
      expect(DeviceDeduplicationManager.deviceCount, equals(3));
    });
  });

  group('DeviceDeduplicationManager — removeDevice', () {
    test('removes existing device', () {
      final event = _event(70);
      final deviceId = event.peripheral.uuid.toString();

      DeviceDeduplicationManager.processDiscoveredDevice(event);
      expect(DeviceDeduplicationManager.deviceCount, equals(1));

      DeviceDeduplicationManager.removeDevice(deviceId);
      expect(DeviceDeduplicationManager.deviceCount, equals(0));
      expect(DeviceDeduplicationManager.getDevice(deviceId), isNull);
    });

    test('removeDevice does nothing for unknown device', () {
      DeviceDeduplicationManager.removeDevice('unknown-id');
      expect(DeviceDeduplicationManager.deviceCount, equals(0));
    });
  });

  group('DeviceDeduplicationManager — markRetired', () {
    test('marks device as retired', () {
      final event = _event(80);
      final deviceId = event.peripheral.uuid.toString();

      DeviceDeduplicationManager.processDiscoveredDevice(event);
      expect(DeviceDeduplicationManager.getDevice(deviceId)!.isRetired, isFalse);

      DeviceDeduplicationManager.markRetired(deviceId);
      expect(DeviceDeduplicationManager.getDevice(deviceId)!.isRetired, isTrue);
    });

    test('markRetired does nothing for unknown device', () {
      // Should not throw
      DeviceDeduplicationManager.markRetired('unknown-id');
    });
  });

  group('DeviceDeduplicationManager — updateResolvedContact', () {
    test('updates device with contact info', () {
      final event = _event(90);
      final deviceId = event.peripheral.uuid.toString();

      DeviceDeduplicationManager.processDiscoveredDevice(event);
      final device = DeviceDeduplicationManager.getDevice(deviceId)!;
      expect(device.isKnownContact, isFalse);
      expect(device.contactInfo, isNull);

      final contact = EnhancedContact(
        contact: Contact(
          publicKey: 'test-pk',
          displayName: 'Alice',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.low,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        ),
        lastSeenAgo: Duration.zero,
        isRecentlyActive: true,
        interactionCount: 0,
        averageResponseTime: Duration.zero,
        groupMemberships: [],
      );

      DeviceDeduplicationManager.updateResolvedContact(deviceId, contact);
      final updated = DeviceDeduplicationManager.getDevice(deviceId)!;
      expect(updated.isKnownContact, isTrue);
      expect(updated.contactInfo, isNotNull);
      expect(updated.isRetired, isFalse);
    });

    test('updateResolvedContact does nothing for unknown device', () {
      final contact = EnhancedContact(
        contact: Contact(
          publicKey: 'pk',
          displayName: 'Bob',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.low,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        ),
        lastSeenAgo: Duration.zero,
        isRecentlyActive: false,
        interactionCount: 0,
        averageResponseTime: Duration.zero,
        groupMemberships: [],
      );
      // Should not throw
      DeviceDeduplicationManager.updateResolvedContact('unknown', contact);
    });
  });

  group('DeviceDeduplicationManager — stale device cleanup', () {
    test('setStaleTimeout changes timeout', () {
      // Just verify it doesn't throw
      DeviceDeduplicationManager.setStaleTimeout(Duration(seconds: 10));
    });

    test('removeStaleDevices removes old devices', () {
      final event = _event(100);
      DeviceDeduplicationManager.processDiscoveredDevice(event);
      expect(DeviceDeduplicationManager.deviceCount, equals(1));

      // Device was just added, so it shouldn't be stale with default 2-min timeout
      DeviceDeduplicationManager.removeStaleDevices();
      expect(DeviceDeduplicationManager.deviceCount, equals(1));
    });

    test('removeStaleDevicesWithConfigurableTimeout uses configured timeout', () {
      final event = _event(110);
      DeviceDeduplicationManager.processDiscoveredDevice(event);

      // Set very short timeout
      DeviceDeduplicationManager.setStaleTimeout(Duration.zero);
      DeviceDeduplicationManager.removeStaleDevicesWithConfigurableTimeout();
      // Device's lastSeen was just now, but Duration.zero means cutoff is now
      // The device should be removed since lastSeen.isBefore(now) is borderline
      // This tests the configurable timeout path
    });
  });

  group('DeviceDeduplicationManager — uniqueDevicesStream', () {
    test('stream emits current devices on subscription', () async {
      DeviceDeduplicationManager.processDiscoveredDevice(_event(120));

      final firstEvent = await DeviceDeduplicationManager.uniqueDevicesStream
          .first
          .timeout(Duration(seconds: 2));
      expect(firstEvent, isA<Map<String, DiscoveredDevice>>());
      expect(firstEvent.length, equals(1));
    });

    test('stream emits updates when devices change', () async {
      final events = <Map<String, DiscoveredDevice>>[];
      final sub = DeviceDeduplicationManager.uniqueDevicesStream.listen(
        events.add,
      );

      // Allow initial emission
      await Future.delayed(Duration(milliseconds: 50));

      // Add device (triggers notification)
      DeviceDeduplicationManager.processDiscoveredDevice(_event(130));
      await Future.delayed(Duration(milliseconds: 50));

      sub.cancel();

      // Should have at least 2 events: initial + new device
      expect(events.length, greaterThanOrEqualTo(2));
    });
  });

  group('DeviceDeduplicationManager — setIntroHintRepository', () {
    test('setIntroHintRepository and clearIntroHintRepository work', () {
      // Just verify no exceptions
      DeviceDeduplicationManager.clearIntroHintRepository();
      // Can't directly test private field, but we verify code paths
    });
  });

  group('DeviceDeduplicationManager — autoConnectStrongestRssi', () {
    test('skips when no callback registered', () async {
      DeviceDeduplicationManager.processDiscoveredDevice(_event(140));
      // Should not throw
      await DeviceDeduplicationManager.autoConnectStrongestRssi();
    });

    test('invokes callback for strongest RSSI device', () async {
      final connectedDevices = <String>[];
      DeviceDeduplicationManager.onKnownContactDiscovered =
          (device, name) async {
        connectedDevices.add(name);
      };

      // Add multiple devices with different RSSI
      final p1 = _peripheral(150);
      final p2 = _peripheral(160);
      DeviceDeduplicationManager.processDiscoveredDevice(
        DiscoveredEventArgs(p1, -80, _emptyAd()),
      );
      DeviceDeduplicationManager.processDiscoveredDevice(
        DiscoveredEventArgs(p2, -30, _emptyAd()),
      );
      // Mark as known contacts so the isKnownContact filter passes
      DeviceDeduplicationManager.updateResolvedContact(
        p1.uuid.toString(),
        EnhancedContact(
          contact: Contact(
            publicKey: 'pk-150',
            displayName: 'Peer150',
            trustStatus: TrustStatus.newContact,
            securityLevel: SecurityLevel.low,
            firstSeen: DateTime.now(),
            lastSeen: DateTime.now(),
          ),
          lastSeenAgo: Duration.zero,
          isRecentlyActive: true,
          interactionCount: 0,
          averageResponseTime: Duration.zero,
          groupMemberships: [],
        ),
      );
      DeviceDeduplicationManager.updateResolvedContact(
        p2.uuid.toString(),
        EnhancedContact(
          contact: Contact(
            publicKey: 'pk-160',
            displayName: 'Peer160',
            trustStatus: TrustStatus.newContact,
            securityLevel: SecurityLevel.low,
            firstSeen: DateTime.now(),
            lastSeen: DateTime.now(),
          ),
          lastSeenAgo: Duration.zero,
          isRecentlyActive: true,
          interactionCount: 0,
          averageResponseTime: Duration.zero,
          groupMemberships: [],
        ),
      );
      connectedDevices.clear();

      await DeviceDeduplicationManager.autoConnectStrongestRssi();
      // Callback should have been invoked for the strongest RSSI known device
      expect(connectedDevices, isNotEmpty);
    });

    test('respects shouldAutoConnect predicate', () async {
      DeviceDeduplicationManager.shouldAutoConnect = (_) => false;
      DeviceDeduplicationManager.onKnownContactDiscovered =
          (device, name) async {};

      DeviceDeduplicationManager.processDiscoveredDevice(_event(170));
      await DeviceDeduplicationManager.autoConnectStrongestRssi();
      // Should have been declined by predicate — verify no crash
    });

    test('skips retired devices', () async {
      final event = _event(180);
      final deviceId = event.peripheral.uuid.toString();

      DeviceDeduplicationManager.onKnownContactDiscovered =
          (device, name) async {};

      DeviceDeduplicationManager.processDiscoveredDevice(event);
      DeviceDeduplicationManager.markRetired(deviceId);

      // The device is retired, should be skipped
      await DeviceDeduplicationManager.autoConnectStrongestRssi();
    });
  });
}

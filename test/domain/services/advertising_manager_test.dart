import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/constants/ble_constants.dart';
import 'package:pak_connect/domain/entities/ephemeral_discovery_hint.dart';
import 'package:pak_connect/domain/interfaces/i_intro_hint_repository.dart';
import 'package:pak_connect/domain/services/advertising_manager.dart';
import 'package:pak_connect/domain/utils/hint_advertisement_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/services/ble_advertising_service_test.mocks.dart';

class _FakeIntroHintRepository implements IIntroHintRepository {
  EphemeralDiscoveryHint? mostRecentActiveHint;

  @override
  Future<void> cleanupExpiredHints() async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<List<EphemeralDiscoveryHint>> getMyActiveHints() async {
    final hint = mostRecentActiveHint;
    return hint == null
        ? <EphemeralDiscoveryHint>[]
        : <EphemeralDiscoveryHint>[hint];
  }

  @override
  Future<EphemeralDiscoveryHint?> getMostRecentActiveHint() async {
    return mostRecentActiveHint;
  }

  @override
  Future<Map<String, EphemeralDiscoveryHint>> getScannedHints() async =>
      <String, EphemeralDiscoveryHint>{};

  @override
  Future<void> removeScannedHint(String key) async {}

  @override
  Future<void> saveMyActiveHint(EphemeralDiscoveryHint hint) async {
    mostRecentActiveHint = hint;
  }

  @override
  Future<void> saveScannedHint(String key, EphemeralDiscoveryHint hint) async {}
}

void main() {
  group('AdvertisingManager', () {
    late MockPeripheralInitializer peripheralInitializer;
    late MockPeripheralManager peripheralManager;
    late _FakeIntroHintRepository introHintRepo;
    late AdvertisingManager manager;

    setUp(() {
      resetMockitoState();
      SharedPreferences.setMockInitialValues(<String, Object>{});

      peripheralInitializer = MockPeripheralInitializer();
      peripheralManager = MockPeripheralManager();
      introHintRepo = _FakeIntroHintRepository();

      when(
        peripheralInitializer.safelyStartAdvertising(
          any,
          timeout: anyNamed('timeout'),
          skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
        ),
      ).thenAnswer((_) async => true);
      when(peripheralManager.stopAdvertising()).thenAnswer((_) async {});

      manager = AdvertisingManager(
        peripheralInitializer: peripheralInitializer,
        peripheralManager: peripheralManager,
        introHintRepo: introHintRepo,
        sessionKeyProvider: () => 'A1B2C3D4',
      );
    });

    test(
      'startAdvertising returns false when manager is not started',
      () async {
        final result = await manager.startAdvertising(
          myPublicKey: 'my-public-key',
        );

        expect(result, isFalse);
        verifyNever(
          peripheralInitializer.safelyStartAdvertising(
            any,
            timeout: anyNamed('timeout'),
            skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
          ),
        );
      },
    );

    test(
      'startAdvertising succeeds and emits UUID-only advert when hints disabled',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'show_online_status': false,
          'hint_broadcast_enabled': false,
        });
        manager.start();

        final success = await manager.startAdvertising(
          myPublicKey: 'my-public-key',
        );

        expect(success, isTrue);
        expect(manager.isAdvertising, isTrue);

        final invocation = verify(
          peripheralInitializer.safelyStartAdvertising(
            captureAny,
            timeout: anyNamed('timeout'),
            skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
          ),
        );
        invocation.called(1);
        final captured = invocation.captured.single as Advertisement;
        expect(captured.serviceUUIDs, contains(BLEConstants.serviceUUID));
        expect(captured.manufacturerSpecificData, isEmpty);
      },
    );

    test(
      'second startAdvertising call is skipped when already advertising',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'show_online_status': false,
          'hint_broadcast_enabled': false,
        });
        manager.start();

        expect(
          await manager.startAdvertising(myPublicKey: 'my-public-key'),
          isTrue,
        );
        expect(
          await manager.startAdvertising(myPublicKey: 'my-public-key'),
          isTrue,
        );

        verify(
          peripheralInitializer.safelyStartAdvertising(
            any,
            timeout: anyNamed('timeout'),
            skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
          ),
        ).called(1);
      },
    );

    test(
      'startAdvertising includes persistent blinded hint when enabled',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'show_online_status': true,
          'hint_broadcast_enabled': true,
        });
        manager.start();

        final success = await manager.startAdvertising(
          myPublicKey: 'my-public-key',
        );

        expect(success, isTrue);
        final invocation = verify(
          peripheralInitializer.safelyStartAdvertising(
            captureAny,
            timeout: anyNamed('timeout'),
            skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
          ),
        );
        final advertisement = invocation.captured.single as Advertisement;
        expect(advertisement.manufacturerSpecificData, hasLength(1));

        final packed = advertisement.manufacturerSpecificData.single.data;
        final parsed = HintAdvertisementService.parseAdvertisement(packed);
        expect(parsed, isNotNull);
        expect(parsed!.isIntro, isFalse);
      },
    );

    test(
      'startAdvertising uses intro hint payload when active intro exists',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'show_online_status': true,
          'hint_broadcast_enabled': true,
        });
        introHintRepo.mostRecentActiveHint = EphemeralDiscoveryHint(
          hintBytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
          createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          displayName: 'Intro',
        );
        manager.start();

        await manager.startAdvertising(myPublicKey: 'my-public-key');

        final invocation = verify(
          peripheralInitializer.safelyStartAdvertising(
            captureAny,
            timeout: anyNamed('timeout'),
            skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
          ),
        );
        final advertisement = invocation.captured.single as Advertisement;
        final packed = advertisement.manufacturerSpecificData.single.data;
        final parsed = HintAdvertisementService.parseAdvertisement(packed);
        expect(parsed, isNotNull);
        expect(parsed!.isIntro, isTrue);
      },
    );

    test(
      'startAdvertising gracefully falls back when session key is missing',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'show_online_status': true,
          'hint_broadcast_enabled': true,
        });
        final noSessionManager = AdvertisingManager(
          peripheralInitializer: peripheralInitializer,
          peripheralManager: peripheralManager,
          introHintRepo: introHintRepo,
          sessionKeyProvider: () => null,
        );
        noSessionManager.start();

        final success = await noSessionManager.startAdvertising(
          myPublicKey: 'my-public-key',
        );

        expect(success, isTrue);
        final invocation = verify(
          peripheralInitializer.safelyStartAdvertising(
            captureAny,
            timeout: anyNamed('timeout'),
            skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
          ),
        );
        final advertisement = invocation.captured.single as Advertisement;
        expect(advertisement.manufacturerSpecificData, isEmpty);
      },
    );

    test('startAdvertising returns false when initializer fails', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'show_online_status': false,
        'hint_broadcast_enabled': false,
      });
      when(
        peripheralInitializer.safelyStartAdvertising(
          any,
          timeout: anyNamed('timeout'),
          skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
        ),
      ).thenAnswer((_) async => false);
      manager.start();

      final success = await manager.startAdvertising(
        myPublicKey: 'my-public-key',
      );

      expect(success, isFalse);
      expect(manager.isAdvertising, isFalse);
    });

    test(
      'stopAdvertising and stop handle both active and inactive states',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'show_online_status': false,
          'hint_broadcast_enabled': false,
        });
        manager.start();
        await manager.startAdvertising(myPublicKey: 'my-public-key');

        await manager.stopAdvertising();
        expect(manager.isAdvertising, isFalse);
        verify(peripheralManager.stopAdvertising()).called(1);

        await manager.stopAdvertising();
        await manager.stop();
        await manager.stop();
      },
    );

    test(
      'restartAdvertising and refreshAdvertising re-run start path',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'show_online_status': false,
          'hint_broadcast_enabled': false,
        });
        manager.start();
        await manager.startAdvertising(myPublicKey: 'my-public-key');

        await manager.restartAdvertising(myPublicKey: 'my-public-key');
        await manager.refreshAdvertising(myPublicKey: 'my-public-key');

        verify(
          peripheralInitializer.safelyStartAdvertising(
            any,
            timeout: anyNamed('timeout'),
            skipIfAlreadyAdvertising: false,
          ),
        ).called(greaterThanOrEqualTo(2));
      },
    );
  });
}

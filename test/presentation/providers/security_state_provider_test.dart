import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/security_state.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/security_state_provider.dart';

class _FakeContactRepository extends Fake implements IContactRepository {
  final Map<String, Contact?> contactsByAnyId = <String, Contact?>{};
  final Map<String, SecurityLevel> securityLevelById =
      <String, SecurityLevel>{};
  int contactLookupCalls = 0;
  int securityLevelCalls = 0;

  @override
  Future<Contact?> getContactByAnyId(String identifier) async {
    contactLookupCalls++;
    return contactsByAnyId[identifier];
  }

  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async {
    securityLevelCalls++;
    return securityLevelById[publicKey] ?? SecurityLevel.low;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnectionService extends Fake implements IConnectionService {
  _FakeConnectionService({
    this.sessionId,
    this.persistentKey,
    this.ephemeralId,
    this.stateManager,
  });

  String? sessionId;
  String? persistentKey;
  String? ephemeralId;
  dynamic stateManager;

  @override
  String? get currentSessionId => sessionId;

  @override
  String? get theirPersistentKey => persistentKey;

  @override
  String? get theirPersistentPublicKey => persistentKey;

  @override
  String? get theirEphemeralId => ephemeralId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnectionStateManager {
  _FakeConnectionStateManager(this.theyHaveUsAsContact);

  final bool theyHaveUsAsContact;
}

class _FakeBleRuntimeNotifier extends BleRuntimeNotifier {
  _FakeBleRuntimeNotifier(this.runtimeState);

  final BleRuntimeState runtimeState;

  @override
  Future<BleRuntimeState> build() async => runtimeState;
}

Contact _contact({
  required String key,
  required String displayName,
  required TrustStatus trustStatus,
  required SecurityLevel securityLevel,
}) {
  return Contact(
    publicKey: key,
    persistentPublicKey: key,
    currentEphemeralId: null,
    displayName: displayName,
    trustStatus: trustStatus,
    securityLevel: securityLevel,
    firstSeen: DateTime(2026, 1, 1),
    lastSeen: DateTime(2026, 1, 2),
  );
}

BleRuntimeState _runtimeState(ConnectionInfo info) {
  return BleRuntimeState(
    connectionInfo: info,
    discoveredDevices: const [],
    discoveryData: const {},
    lastSpyModeEvent: null,
    lastIdentityReveal: null,
    bluetoothState: null,
    bluetoothMessage: null,
    isBluetoothReady: true,
  );
}

Future<void> _primeBleRuntime(ProviderContainer container) async {
  await container.read(bleRuntimeProvider.future);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    clearSecurityStateCache();
    await getIt.reset();
  });

  tearDown(() async {
    clearSecurityStateCache();
    await getIt.reset();
  });

  group('securityStateProvider helpers', () {
    test('helper providers map security state to convenience values', () async {
      const key = 'contact-key';
      final container = ProviderContainer(
        overrides: [
          securityStateProvider.overrideWith(
            (ref, _) async => SecurityState.paired(
              otherUserName: 'Peer',
              otherPublicKey: key,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(securityStateProvider(key).future);
      expect(container.read(canSendMessagesProvider(key)), isTrue);
      expect(
        container.read(recommendedActionProvider(key)),
        'Tap + to add contact for ECDH encryption',
      );
      expect(
        container.read(encryptionDescriptionProvider(key)),
        'Paired + Global Encryption',
      );
    });

    test('cache utility functions are safe to call repeatedly', () {
      expect(clearSecurityStateCache, returnsNormally);
      expect(() => invalidateSecurityStateCache('key-a'), returnsNormally);
      expect(clearSecurityStateCache, returnsNormally);
    });

    test(
      'repository mode computes needs-pairing with repo_ key trimming',
      () async {
        final repository = _FakeContactRepository();
        getIt.registerSingleton<IContactRepository>(repository);
        final connectionService = _FakeConnectionService(
          sessionId: 'live-session',
          persistentKey: 'live-persistent',
          ephemeralId: 'live-ephemeral',
        );

        final container = ProviderContainer(
          overrides: [
            connectionServiceProvider.overrideWithValue(connectionService),
            bleRuntimeProvider.overrideWith(
              () => _FakeBleRuntimeNotifier(
                _runtimeState(
                  const ConnectionInfo(isConnected: false, isReady: false),
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await _primeBleRuntime(container);
        final runtime = container.read(bleRuntimeProvider).requireValue;
        expect(runtime.connectionInfo.isReady, isFalse);

        final state = await container.read(
          securityStateProvider('repo_peer').future,
        );
        expect(state.status, SecurityStatus.needsPairing);
        expect(state.otherPublicKey, 'peer');
        expect(repository.contactLookupCalls, 1);
      },
    );

    test(
      'live mode computes verified and asymmetric relationship states',
      () async {
        final repository = _FakeContactRepository()
          ..contactsByAnyId['session-verified'] = _contact(
            key: 'session-verified',
            displayName: 'Verified',
            trustStatus: TrustStatus.verified,
            securityLevel: SecurityLevel.high,
          )
          ..securityLevelById['session-verified'] = SecurityLevel.high
          ..securityLevelById['session-asymmetric'] = SecurityLevel.low;
        getIt.registerSingleton<IContactRepository>(repository);

        final verifiedConnection = _FakeConnectionService(
          sessionId: 'session-verified',
          persistentKey: 'session-verified',
          ephemeralId: 'session-verified',
          stateManager: _FakeConnectionStateManager(true),
        );
        final verifiedContainer = ProviderContainer(
          overrides: [
            connectionServiceProvider.overrideWithValue(verifiedConnection),
            bleRuntimeProvider.overrideWith(
              () => _FakeBleRuntimeNotifier(
                _runtimeState(
                  const ConnectionInfo(
                    isConnected: true,
                    isReady: true,
                    otherUserName: 'Verified User',
                  ),
                ),
              ),
            ),
          ],
        );
        addTearDown(verifiedContainer.dispose);

        await _primeBleRuntime(verifiedContainer);
        final verified = await verifiedContainer.read(
          securityStateProvider('session-verified').future,
        );
        expect(verified.status, SecurityStatus.verifiedContact);
        expect(verified.otherUserName, 'Verified User');

        final asymmetricConnection = _FakeConnectionService(
          sessionId: 'session-asymmetric',
          persistentKey: 'session-asymmetric',
          ephemeralId: 'session-asymmetric',
          stateManager: _FakeConnectionStateManager(true),
        );
        final asymmetricContainer = ProviderContainer(
          overrides: [
            connectionServiceProvider.overrideWithValue(asymmetricConnection),
            bleRuntimeProvider.overrideWith(
              () => _FakeBleRuntimeNotifier(
                _runtimeState(
                  const ConnectionInfo(
                    isConnected: true,
                    isReady: true,
                    otherUserName: 'Asymmetric User',
                  ),
                ),
              ),
            ),
          ],
        );
        addTearDown(asymmetricContainer.dispose);

        await _primeBleRuntime(asymmetricContainer);
        final asymmetric = await asymmetricContainer.read(
          securityStateProvider('session-asymmetric').future,
        );
        expect(asymmetric.status, SecurityStatus.asymmetricContact);
        expect(asymmetric.otherUserName, 'Asymmetric User');
      },
    );

    test(
      'live mode falls back safely when stateManager is unavailable',
      () async {
        final repository = _FakeContactRepository()
          ..securityLevelById['session-unilateral'] = SecurityLevel.low;
        getIt.registerSingleton<IContactRepository>(repository);
        final connectionService = _FakeConnectionService(
          sessionId: 'session-unilateral',
          persistentKey: 'session-unilateral',
          ephemeralId: 'session-unilateral',
          stateManager: null,
        );

        final container = ProviderContainer(
          overrides: [
            connectionServiceProvider.overrideWithValue(connectionService),
            bleRuntimeProvider.overrideWith(
              () => _FakeBleRuntimeNotifier(
                _runtimeState(
                  const ConnectionInfo(
                    isConnected: true,
                    isReady: true,
                    otherUserName: 'Peer',
                  ),
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await _primeBleRuntime(container);
        final state = await container.read(
          securityStateProvider('session-unilateral').future,
        );
        expect(state.status, SecurityStatus.needsPairing);
      },
    );

    test('cache survives provider recreation and can be invalidated', () async {
      final repository = _FakeContactRepository()
        ..contactsByAnyId['cache-key'] = _contact(
          key: 'cache-key',
          displayName: 'Cached',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.medium,
        );
      getIt.registerSingleton<IContactRepository>(repository);
      final connectionService = _FakeConnectionService(
        sessionId: 'another-live-key',
        persistentKey: 'another-live-key',
        ephemeralId: 'another-live-key',
      );
      final runtimeState = _runtimeState(
        const ConnectionInfo(isConnected: false, isReady: false),
      );

      final firstContainer = ProviderContainer(
        overrides: [
          connectionServiceProvider.overrideWithValue(connectionService),
          bleRuntimeProvider.overrideWith(
            () => _FakeBleRuntimeNotifier(runtimeState),
          ),
        ],
      );
      addTearDown(firstContainer.dispose);
      await _primeBleRuntime(firstContainer);
      final first = await firstContainer.read(
        securityStateProvider('cache-key').future,
      );
      expect(first.status, SecurityStatus.paired);
      expect(repository.contactLookupCalls, 1);

      final secondContainer = ProviderContainer(
        overrides: [
          connectionServiceProvider.overrideWithValue(connectionService),
          bleRuntimeProvider.overrideWith(
            () => _FakeBleRuntimeNotifier(runtimeState),
          ),
        ],
      );
      addTearDown(secondContainer.dispose);
      await _primeBleRuntime(secondContainer);
      final second = await secondContainer.read(
        securityStateProvider('cache-key').future,
      );
      expect(second.status, SecurityStatus.paired);
      expect(repository.contactLookupCalls, 1);

      invalidateSecurityStateCache('cache-key');
      final thirdContainer = ProviderContainer(
        overrides: [
          connectionServiceProvider.overrideWithValue(connectionService),
          bleRuntimeProvider.overrideWith(
            () => _FakeBleRuntimeNotifier(runtimeState),
          ),
        ],
      );
      addTearDown(thirdContainer.dispose);
      await _primeBleRuntime(thirdContainer);
      final third = await thirdContainer.read(
        securityStateProvider('cache-key').future,
      );
      expect(third.status, SecurityStatus.paired);
      expect(repository.contactLookupCalls, 2);
    });
  });
}

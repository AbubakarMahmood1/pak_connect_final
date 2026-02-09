import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/core/services/simple_crypto.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import '../../test_helpers/test_setup.dart';

// Mock secure storage for testing
class MockSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _storage[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 🏗️ Initialize test environment (Phase 3: sets up DI container)
    await TestSetup.initializeTestEnvironment(dbLabel: 'handshake_coordinator');

    // Initialize SecurityManager with mock storage
    await SecurityManager.instance.initialize(
      secureStorage: MockSecureStorage(),
    );
  });

  tearDownAll(() {
    SecurityManager.instance.shutdown();
  });

  group('HandshakeCoordinator with Noise Protocol', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      SimpleCrypto.resetDeprecatedWrapperUsageCounts();
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
      final wrapperUsage = SimpleCrypto.getDeprecatedWrapperUsageCounts();
      expect(
        wrapperUsage['total'],
        equals(0),
        reason:
            'Deprecated SimpleCrypto wrappers were used unexpectedly: $wrapperUsage',
      );
    });

    test('ConnectionPhase enum includes Noise phases', () {
      expect(
        ConnectionPhase.values.contains(ConnectionPhase.noiseHandshake1Sent),
        isTrue,
      );
      expect(
        ConnectionPhase.values.contains(ConnectionPhase.noiseHandshake2Sent),
        isTrue,
      );
      expect(
        ConnectionPhase.values.contains(ConnectionPhase.noiseHandshakeComplete),
        isTrue,
      );
    });

    test('message type enum includes Noise types', () {
      expect(
        ProtocolMessageType.values.contains(
          ProtocolMessageType.noiseHandshake1,
        ),
        isTrue,
      );
      expect(
        ProtocolMessageType.values.contains(
          ProtocolMessageType.noiseHandshake2,
        ),
        isTrue,
      );
      expect(
        ProtocolMessageType.values.contains(
          ProtocolMessageType.noiseHandshake3,
        ),
        isTrue,
      );
    });

    test('Noise message factory methods work correctly', () {
      final testData = Uint8List.fromList([1, 2, 3, 4, 5]);

      final msg1 = ProtocolMessage.noiseHandshake1(
        handshakeData: testData,
        peerId: 'test_peer',
      );

      expect(msg1.type, equals(ProtocolMessageType.noiseHandshake1));
      expect(msg1.noiseHandshakeData, equals(testData));
      expect(msg1.noiseHandshakePeerId, equals('test_peer'));

      final msg2 = ProtocolMessage.noiseHandshake2(
        handshakeData: testData,
        peerId: 'test_peer',
      );

      expect(msg2.type, equals(ProtocolMessageType.noiseHandshake2));
      expect(msg2.noiseHandshakeData, equals(testData));

      final msg3 = ProtocolMessage.noiseHandshake3(
        handshakeData: testData,
        peerId: 'test_peer',
      );

      expect(msg3.type, equals(ProtocolMessageType.noiseHandshake3));
      expect(msg3.noiseHandshakeData, equals(testData));
    });

    test('Noise message serialization preserves data', () {
      final testData = Uint8List.fromList(List.generate(32, (i) => i));

      final msg = ProtocolMessage.noiseHandshake1(
        handshakeData: testData,
        peerId: 'test123',
      );

      // Serialize to bytes
      final bytes = msg.toBytes();
      expect(bytes, isNotEmpty);

      // Deserialize
      final decoded = ProtocolMessage.fromBytes(bytes);
      expect(decoded.type, equals(ProtocolMessageType.noiseHandshake1));
      expect(decoded.noiseHandshakeData, equals(testData));
      expect(decoded.noiseHandshakePeerId, equals('test123'));
    });

    test('HandshakeCoordinator initializes with correct state', () async {
      final messages = <ProtocolMessage>[];
      final completer = Completer<void>();

      final coordinator = HandshakeCoordinator(
        myEphemeralId: 'test_eph',
        myPublicKey: 'test_persistent',
        myDisplayName: 'Test Device',
        sendMessage: (msg) async {
          messages.add(msg);
        },
        onHandshakeComplete: (ephId, name, noiseKey) async {
          completer.complete();
        },
      );

      expect(coordinator.currentPhase, equals(ConnectionPhase.bleConnected));
      expect(coordinator.isComplete, isFalse);
      expect(coordinator.hasFailed, isFalse);
      expect(coordinator.theirNoisePublicKey, isNull);

      coordinator.dispose();
    });

    test('HandshakeCoordinator starts handshake', () async {
      final messages = <ProtocolMessage>[];

      final coordinator = HandshakeCoordinator(
        myEphemeralId: 'test_eph',
        myPublicKey: 'test_persistent',
        myDisplayName: 'Test Device',
        sendMessage: (msg) async {
          messages.add(msg);
        },
        onHandshakeComplete: (ephId, name, noiseKey) async {},
      );

      await coordinator.startHandshake();

      // Should send connectionReady message
      expect(messages.length, equals(1));
      expect(messages[0].type, equals(ProtocolMessageType.connectionReady));
      expect(coordinator.currentPhase, equals(ConnectionPhase.readySent));

      coordinator.dispose();
    });

    test('SecurityManager Noise service is available', () {
      final noiseService = SecurityManager.instance.noiseService;
      expect(noiseService, isNotNull);
      expect(noiseService!.getStaticPublicKeyData().length, equals(32));
    });

    test('Noise handshake messages have expected sizes', () async {
      final noiseService = SecurityManager.instance.noiseService!;

      // Message 1: -> e (ephemeral key)
      final msg1 = await noiseService.initiateHandshake('peer1');
      expect(msg1, isNotNull);
      expect(msg1!.length, equals(32));

      // Note: Full handshake testing requires two separate Noise service instances
      // which isn't possible in a single-process test environment
      // This is tested in real-world multi-device scenarios
    });
  });
}

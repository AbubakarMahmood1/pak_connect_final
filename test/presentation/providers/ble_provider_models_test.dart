import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/presentation/providers/ble_provider_models.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

void main() {
  group('EnhancedConnectionInfo', () {
    test('combines BLE and mesh readiness and status text', () {
      final ready = EnhancedConnectionInfo(
        bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
          ConnectionInfo(
            isConnected: true,
            isReady: true,
            statusMessage: 'Connected',
          ),
        ),
        meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(true)),
      );

      final notReady = EnhancedConnectionInfo(
        bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
          ConnectionInfo(
            isConnected: true,
            isReady: true,
            statusMessage: 'Connected',
          ),
        ),
        meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(false)),
      );

      expect(ready.isFullyConnected, isTrue);
      expect(ready.statusMessage, 'Connected + Mesh Ready');
      expect(ready.canUseRelay, isTrue);

      expect(notReady.isFullyConnected, isFalse);
      expect(notReady.statusMessage, 'Connected');
      expect(notReady.canUseRelay, isFalse);
    });
  });

  group('ConnectivityStatus', () {
    test('calculates health, description, and active capabilities', () {
      final status = ConnectivityStatus(
        bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
          ConnectionInfo(isConnected: true, isReady: true),
        ),
        meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(true)),
        bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
          BluetoothLowEnergyState.poweredOn,
        ),
      );
      final degraded = ConnectivityStatus(
        bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
          ConnectionInfo(isConnected: false, isReady: false),
        ),
        meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(false)),
        bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
          BluetoothLowEnergyState.poweredOff,
        ),
      );

      expect(status.connectionHealth, closeTo(1.0, 0.0001));
      expect(status.statusDescription, 'Excellent');
      expect(status.activeCapabilities, containsAll(<String>[
        'Bluetooth',
        'Direct Messaging',
        'Mesh Relay',
      ]));

      expect(degraded.connectionHealth, 0.0);
      expect(degraded.statusDescription, 'Disconnected');
      expect(degraded.activeCapabilities, isEmpty);
    });
  });

  group('MeshEnabledBLEOperations', () {
    test('uses direct message path for connected peer and central role', () async {
      final connection = MockConnectionService()
        ..currentSessionId = 'peer'
        ..isPeripheralMode = false;
      connection.emitConnectionInfo(
        const ConnectionInfo(isConnected: true, isReady: true),
      );
      final meshService = _FakeMeshService();

      final operations = MeshEnabledBLEOperations(
        connectionService: connection,
        meshController: MeshNetworkingController(meshService),
        connectivityStatus: ConnectivityStatus(
          bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
            ConnectionInfo(isConnected: true, isReady: true),
          ),
          meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(true)),
          bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
            BluetoothLowEnergyState.poweredOn,
          ),
        ),
      );

      final result = await operations.sendMessage(
        content: 'hello',
        recipientPublicKey: 'peer',
      );

      expect(result.success, isTrue);
      expect(result.method, MessageSendMethod.direct);
      expect(connection.sentMessages, isNotEmpty);
    });

    test('uses peripheral direct path when in peripheral mode', () async {
      final connection = MockConnectionService()
        ..currentSessionId = 'peer'
        ..isPeripheralMode = true;
      final operations = MeshEnabledBLEOperations(
        connectionService: connection,
        meshController: MeshNetworkingController(_FakeMeshService()),
        connectivityStatus: ConnectivityStatus(
          bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
            ConnectionInfo(isConnected: true, isReady: true),
          ),
          meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(true)),
          bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
            BluetoothLowEnergyState.poweredOn,
          ),
        ),
      );

      final result = await operations.sendMessage(
        content: 'hi',
        recipientPublicKey: 'peer',
      );

      expect(result.success, isTrue);
      expect(result.method, MessageSendMethod.direct);
      expect(connection.sentPeripheralMessages, isNotEmpty);
    });

    test('falls back to mesh path and maps mesh result fields', () async {
      final connection = MockConnectionService()
        ..currentSessionId = 'someone-else'
        ..isPeripheralMode = false;
      final meshService = _FakeMeshService()
        ..nextResult = MeshSendResult.relay('m-1', 'hop-1');
      final operations = MeshEnabledBLEOperations(
        connectionService: connection,
        meshController: MeshNetworkingController(meshService),
        connectivityStatus: ConnectivityStatus(
          bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
            ConnectionInfo(isConnected: true, isReady: true),
          ),
          meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(true)),
          bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
            BluetoothLowEnergyState.poweredOn,
          ),
        ),
      );

      final result = await operations.sendMessage(
        content: 'mesh payload',
        recipientPublicKey: 'peer',
        preferDirect: true,
      );

      expect(result.success, isTrue);
      expect(result.method, MessageSendMethod.mesh);
      expect(result.messageId, 'm-1');
      expect(result.nextHop, 'hop-1');

      final capabilities = operations.sendCapabilities;
      expect(capabilities.canSendDirect, isTrue);
      expect(capabilities.canSendMesh, isTrue);
      expect(capabilities.hasAnyMethod, isTrue);
      expect(capabilities.preferredMethod, MessageSendMethod.direct);
      expect(
        capabilities.availableMethods,
        containsAll(<MessageSendMethod>[MessageSendMethod.direct, MessageSendMethod.mesh]),
      );
    });

    test('returns failed result when direct send throws', () async {
      final connection = _ThrowingConnectionService()
        ..currentSessionId = 'peer'
        ..isPeripheralMode = false;
      final operations = MeshEnabledBLEOperations(
        connectionService: connection,
        meshController: MeshNetworkingController(_FakeMeshService()),
        connectivityStatus: ConnectivityStatus(
          bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
            ConnectionInfo(isConnected: true, isReady: true),
          ),
          meshNetworkStatus: AsyncValue<MeshNetworkStatus>.data(_meshStatus(true)),
          bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
            BluetoothLowEnergyState.poweredOn,
          ),
        ),
      );

      final result = await operations.sendMessage(
        content: 'x',
        recipientPublicKey: 'peer',
      );

      expect(result.success, isFalse);
      expect(result.method, MessageSendMethod.direct);
      expect(result.error, isNull);
    });
  });

  group('NetworkHealth and UnifiedMessagingService', () {
    test('computes aggregate network health and issue list', () {
      final health = NetworkHealth(
        bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
          ConnectionInfo(isConnected: true, isReady: true),
        ),
        meshHealth: const MeshNetworkHealth(
          overallHealth: 0.8,
          relayEfficiency: 0.8,
          queueHealth: 0.8,
          spamBlockRate: 0.1,
          isHealthy: true,
          issues: <String>[],
        ),
        bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
          BluetoothLowEnergyState.poweredOn,
        ),
      );
      final poor = NetworkHealth(
        bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
          ConnectionInfo(isConnected: false, isReady: false),
        ),
        meshHealth: const MeshNetworkHealth(
          overallHealth: 0.1,
          relayEfficiency: 0.1,
          queueHealth: 0.1,
          spamBlockRate: 0.8,
          isHealthy: false,
          issues: <String>['relay unstable'],
        ),
        bluetoothState: const AsyncValue<BluetoothLowEnergyState>.data(
          BluetoothLowEnergyState.poweredOff,
        ),
      );

      expect(health.overallHealth, closeTo(0.92, 0.0001));
      expect(health.isHealthy, isTrue);
      expect(health.statusMessage, 'Network Excellent');
      expect(health.allIssues, isEmpty);

      expect(poor.overallHealth, closeTo(0.04, 0.0001));
      expect(poor.isHealthy, isFalse);
      expect(poor.statusMessage, 'Network Issues');
      expect(
        poor.allIssues,
        containsAll(<String>[
          'Bluetooth not powered on',
          'No BLE connection',
          'relay unstable',
        ]),
      );
    });

    test('UnifiedMessagingService maps mesh send result to UI model', () async {
      final meshService = _FakeMeshService()
        ..nextResult = MeshSendResult.error('cannot send');
      final service = UnifiedMessagingService(
        meshController: MeshNetworkingController(meshService),
        bleConnectionInfo: const AsyncValue<ConnectionInfo>.data(
          ConnectionInfo(isConnected: false, isReady: false),
        ),
      );

      final result = await service.sendMessage(
        content: 'payload',
        recipientPublicKey: 'peer',
      );

      expect(result.success, isFalse);
      expect(result.method, MessageSendMethod.mesh);
      expect(result.error, 'cannot send');
    });
  });

  group('BurstScanningOperations', () {
    test('delegates control calls and computes availability flags', () async {
      final controller = _FakeBurstController();
      final connection = MockConnectionService()
        ..isPeripheralMode = false
        ..emitBluetoothReady(true);

      final operations = BurstScanningOperations(
        controller: controller,
        connectionService: connection,
      );

      await operations.startBurstScanning();
      await operations.stopBurstScanning();
      await operations.triggerManualScan();
      await operations.forceManualScan();
      operations.reportConnectionSuccess(
        rssi: -60,
        connectionTime: 1.2,
        dataTransferSuccess: true,
      );
      operations.reportConnectionFailure(reason: 'timeout', rssi: -90, attemptTime: 2.1);

      final status = operations.getCurrentStatus();
      expect(status.statusMessage, isNotEmpty);
      expect(status.efficiencyRating, isNotEmpty);
      expect(operations.canPerformBurstScanning, isTrue);
      expect(operations.isBurstScanningAvailable, isTrue);
      expect(controller.startCalls, 1);
      expect(controller.stopCalls, 1);
      expect(controller.manualCalls, 1);
      expect(controller.forceCalls, 1);
      expect(controller.successReports, 1);
      expect(controller.failureReports, 1);

      connection.isPeripheralMode = true;
      expect(operations.canPerformBurstScanning, isFalse);
      expect(operations.isBurstScanningAvailable, isFalse);
    });
  });
}

MeshNetworkStatus _meshStatus(bool initialized) {
  return MeshNetworkStatus(
    isInitialized: initialized,
    currentNodeId: initialized ? 'node-a' : null,
    isConnected: initialized,
    statistics: MeshNetworkStatistics(
      nodeId: 'node-a',
      isInitialized: initialized,
      relayStatistics: null,
      queueStatistics: null,
      syncStatistics: null,
      spamStatistics: null,
      spamPreventionActive: initialized,
      queueSyncActive: initialized,
    ),
  );
}

class _FakeMeshService implements IMeshNetworkingService {
  MeshSendResult nextResult = MeshSendResult.direct('mesh-id');

  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream =>
      const Stream<ReceivedBinaryEvent>.empty();

  @override
  Future<void> initialize({String? nodeId}) async {}

  @override
  Stream<String> get messageDeliveryStream => const Stream<String>.empty();

  @override
  Stream<MeshNetworkStatus> get meshStatus =>
      Stream<MeshNetworkStatus>.value(_meshStatus(true));

  @override
  Stream<QueueSyncManagerStats> get queueStats =>
      const Stream<QueueSyncManagerStats>.empty();

  @override
  Stream<RelayStatistics> get relayStats => const Stream<RelayStatistics>.empty();

  @override
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    return nextResult;
  }

  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async =>
      <String, QueueSyncResult>{};

  @override
  Future<bool> removeMessage(String messageId) async => true;

  @override
  Future<int> retryAllMessages() async => 0;

  @override
  Future<bool> retryMessage(String messageId) async => true;

  @override
  Future<bool> setPriority(String messageId, MessagePriority priority) async =>
      true;

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
  }) async {
    return 'transfer-1';
  }

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async {
    return true;
  }

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() =>
      const <PendingBinaryTransfer>[];

  @override
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) =>
      const <QueuedMessage>[];

  @override
  MeshNetworkStatistics getNetworkStatistics() => const MeshNetworkStatistics(
    nodeId: 'node-a',
    isInitialized: true,
    relayStatistics: null,
    queueStatistics: null,
    syncStatistics: null,
    spamStatistics: null,
    spamPreventionActive: true,
    queueSyncActive: true,
  );

  @override
  void refreshMeshStatus() {}

  @override
  void dispose() {}
}

class _ThrowingConnectionService extends MockConnectionService {
  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) {
    throw StateError('direct send failed');
  }
}

class _FakeBurstController extends BurstScanningController {
  int startCalls = 0;
  int stopCalls = 0;
  int manualCalls = 0;
  int forceCalls = 0;
  int successReports = 0;
  int failureReports = 0;

  @override
  Future<void> startBurstScanning() async {
    startCalls++;
  }

  @override
  Future<void> stopBurstScanning() async {
    stopCalls++;
  }

  @override
  Future<void> triggerManualScan({
    Duration delay = const Duration(seconds: 1),
  }) async {
    manualCalls++;
  }

  @override
  Future<void> forceBurstScanNow() async {
    forceCalls++;
  }

  @override
  void reportConnectionSuccess({
    int? rssi,
    double? connectionTime,
    bool? dataTransferSuccess,
  }) {
    successReports++;
  }

  @override
  void reportConnectionFailure({
    String? reason,
    int? rssi,
    double? attemptTime,
  }) {
    failureReports++;
  }

  @override
  BurstScanningStatus getCurrentStatus() {
    return BurstScanningStatus(
      isBurstActive: false,
      secondsUntilNextScan: 12,
      burstTimeRemaining: null,
      currentScanInterval: 60,
      powerStats: const PowerManagementStats(
        currentScanInterval: 60,
        currentHealthCheckInterval: 30,
        consecutiveSuccessfulChecks: 1,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.9,
        connectionStabilityScore: 0.9,
        timeSinceLastSuccess: Duration(seconds: 3),
        qualityMeasurementsCount: 3,
        isBurstMode: false,
        powerMode: PowerMode.balanced,
        isDutyCycleScanning: true,
        batteryLevel: 80,
        isCharging: false,
        isAppInBackground: false,
      ),
    );
  }
}

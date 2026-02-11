import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/models/connection_info.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/services/burst_scanning_controller.dart';
import '../../domain/models/message_priority.dart';
import 'mesh_networking_provider.dart';

/// Enhanced connection information combining BLE and mesh status
class EnhancedConnectionInfo {
  final AsyncValue<ConnectionInfo> bleConnectionInfo;
  final AsyncValue<MeshNetworkStatus> meshNetworkStatus;

  const EnhancedConnectionInfo({
    required this.bleConnectionInfo,
    required this.meshNetworkStatus,
  });

  /// Check if both BLE and mesh are ready
  bool get isFullyConnected {
    final bleReady = bleConnectionInfo.asData?.value.isConnected ?? false;
    final meshReady = meshNetworkStatus.asData?.value.isInitialized ?? false;
    return bleReady && meshReady;
  }

  /// Get combined status message
  String get statusMessage {
    final bleStatus =
        bleConnectionInfo.asData?.value.statusMessage ?? 'Unknown';
    final meshReady = meshNetworkStatus.asData?.value.isInitialized ?? false;

    if (meshReady) {
      return '$bleStatus + Mesh Ready';
    } else {
      return bleStatus;
    }
  }

  /// Check if mesh relay is available
  bool get canUseRelay {
    final bleConnected = bleConnectionInfo.asData?.value.isConnected ?? false;
    final meshInitialized =
        meshNetworkStatus.asData?.value.isInitialized ?? false;
    return bleConnected && meshInitialized;
  }
}

/// Overall connectivity status
class ConnectivityStatus {
  final AsyncValue<ConnectionInfo> bleConnectionInfo;
  final AsyncValue<MeshNetworkStatus> meshNetworkStatus;
  final AsyncValue<BluetoothLowEnergyState> bluetoothState;

  const ConnectivityStatus({
    required this.bleConnectionInfo,
    required this.meshNetworkStatus,
    required this.bluetoothState,
  });

  /// Get overall connection health (0.0 - 1.0)
  double get connectionHealth {
    double health = 0.0;

    // Bluetooth state health
    final btState = bluetoothState.asData?.value;
    if (btState == BluetoothLowEnergyState.poweredOn) {
      health += 0.3;
    }

    // BLE connection health
    if (bleConnectionInfo.asData?.value.isConnected == true) {
      health += 0.4;
    }

    // Mesh networking health
    if (meshNetworkStatus.asData?.value.isInitialized == true) {
      health += 0.3;
    }

    return health;
  }

  /// Get status description
  String get statusDescription {
    if (connectionHealth >= 0.8) return 'Excellent';
    if (connectionHealth >= 0.6) return 'Good';
    if (connectionHealth >= 0.4) return 'Fair';
    if (connectionHealth >= 0.2) return 'Poor';
    return 'Disconnected';
  }

  /// Get list of active capabilities
  List<String> get activeCapabilities {
    final capabilities = <String>[];

    if (bluetoothState.asData?.value == BluetoothLowEnergyState.poweredOn) {
      capabilities.add('Bluetooth');
    }

    if (bleConnectionInfo.asData?.value.isConnected == true) {
      capabilities.add('Direct Messaging');
    }

    if (meshNetworkStatus.asData?.value.isInitialized == true) {
      capabilities.add('Mesh Relay');
    }

    return capabilities;
  }
}

/// Mesh-enabled BLE operations
class MeshEnabledBLEOperations {
  final IConnectionService connectionService;
  final MeshNetworkingController meshController;
  final ConnectivityStatus connectivityStatus;

  const MeshEnabledBLEOperations({
    required this.connectionService,
    required this.meshController,
    required this.connectivityStatus,
  });

  /// Send message using best available method (direct or mesh)
  Future<MessageSendResult> sendMessage({
    required String content,
    required String recipientPublicKey,
    bool preferDirect = true,
  }) async {
    try {
      // Check if direct connection is available to recipient
      final bleConnected =
          connectivityStatus.bleConnectionInfo.asData?.value.isConnected ??
          false;
      final connectedNodeId = connectionService.currentSessionId;

      if (preferDirect &&
          bleConnected &&
          connectedNodeId == recipientPublicKey) {
        // Use direct BLE messaging
        final success = await _sendDirectMessage(content);
        return MessageSendResult(
          success: success,
          method: MessageSendMethod.direct,
          messageId: DateTime.now().millisecondsSinceEpoch.toString(),
        );
      } else {
        // Use mesh relay
        final result = await meshController.sendMeshMessage(
          content: content,
          recipientPublicKey: recipientPublicKey,
        );

        return MessageSendResult(
          success: result.isSuccess,
          method: result.isDirect
              ? MessageSendMethod.direct
              : MessageSendMethod.mesh,
          messageId: result.messageId,
          nextHop: result.nextHop,
          error: result.error,
        );
      }
    } catch (e) {
      return MessageSendResult(
        success: false,
        method: MessageSendMethod.failed,
        error: e.toString(),
      );
    }
  }

  /// Send direct BLE message
  Future<bool> _sendDirectMessage(String content) async {
    try {
      if (connectionService.isPeripheralMode) {
        return await connectionService.sendPeripheralMessage(content);
      } else {
        return await connectionService.sendMessage(content);
      }
    } catch (e) {
      return false;
    }
  }

  /// Check message sending capabilities
  MessageSendCapabilities get sendCapabilities {
    final bleConnected =
        connectivityStatus.bleConnectionInfo.asData?.value.isConnected ?? false;
    final meshReady =
        connectivityStatus.meshNetworkStatus.asData?.value.isInitialized ??
        false;

    return MessageSendCapabilities(
      canSendDirect: bleConnected,
      canSendMesh: meshReady,
      preferredMethod: bleConnected
          ? MessageSendMethod.direct
          : MessageSendMethod.mesh,
    );
  }
}

/// Combined network health
class NetworkHealth {
  final AsyncValue<ConnectionInfo> bleConnectionInfo;
  final MeshNetworkHealth meshHealth;
  final AsyncValue<BluetoothLowEnergyState> bluetoothState;

  const NetworkHealth({
    required this.bleConnectionInfo,
    required this.meshHealth,
    required this.bluetoothState,
  });

  /// Get overall network health score (0.0 - 1.0)
  double get overallHealth {
    double totalHealth = 0.0;
    int factors = 0;

    // Bluetooth state factor (30%)
    if (bluetoothState.asData?.value == BluetoothLowEnergyState.poweredOn) {
      totalHealth += 0.3;
    }
    factors++;

    // BLE connection factor (30%)
    if (bleConnectionInfo.asData?.value.isConnected == true) {
      totalHealth += 0.3;
    }
    factors++;

    // Mesh health factor (40%)
    totalHealth += meshHealth.overallHealth * 0.4;
    factors++;

    return factors > 0 ? totalHealth : 0.0;
  }

  /// Check if network is healthy
  bool get isHealthy => overallHealth > 0.7;

  /// Get network status message
  String get statusMessage {
    if (overallHealth >= 0.8) return 'Network Excellent';
    if (overallHealth >= 0.6) return 'Network Good';
    if (overallHealth >= 0.4) return 'Network Fair';
    if (overallHealth >= 0.2) return 'Network Poor';
    return 'Network Issues';
  }

  /// Get combined issues
  List<String> get allIssues {
    final issues = <String>[];

    // Bluetooth issues
    if (bluetoothState.asData?.value != BluetoothLowEnergyState.poweredOn) {
      issues.add('Bluetooth not powered on');
    }

    // BLE connection issues
    if (bleConnectionInfo.asData?.value.isConnected != true) {
      issues.add('No BLE connection');
    }

    // Mesh issues
    issues.addAll(meshHealth.issues);

    return issues;
  }
}

/// Unified messaging service
class UnifiedMessagingService {
  final MeshNetworkingController meshController;
  final AsyncValue<ConnectionInfo> bleConnectionInfo;

  const UnifiedMessagingService({
    required this.meshController,
    required this.bleConnectionInfo,
  });

  /// Send message using the best available method
  Future<MessageSendResult> sendMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    final result = await meshController.sendMeshMessage(
      content: content,
      recipientPublicKey: recipientPublicKey,
      priority: priority,
    );

    return MessageSendResult(
      success: result.isSuccess,
      method: result.isDirect
          ? MessageSendMethod.direct
          : MessageSendMethod.mesh,
      messageId: result.messageId,
      nextHop: result.nextHop,
      error: result.error,
    );
  }
}

enum MessageSendMethod { direct, mesh, failed }

class MessageSendResult {
  final bool success;
  final MessageSendMethod method;
  final String? messageId;
  final String? nextHop;
  final String? error;

  const MessageSendResult({
    required this.success,
    required this.method,
    this.messageId,
    this.nextHop,
    this.error,
  });
}

class MessageSendCapabilities {
  final bool canSendDirect;
  final bool canSendMesh;
  final MessageSendMethod preferredMethod;

  const MessageSendCapabilities({
    required this.canSendDirect,
    required this.canSendMesh,
    required this.preferredMethod,
  });

  bool get hasAnyMethod => canSendDirect || canSendMesh;

  List<MessageSendMethod> get availableMethods {
    final methods = <MessageSendMethod>[];
    if (canSendDirect) methods.add(MessageSendMethod.direct);
    if (canSendMesh) methods.add(MessageSendMethod.mesh);
    return methods;
  }
}

/// Burst scanning operations class for UI control
class BurstScanningOperations {
  final BurstScanningController controller;
  final IConnectionService connectionService;

  const BurstScanningOperations({
    required this.controller,
    required this.connectionService,
  });

  /// Start burst scanning
  Future<void> startBurstScanning() async {
    await controller.startBurstScanning();
  }

  /// Stop burst scanning
  Future<void> stopBurstScanning() async {
    await controller.stopBurstScanning();
  }

  /// Trigger manual scan (overrides burst timing)
  Future<void> triggerManualScan() async {
    await controller.triggerManualScan();
  }

  /// Force a manual scan even if cooldown is active.
  Future<void> forceManualScan() async {
    await controller.forceBurstScanNow();
  }

  /// Report connection success for adaptive power management
  void reportConnectionSuccess({
    int? rssi,
    double? connectionTime,
    bool? dataTransferSuccess,
  }) {
    controller.reportConnectionSuccess(
      rssi: rssi,
      connectionTime: connectionTime,
      dataTransferSuccess: dataTransferSuccess,
    );
  }

  /// Report connection failure for adaptive power management
  void reportConnectionFailure({
    String? reason,
    int? rssi,
    double? attemptTime,
  }) {
    controller.reportConnectionFailure(
      reason: reason,
      rssi: rssi,
      attemptTime: attemptTime,
    );
  }

  /// Get current status
  BurstScanningStatus getCurrentStatus() {
    return controller.getCurrentStatus();
  }

  /// Check if device is in peripheral mode (can't do burst scanning)
  bool get canPerformBurstScanning => !connectionService.isPeripheralMode;

  /// Check if burst scanning is available
  bool get isBurstScanningAvailable {
    return canPerformBurstScanning && connectionService.isBluetoothReady;
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'dart:async';
import '../../data/services/ble_service.dart';
import '../../core/models/connection_info.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../domain/entities/enhanced_message.dart';
import 'mesh_networking_provider.dart';
import '../../data/repositories/user_preferences.dart';

// =============================================================================
// REACTIVE USERNAME PROVIDERS
// =============================================================================

/// Current username provider
final currentUsernameProvider = FutureProvider<String>((ref) async {
  return await UserPreferences().getUserName();
});

/// Username stream provider for reactive updates
final usernameStreamProvider = StreamProvider<String>((ref) {
  final controller = StreamController<String>.broadcast();
  
  // Initialize with current username
  UserPreferences().getUserName().then((name) {
    if (!controller.isClosed) {
      controller.add(name);
    }
  });
  
  ref.onDispose(() {
    controller.close();
  });
  
  return controller.stream;
});

/// Username update operations provider
final usernameOperationsProvider = Provider<UsernameOperations>((ref) {
  return UsernameOperations(ref);
});

// =============================================================================
// USERNAME OPERATIONS CLASS
// =============================================================================

/// Username operations for reactive updates with BLE integration
class UsernameOperations {
  final Ref _ref;
  
  const UsernameOperations(this._ref);
  
  /// Update username with full BLE state manager integration and identity re-exchange
  Future<void> updateUsernameWithBLE(String newUsername) async {
    final bleService = _ref.read(bleServiceProvider);
    
    try {
      // 1. Update username in storage (triggers reactive updates)
      await UserPreferences().setUserName(newUsername);
      
      // 2. Update BLE state manager cache (we'll enhance this method next)
      await bleService.stateManager.setMyUserName(newUsername);
      
      // 3. Trigger identity re-exchange if connected
      if (bleService.isConnected) {
        await _triggerIdentityReExchange(bleService, newUsername);
      }
      
      // 4. Refresh the current username provider
      _ref.refresh(currentUsernameProvider);
    } catch (e) {
      rethrow;
    }
  }
  
  /// Trigger identity re-exchange for immediate username propagation
  Future<void> _triggerIdentityReExchange(BLEService bleService, String newUsername) async {
    try {
      // Use the new enhanced identity re-exchange method
      await bleService.triggerIdentityReExchange();
      
    } catch (e) {
      // Log error but don't fail the username update
      print('Failed to re-exchange identity: $e');
    }
  }
}

// BLE Service provider
final bleServiceProvider = Provider<BLEService>((ref) {
  final service = BLEService();
  service.initialize();

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

// BLE State provider
final bleStateProvider = StreamProvider<BluetoothLowEnergyState>((ref) {
  final service = ref.watch(bleServiceProvider);
  return Stream.fromFuture(service.initializationComplete).asyncExpand((_) => Stream.periodic(Duration(seconds: 1), (_) => service.state));
});

// Discovered devices provider
final discoveredDevicesProvider = StreamProvider<List<Peripheral>>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.discoveredDevices;
});

// Received messages provider
final receivedMessagesProvider = StreamProvider<String>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.receivedMessages;
});

final connectionInfoProvider = StreamProvider<ConnectionInfo>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.connectionInfo;
});

final chatsRepositoryProvider = Provider<ChatsRepository>((ref) {
  return ChatsRepository();
});

// Discovery data with advertisements provider
final discoveryDataProvider = StreamProvider<Map<String, DiscoveredEventArgs>>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.discoveryData;
});

// =============================================================================
// MESH NETWORKING INTEGRATION WITH BLE PROVIDERS
// =============================================================================

/// Enhanced connection info provider that includes mesh networking status
final enhancedConnectionInfoProvider = Provider<EnhancedConnectionInfo>((ref) {
  final bleConnection = ref.watch(connectionInfoProvider);
  final meshStatus = ref.watch(meshNetworkStatusProvider);
  
  return EnhancedConnectionInfo(
    bleConnectionInfo: bleConnection,
    meshNetworkStatus: meshStatus,
  );
});

/// Combined connectivity status provider
final connectivityStatusProvider = Provider<ConnectivityStatus>((ref) {
  final bleConnection = ref.watch(connectionInfoProvider);
  final meshStatus = ref.watch(meshNetworkStatusProvider);
  final bleState = ref.watch(bleStateProvider);
  
  return ConnectivityStatus(
    bleConnectionInfo: bleConnection,
    meshNetworkStatus: meshStatus,
    bluetoothState: bleState,
  );
});

/// Mesh-enabled BLE operations provider
final meshEnabledBLEProvider = Provider<MeshEnabledBLEOperations>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  final meshController = ref.watch(meshNetworkingControllerProvider);
  final connectivityStatus = ref.watch(connectivityStatusProvider);
  
  return MeshEnabledBLEOperations(
    bleService: bleService,
    meshController: meshController,
    connectivityStatus: connectivityStatus,
  );
});

/// Network health provider combining BLE and mesh health
final networkHealthProvider = Provider<NetworkHealth>((ref) {
  final bleConnection = ref.watch(connectionInfoProvider);
  final meshHealth = ref.watch(meshNetworkingControllerProvider).getNetworkHealth();
  final bluetoothState = ref.watch(bleStateProvider);
  
  return NetworkHealth(
    bleConnectionInfo: bleConnection,
    meshHealth: meshHealth,
    bluetoothState: bluetoothState,
  );
});

/// Unified messaging provider that handles both direct and mesh messages
final unifiedMessagingProvider = Provider<UnifiedMessagingService>((ref) {
  final meshController = ref.watch(meshNetworkingControllerProvider);
  final bleConnection = ref.watch(connectionInfoProvider);
  
  return UnifiedMessagingService(
    meshController: meshController,
    bleConnectionInfo: bleConnection,
  );
});

// =============================================================================
// DATA CLASSES FOR ENHANCED BLE + MESH INTEGRATION
// =============================================================================

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
    final bleStatus = bleConnectionInfo.asData?.value.statusMessage ?? 'Unknown';
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
    final meshInitialized = meshNetworkStatus.asData?.value.isInitialized ?? false;
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
    
    if (meshNetworkStatus.asData?.value.isDemoMode == true) {
      capabilities.add('Demo Mode');
    }
    
    return capabilities;
  }
}

/// Mesh-enabled BLE operations
class MeshEnabledBLEOperations {
  final BLEService bleService;
  final MeshNetworkingController meshController;
  final ConnectivityStatus connectivityStatus;

  const MeshEnabledBLEOperations({
    required this.bleService,
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
      final bleConnected = connectivityStatus.bleConnectionInfo.asData?.value.isConnected ?? false;
      final connectedNodeId = bleService.otherDevicePersistentId;
      
      if (preferDirect && bleConnected && connectedNodeId == recipientPublicKey) {
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
          isDemo: connectivityStatus.meshNetworkStatus.asData?.value.isDemoMode ?? false,
        );
        
        return MessageSendResult(
          success: result.isSuccess,
          method: result.isDirect ? MessageSendMethod.direct : MessageSendMethod.mesh,
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
      if (bleService.isPeripheralMode) {
        return await bleService.sendPeripheralMessage(content);
      } else {
        return await bleService.sendMessage(content);
      }
    } catch (e) {
      return false;
    }
  }

  /// Check message sending capabilities
  MessageSendCapabilities get sendCapabilities {
    final bleConnected = connectivityStatus.bleConnectionInfo.asData?.value.isConnected ?? false;
    final meshReady = connectivityStatus.meshNetworkStatus.asData?.value.isInitialized ?? false;
    
    return MessageSendCapabilities(
      canSendDirect: bleConnected,
      canSendMesh: meshReady,
      preferredMethod: bleConnected ? MessageSendMethod.direct : MessageSendMethod.mesh,
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
    bool isDemo = false,
  }) async {
    final result = await meshController.sendMeshMessage(
      content: content,
      recipientPublicKey: recipientPublicKey,
      priority: priority,
      isDemo: isDemo,
    );
    
    return MessageSendResult(
      success: result.isSuccess,
      method: result.isDirect ? MessageSendMethod.direct : MessageSendMethod.mesh,
      messageId: result.messageId,
      nextHop: result.nextHop,
      error: result.error,
    );
  }

  /// Check if recipient is directly connected
  bool isDirectlyConnected(String recipientPublicKey) {
    // This would check if the recipient is the currently connected BLE peer
    return false; // Placeholder implementation
  }
}

// Supporting enums and classes

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
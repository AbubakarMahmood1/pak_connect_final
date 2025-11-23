import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_ble_advertising_service.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import '../../data/services/ble_connection_manager.dart';
import '../../core/bluetooth/advertising_manager.dart';
import '../../core/bluetooth/peripheral_initializer.dart';

/// Manages BLE peripheral role (server) advertising and GATT services.
///
/// Extracted from BLEService in Phase 2A.2.2a as part of refactoring
/// (splitting 3,431 lines → 6 services).
///
/// Responsibility: Handle all advertising/peripheral-mode operations
/// - GATT service and characteristic setup
/// - Advertising start/stop and data updates
/// - MTU negotiation with connecting centrals
/// - Online status broadcasting
class BLEAdvertisingService implements IBLEAdvertisingService {
  final _logger = Logger('BLEAdvertisingService');

  // Dependencies injected at initialization
  final IBLEStateManagerFacade stateManager;
  final BLEConnectionManager connectionManager;
  final AdvertisingManager advertisingManager;
  final PeripheralInitializer peripheralInitializer;
  final PeripheralManager peripheralManager;

  // Callback to update connection info in facade
  final Function({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
  })
  onUpdateConnectionInfo;

  // Peripheral state (shared with connection service)
  Central? connectedCentral;
  GATTCharacteristic? connectedCharacteristic;
  bool peripheralHandshakeStarted = false;
  int? _peripheralNegotiatedMTU;
  bool _peripheralMtuReady = false;

  BLEAdvertisingService({
    required this.stateManager,
    required this.connectionManager,
    required this.advertisingManager,
    required this.peripheralInitializer,
    required this.peripheralManager,
    required this.onUpdateConnectionInfo,
  });

  // ============================================================================
  // IMPLEMENTATION: Extracted from BLEService (lines 1979-2158)
  // ============================================================================

  @override
  Future<void> startAsPeripheral() async {
    _logger.info('📡 Starting peripheral advertising (dual-role mode)...');

    // 🔧 DUAL-ROLE FIX: NO mode switching - peripheral and central run simultaneously
    // We NEVER stop central mode or disconnect - both roles coexist
    // Only skip if already advertising to avoid redundant operations

    if (advertisingManager.isAdvertising) {
      _logger.fine(
        '📡 Already advertising - skipping redundant peripheral start',
      );
      return;
    }

    // ✅ DUAL-ROLE: Track peripheral connection state (device is always both central+peripheral)
    stateManager.setPeripheralMode(true);

    try {
      // ✅ FIX: Use safe peripheral initialization
      _logger.info('🔧 Preparing peripheral manager...');

      final messageCharacteristic = GATTCharacteristic.mutable(
        uuid: BLEConstants.messageCharacteristicUUID,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );

      final service = GATTService(
        uuid: BLEConstants.serviceUUID,
        isPrimary: true,
        includedServices: [],
        characteristics: [messageCharacteristic],
      );

      // ✅ FIX: Safely add service with proper initialization wait
      final serviceAdded = await peripheralInitializer.safelyAddService(
        service,
        timeout: Duration(seconds: 5),
      );

      if (!serviceAdded) {
        throw Exception('Failed to add GATT service - peripheral not ready');
      }

      // 📡 NEW: Use AdvertisingManager (SINGLE RESPONSIBILITY)
      // Get my public key for identity hint
      final myPublicKey = await stateManager.getMyPersistentId();

      // Start advertising with settings-aware hint inclusion
      final advertisingStarted = await advertisingManager.startAdvertising(
        myPublicKey: myPublicKey,
        timeout: Duration(seconds: 5),
        skipIfAlreadyAdvertising: true,
      );

      if (!advertisingStarted) {
        throw Exception('Failed to start advertising - peripheral not ready');
      }

      // ⚠️ REMOVED: _isAdvertising assignment - connection manager tracks state
      onUpdateConnectionInfo(
        isAdvertising: true,
        statusMessage: 'Advertising - dual-role active',
      );
      _logger.info(
        '✅ Peripheral advertising active (dual-role - central still running)!',
      );
    } catch (e, stack) {
      _logger.severe('Failed to start as peripheral: $e', e, stack);
      onUpdateConnectionInfo(
        isAdvertising: false,
        statusMessage: 'Peripheral mode failed',
      );
      rethrow;
    }
  }

  @override
  Future<void> startAsPeripheralWithValidation() async {
    _logger.info('📡 startAsPeripheralWithValidation()');
    // Delegate to main method; Bluetooth state validation is handled by facade
    await startAsPeripheral();
  }

  @override
  Future<void> refreshAdvertising({bool? showOnlineStatus}) async {
    if (!stateManager.isPeripheralMode) {
      _logger.warning('⚠️ Cannot refresh advertising - not in peripheral mode');
      return;
    }

    _logger.info('🔄 Refreshing advertising data...');

    try {
      // Get my public key for identity hint
      final myPublicKey = await stateManager.getMyPersistentId();

      // 📡 NEW: Use AdvertisingManager.refreshAdvertising (SINGLE METHOD)
      // This ensures consistent advertisement structure every time
      await advertisingManager.refreshAdvertising(
        myPublicKey: myPublicKey,
        showOnlineStatus: showOnlineStatus,
      );

      onUpdateConnectionInfo(
        isAdvertising: true,
        statusMessage: 'Advertising - discoverable',
      );
      _logger.info('✅ Advertising refreshed successfully!');
    } catch (e, stack) {
      _logger.severe('❌ Failed to refresh advertising: $e', e, stack);
      onUpdateConnectionInfo(
        isAdvertising: false,
        statusMessage: 'Advertising refresh failed',
      );
    }
  }

  @override
  Future<void> startAsCentral() async {
    _logger.info('Starting as Central (scanner)...');

    // Preserve session ID across mode switches
    final preservedOtherPublicKey = stateManager.currentSessionId;
    final preservedOtherName = stateManager.otherUserName;
    final preservedTheyHaveUs = stateManager.theyHaveUsAsContact;
    final preservedWeHaveThem = await stateManager.weHaveThemAsContact;

    // Set mode
    stateManager.setPeripheralMode(false);

    // Clear peripheral-specific state (but NOT encryption keys!)
    connectedCentral = null;
    connectedCharacteristic = null;
    peripheralHandshakeStarted = false;
    _peripheralNegotiatedMTU = null;
    _peripheralMtuReady = false;

    // Stop mesh networking (stops both advertising and scanning)
    try {
      await connectionManager.stopMeshNetworking();
    } catch (e) {
      _logger.fine('Could not stop mesh networking: $e');
    }

    try {
      await peripheralManager.removeAllServices();
    } catch (e) {
      _logger.fine('Could not remove services: $e');
    }

    onUpdateConnectionInfo(
      isConnected: false,
      isReady: false,
      otherUserName: null,
      isAdvertising: false,
      statusMessage: 'Ready to scan',
    );

    stateManager.preserveContactRelationship(
      otherPublicKey: preservedOtherPublicKey,
      otherName: preservedOtherName,
      theyHaveUs: preservedTheyHaveUs,
      weHaveThem: preservedWeHaveThem,
    );

    _logger.info('Switched to central mode');
  }

  @override
  bool get isAdvertising => advertisingManager.isAdvertising;

  @override
  bool get isPeripheralMode => stateManager.isPeripheralMode;

  @override
  int? get peripheralNegotiatedMTU => _peripheralNegotiatedMTU;

  @override
  bool get isPeripheralMTUReady => _peripheralMtuReady;
}

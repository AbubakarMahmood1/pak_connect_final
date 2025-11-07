import 'dart:async';
import 'dart:io';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/ble_constants.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../services/hint_advertisement_service.dart';
import '../../core/security/ephemeral_key_manager.dart';
import 'peripheral_initializer.dart';

/// 📡 SINGLE RESPONSIBILITY: Manages ALL BLE advertising operations
/// 
/// This class is the ONLY place where advertising is started, stopped, or refreshed.
/// It ensures consistent advertisement structure regardless of hints or settings.
/// 
/// Key Design Principles (from BitChat reference):
/// 1. Advertising ALWAYS starts - hints are optional additions, not requirements
/// 2. Same method for initial and restart advertising (no inconsistency)
/// 3. Settings-aware: respects user preferences for hint broadcasting
/// 4. Guard conditions never throw - fail gracefully with logging
/// 5. 100ms delay between stop and start prevents Android errors
class AdvertisingManager {
  final Logger _logger = Logger('AdvertisingManager');
  final PeripheralInitializer _peripheralInitializer;
  final PeripheralManager _peripheralManager;
  final IntroHintRepository _introHintRepo;

  /// Track advertising state
  bool _isAdvertising = false;
  bool get isAdvertising => _isAdvertising;

  /// Track if manager is active
  bool _isActive = false;

  AdvertisingManager({
    required PeripheralInitializer peripheralInitializer,
    required PeripheralManager peripheralManager,
    required IntroHintRepository introHintRepo,
  })  : _peripheralInitializer = peripheralInitializer,
        _peripheralManager = peripheralManager,
        _introHintRepo = introHintRepo;
  
  /// Initialize the advertising manager
  void start() {
    if (_isActive) {
      _logger.fine('📡 Advertising manager already active');
      return;
    }
    _isActive = true;
    _logger.info('📡 Advertising manager started');
  }
  
  /// Shutdown the advertising manager
  Future<void> stop() async {
    if (!_isActive) {
      _logger.fine('📡 Advertising manager already stopped');
      return;
    }
    
    _isActive = false;
    await stopAdvertising();
    _logger.info('📡 Advertising manager stopped');
  }
  
  /// 📡 Start advertising with settings-aware hint inclusion
  /// 
  /// This is the ONLY method that starts advertising.
  /// It ALWAYS starts advertising with service UUID.
  /// Hints are added based on user settings (optional, not required).
  /// 
  /// Parameters:
  /// - myPublicKey: User's persistent public key for identity hint
  /// - timeout: Maximum time to wait for peripheral ready
  /// - skipIfAlreadyAdvertising: Stop existing advertising before starting
  Future<bool> startAdvertising({
    required String myPublicKey,
    Duration timeout = const Duration(seconds: 5),
    bool skipIfAlreadyAdvertising = true,
  }) async {
    _logger.info('🔍 [ADV-DEBUG] ========================================');
    _logger.info('🔍 [ADV-DEBUG] START ADVERTISING CALLED');
    _logger.info('🔍 [ADV-DEBUG] myPublicKey: ${myPublicKey.substring(0, 16)}...');
    _logger.info('🔍 [ADV-DEBUG] timeout: $timeout');
    _logger.info('🔍 [ADV-DEBUG] skipIfAlreadyAdvertising: $skipIfAlreadyAdvertising');
    _logger.info('🔍 [ADV-DEBUG] ========================================');

    // Guard: Check if active
    if (!_isActive) {
      _logger.severe('❌ [ADV-DEBUG] Manager NOT ACTIVE - cannot start');
      return false;
    }
    _logger.info('✅ [ADV-DEBUG] Manager is ACTIVE');

    // Guard: Check if already advertising
    if (_isAdvertising && skipIfAlreadyAdvertising) {
      _logger.info('📡 [ADV-DEBUG] Already advertising - skipping');
      return true;
    }
    _logger.info('✅ [ADV-DEBUG] Not currently advertising - proceeding');

    _logger.info('📡 [ADV-DEBUG] Starting advertising process...');

    try {
      // Step 1: Build advertisement data (settings-aware)
      _logger.info('🔍 [ADV-DEBUG] STEP 1: Building advertisement data...');
      final advData = await _buildAdvertisementData(myPublicKey);
      _logger.info('✅ [ADV-DEBUG] Advertisement data built: ${advData.length} entries');

      if (advData.isNotEmpty) {
        for (var i = 0; i < advData.length; i++) {
          _logger.info('🔍 [ADV-DEBUG]   Entry[$i]: ID=0x${advData[i].id.toRadixString(16)}, Data=${advData[i].data.length} bytes');
        }
      } else {
        _logger.info('🔍 [ADV-DEBUG]   No manufacturer data (hints disabled or iOS)');
      }

      // Step 2: Create advertisement structure
      _logger.info('🔍 [ADV-DEBUG] STEP 2: Creating advertisement...');
      final advertisement = Advertisement(
        name: null,  // Privacy: no device name
        serviceUUIDs: [BLEConstants.serviceUUID],  // ALWAYS include service UUID
        manufacturerSpecificData: advData,  // Hints (if enabled) or empty
      );
      _logger.info('✅ [ADV-DEBUG] Advertisement created:');
      _logger.info('   - Service UUID: ${BLEConstants.serviceUUID}');
      _logger.info('   - Device name: null');
      _logger.info('   - Manufacturer data: ${advData.length} entries');

      // Step 3: Start advertising via peripheral initializer
      _logger.info('🔍 [ADV-DEBUG] STEP 3: Calling PeripheralInitializer...');
      final success = await _peripheralInitializer.safelyStartAdvertising(
        advertisement,
        timeout: timeout,
        skipIfAlreadyAdvertising: skipIfAlreadyAdvertising,
      );

      _logger.info('🔍 [ADV-DEBUG] PeripheralInitializer returned: $success');

      if (success) {
        _isAdvertising = true;
        _logger.info('✅✅✅ [ADV-DEBUG] ADVERTISING STARTED! ✅✅✅');
        _logger.info('🔍 [ADV-DEBUG] Device should be discoverable with UUID: ${BLEConstants.serviceUUID}');
        return true;
      } else {
        _logger.severe('❌❌❌ [ADV-DEBUG] ADVERTISING FAILED! ❌❌❌');
        _logger.severe('❌ [ADV-DEBUG] PeripheralInitializer returned FALSE');
        return false;
      }

    } catch (e, stack) {
      _logger.severe('❌❌❌ [ADV-DEBUG] EXCEPTION! ❌❌❌');
      _logger.severe('❌ [ADV-DEBUG] Error: $e', e, stack);
      _isAdvertising = false;
      return false;
    }
  }
  
  /// 📡 Stop advertising
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) {
      _logger.fine('📡 Not advertising - nothing to stop');
      return;
    }
    
    try {
      await _peripheralManager.stopAdvertising();
      _isAdvertising = false;
      _logger.info('📡 Advertising stopped');
    } catch (e, stack) {
      _logger.warning('📡 Error stopping advertising (may not have been active)', e, stack);
      _isAdvertising = false;  // Reset state anyway
    }
  }
  
  /// 📡 Restart advertising with fresh data
  /// 
  /// This method uses the SAME startAdvertising() method to ensure consistency.
  /// No separate "restart advertisement" - prevents hint inconsistency issues.
  /// 
  /// Parameters:
  /// - myPublicKey: User's persistent public key for identity hint
  /// - showOnlineStatus: Optional override for online status setting
  Future<void> restartAdvertising({
    required String myPublicKey,
    bool? showOnlineStatus,
  }) async {
    // Guard: Check if active
    if (!_isActive) {
      _logger.warning('📡 Cannot restart advertising - manager not active');
      return;
    }
    
    _logger.info('📡 Restarting advertising...');
    
    try {
      // Step 1: Stop current advertising
      await stopAdvertising();
      
      // Step 2: Wait 100ms to prevent "already advertising" errors (BitChat pattern)
      await Future.delayed(Duration(milliseconds: 100));
      
      // Step 3: Start advertising with SAME method (ensures consistency)
      final success = await startAdvertising(
        myPublicKey: myPublicKey,
        skipIfAlreadyAdvertising: false,  // We already stopped
      );
      
      if (success) {
        _logger.info('✅ Advertising restarted successfully');
      } else {
        _logger.severe('❌ Failed to restart advertising');
      }
      
    } catch (e, stack) {
      _logger.severe('❌ Failed to restart advertising', e, stack);
    }
  }
  
  /// 📡 Refresh advertising with updated settings
  /// 
  /// Called when user changes settings (e.g., online status, spy mode).
  /// Uses restart logic to apply new settings.
  Future<void> refreshAdvertising({
    required String myPublicKey,
    bool? showOnlineStatus,
  }) async {
    _logger.info('📡 Refreshing advertising with updated settings...');
    await restartAdvertising(
      myPublicKey: myPublicKey,
      showOnlineStatus: showOnlineStatus,
    );
  }
  
  /// 🔧 Build advertisement data based on user settings
  /// 
  /// This method is settings-aware:
  /// - Checks 'show_online_status' preference
  /// - Checks hint broadcast enabled (spy mode)
  /// - Returns manufacturer data with hints (if enabled) or empty list
  /// 
  /// Returns: List of ManufacturerSpecificData (empty while hints are disabled)
  Future<List<ManufacturerSpecificData>> _buildAdvertisementData(
    String myPublicKey,
  ) async {
    _logger.info('🔍 [ADV-DEBUG] _buildAdvertisementData called');
    _logger.info('🔍 [ADV-DEBUG] Platform: ${Platform.operatingSystem}');

    // Privacy hardening: deterministic hint bytes are disabled until the blinded
    // hint redesign ships. Only the service UUID is advertised for now.
    if (Platform.isIOS || Platform.isMacOS) {
      _logger.info('🔍 [ADV-DEBUG] iOS/macOS detected - manufacturer data unsupported');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final showOnlineStatus = prefs.getBool('show_online_status') ?? true;
      final hintBroadcastEnabled = prefs.getBool('hint_broadcast_enabled') ?? true;

      if (!showOnlineStatus || !hintBroadcastEnabled) {
        _logger.info('🔍 [ADV-DEBUG] Hints disabled via privacy settings');
        return [];
      }

      final sessionKey = EphemeralKeyManager.currentSessionKey;
      if (sessionKey == null) {
        _logger.warning('🔍 [ADV-DEBUG] No session key available - cannot compute blinded hint');
        return [];
      }

      final nonce = HintAdvertisementService.deriveNonce(sessionKey);
      final introHint = await _introHintRepo.getMostRecentActiveHint();
      final useIntro = introHint != null && introHint.isUsable;
      final identifier = useIntro ? introHint!.hintHex : myPublicKey;

      final hintBytes = HintAdvertisementService.computeHintBytes(
        identifier: identifier,
        nonce: nonce,
      );

      final advData = HintAdvertisementService.packAdvertisement(
        nonce: nonce,
        hintBytes: hintBytes,
        isIntro: useIntro,
      );

      final modeLabel = useIntro ? 'intro' : 'persistent';
      _logger.info('✅ [ADV-DEBUG] Blinded hint ready ($modeLabel, nonce=${HintAdvertisementService.bytesToHex(nonce)})');

      return [
        ManufacturerSpecificData(
          id: 0x2E19,
          data: advData,
        ),
      ];

    } catch (e, stack) {
      _logger.severe('❌ [ADV-DEBUG] ERROR building advertisement data!', e, stack);
      _logger.warning('📡 Falling back to advertising without hints');
      return [];
    }
  }
}

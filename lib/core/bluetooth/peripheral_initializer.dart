import 'dart:async';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Handles proper initialization of BLE Peripheral mode
/// Solves the race condition where GATT server isn't ready when addService() is called
class PeripheralInitializer {
  final Logger _logger = Logger('PeripheralInitializer');
  final PeripheralManager peripheralManager;

  // Initialization state
  final Completer<void> _readyCompleter = Completer<void>();
  bool _isInitialized = false;
  DateTime? _initStartTime;

  PeripheralInitializer(this.peripheralManager);

  /// Wait for peripheral manager to be fully ready
  /// Returns true if ready, false if timeout
  Future<bool> waitUntilReady({Duration timeout = const Duration(seconds: 5)}) async {
    if (_isInitialized && _readyCompleter.isCompleted) {
      _logger.info('✅ Peripheral already initialized');
      return true;
    }

    _logger.info('⏳ Waiting for peripheral manager to initialize...');
    _initStartTime = DateTime.now();

    try {
      // Use polling approach since we can't rely on native callbacks
      await _pollForReady(timeout);

      _isInitialized = true;
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }

      final duration = DateTime.now().difference(_initStartTime!).inMilliseconds;
      _logger.info('✅ Peripheral ready after ${duration}ms');
      return true;

    } on TimeoutException {
      _logger.warning('⏱️ Peripheral initialization timeout after ${timeout.inSeconds}s');
      return false;
    } catch (e) {
      _logger.severe('❌ Peripheral initialization error: $e');
      return false;
    }
  }

  /// Poll for peripheral readiness by attempting harmless operations
  Future<void> _pollForReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    const pollInterval = Duration(milliseconds: 100);

    while (DateTime.now().isBefore(deadline)) {
      try {
        // Try to get state - this should work once manager is initialized
        final state = peripheralManager.state;

        // If we can get state without exception, manager is initialized
        _logger.info('  Peripheral state: $state (initialized)');
        return;

      } catch (e) {
        // Manager not ready yet, wait and retry
        _logger.fine('  Waiting for peripheral... ($e)');
        await Future.delayed(pollInterval);
      }
    }

    throw TimeoutException('Peripheral manager not ready', timeout);
  }

  /// Safely add GATT service with proper initialization check
  Future<bool> safelyAddService(
    GATTService service, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _logger.info('🔧 Attempting to add GATT service...');

    // Step 1: Ensure peripheral is ready
    final isReady = await waitUntilReady(timeout: timeout);
    if (!isReady) {
      _logger.severe('❌ Cannot add service - peripheral not ready');
      return false;
    }

    // Step 2: Try to remove existing services (if any)
    try {
      await peripheralManager.removeAllServices();
      _logger.info('  Removed existing services');
    } catch (e) {
      // Not critical - may not have services to remove
      _logger.fine('  No services to remove: $e');
    }

    // Step 3: Add the service
    try {
      await peripheralManager.addService(service);
      _logger.info('✅ GATT service added successfully');
      return true;

    } catch (e, stack) {
      _logger.severe('❌ Failed to add GATT service', e, stack);
      return false;
    }
  }

  /// Safely start advertising with proper initialization check
  Future<bool> safelyStartAdvertising(
    Advertisement advertisement, {
    Duration timeout = const Duration(seconds: 5),
    bool skipIfAlreadyAdvertising = true,
  }) async {
    _logger.info('📡 Attempting to start advertising...');

    // Step 1: Ensure peripheral is ready
    final isReady = await waitUntilReady(timeout: timeout);
    if (!isReady) {
      _logger.severe('❌ Cannot start advertising - peripheral not ready');
      return false;
    }

    // Step 2: Check if already advertising (prevents error code 3)
    if (skipIfAlreadyAdvertising) {
      try {
        // Try to stop advertising first - if it fails, we weren't advertising
        await peripheralManager.stopAdvertising();
        _logger.info('  Stopped previous advertising session');
      } catch (e) {
        // Not advertising, which is fine - we can start fresh
        _logger.fine('  No active advertising to stop');
      }
    }

    // Step 3: Start advertising
    try {
      await peripheralManager.startAdvertising(advertisement);
      _logger.info('✅ Advertising started successfully');
      return true;

    } catch (e, stack) {
      _logger.severe('❌ Failed to start advertising', e, stack);
      return false;
    }
  }

  /// Reset initialization state (for reconnection scenarios)
  void reset() {
    _logger.info('🔄 Resetting peripheral initializer state');
    _isInitialized = false;
  }

  bool get isReady => _isInitialized && _readyCompleter.isCompleted;
}

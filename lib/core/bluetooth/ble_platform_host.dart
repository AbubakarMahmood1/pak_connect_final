import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../interfaces/i_ble_platform_host.dart';
import '../power/battery_optimizer.dart';
import '../security/ephemeral_key_manager.dart';

/// Default production implementation that proxies real platform managers.
class BlePlatformHost implements IBLEPlatformHost {
  BlePlatformHost({
    CentralManager? centralManager,
    PeripheralManager? peripheralManager,
    BatteryOptimizer? batteryOptimizer,
    Future<void> Function()? ensureEphemeralKeysInitialized,
    String Function()? ephemeralIdProvider,
  }) : _centralManager = centralManager,
       _peripheralManager = peripheralManager,
       _batteryOptimizer = batteryOptimizer,
       _ensureEphemeralKeysInitialized = ensureEphemeralKeysInitialized,
       _ephemeralIdProvider = ephemeralIdProvider;

  CentralManager? _centralManager;
  PeripheralManager? _peripheralManager;
  BatteryOptimizer? _batteryOptimizer;

  final Future<void> Function()? _ensureEphemeralKeysInitialized;
  final String Function()? _ephemeralIdProvider;

  @override
  CentralManager get centralManager => _centralManager ??= CentralManager();

  @override
  PeripheralManager get peripheralManager =>
      _peripheralManager ??= PeripheralManager();

  @override
  BatteryOptimizer get batteryOptimizer =>
      _batteryOptimizer ??= BatteryOptimizer();

  @override
  Future<void> ensureEphemeralKeysInitialized() async {
    if (_ensureEphemeralKeysInitialized != null) {
      await _ensureEphemeralKeysInitialized!();
    }
  }

  @override
  String getCurrentEphemeralId() {
    if (_ephemeralIdProvider != null) {
      return _ephemeralIdProvider!();
    }
    return EphemeralKeyManager.generateMyEphemeralKey();
  }
}

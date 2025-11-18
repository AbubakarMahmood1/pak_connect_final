import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../power/battery_optimizer.dart';

/// Abstraction over platform-specific BLE singletons so tests can inject fakes.
///
/// Production code uses the default host, while tests can provide lightweight
/// hosts that expose fake managers and deterministic key providers without
/// touching real plugins.
abstract class IBLEPlatformHost {
  /// Shared central manager instance for the entire BLE stack.
  CentralManager get centralManager;

  /// Shared peripheral manager instance for the entire BLE stack.
  PeripheralManager get peripheralManager;

  /// Battery optimizer used by BLE services to adjust scanning behavior.
  BatteryOptimizer get batteryOptimizer;

  /// Ensures any plugin-backed initialization (ephemeral keys, caches, etc.)
  /// is performed before the BLE services start touching platform APIs.
  Future<void> ensureEphemeralKeysInitialized();

  /// Returns the current ephemeral identifier that should be exposed via the
  /// BLE facade. Implementations can return deterministic values for tests.
  String getCurrentEphemeralId();
}

/// Manages BLE peripheral role (server) including:
/// - GATT service and characteristic setup
/// - Advertising start/stop and data updates
/// - MTU negotiation with connecting centrals
/// - Online status broadcasting
///
/// Single responsibility: Handle all advertising/peripheral-mode operations
/// Dependencies: AdvertisingManager, PeripheralInitializer, PeripheralManager
/// Consumers: HomeScreen, DiscoveryOverlay
abstract class IBLEAdvertisingService {
  // ============================================================================
  // PERIPHERAL MODE CONTROL
  // ============================================================================

  /// Enter peripheral mode: add GATT service, start advertising, update connection info
  /// Transitions device from central-only to dual-role (can scan AND advertise)
  ///
  /// Throws:
  ///   StateError if Bluetooth not ready
  ///   PlatformException if service addition fails
  Future<void> startAsPeripheral();

  /// Enter peripheral mode with Bluetooth state validation
  /// Automatically defers startup if Bluetooth becomes unavailable
  ///
  /// Throws:
  ///   StateError if Bluetooth state prevents peripheral mode
  Future<void> startAsPeripheralWithValidation();

  /// Exit peripheral mode: remove services, stop advertising
  /// Cleans up peripheral state but preserves session identity
  /// Device returns to central-only mode
  ///
  /// Throws:
  ///   PlatformException if service removal fails
  Future<void> startAsCentral();

  // ============================================================================
  // ADVERTISING MANAGEMENT
  // ============================================================================

  /// Update advertising data with new preferences
  /// Called when user changes settings (online status, display name, etc.)
  ///
  /// Args:
  ///   showOnlineStatus - Whether to include device in online discovery
  /// Throws:
  ///   StateError if not in peripheral mode
  Future<void> refreshAdvertising({bool? showOnlineStatus});

  // ============================================================================
  // ADVERTISING STATE
  // ============================================================================

  /// Is device currently advertising in peripheral mode?
  /// Single source of truth: queries AdvertisingManager state
  bool get isAdvertising;

  /// Is device in peripheral mode (can accept connections)?
  bool get isPeripheralMode;

  /// MTU negotiated with connecting central (peripheral mode)
  int? get peripheralNegotiatedMTU;

  /// Has MTU negotiation completed with connecting central?
  bool get isPeripheralMTUReady;
}

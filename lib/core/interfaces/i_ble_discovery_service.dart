import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Manages BLE device discovery and deduplication including:
/// - Central role scanning for devices
/// - Device list deduplication and filtering
/// - Hint-based device matching for collision detection
/// - Auto-connect to known contacts
///
/// Single responsibility: Handle all discovery-related operations
/// Dependencies: CentralManager, DeviceDeduplicationManager, HintScannerService
/// Consumers: DiscoveryOverlay, BLEProviders, BurstScanningController
abstract class IBLEDiscoveryService {
  // ============================================================================
  // SCANNING CONTROL
  // ============================================================================

  /// Begin central role device scanning
  /// Tracks scanning source (manual, burst, system) for conflict resolution
  ///
  /// Args:
  ///   source - Who initiated the scan (for conflict detection)
  /// Throws:
  ///   StateError if Bluetooth not ready
  ///   PlatformException if scan fails to start
  Future<void> startScanning({ScanningSource source = ScanningSource.manual});

  /// Stop central role device scanning
  /// Cancels all active scan subscriptions
  Future<void> stopScanning();

  /// Start scanning with Bluetooth state validation
  /// Automatically handles Bluetooth unavailability by deferring scan
  ///
  /// Args:
  ///   source - Who initiated the scan
  Future<void> startScanningWithValidation({
    ScanningSource source = ScanningSource.manual,
  });

  /// Scan for a specific device by MAC address or name
  /// Stops general scanning, searches for target, then resumes general scanning
  ///
  /// Args:
  ///   timeout - Maximum time to search for device
  /// Returns:
  ///   Peripheral if found, null if timeout expires
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout});

  // ============================================================================
  // DISCOVERY STATE
  // ============================================================================

  /// Stream of discovered devices (deduplicated list)
  /// Emits entire list each time a new device is discovered or removed
  Stream<List<Peripheral>> get discoveredDevicesStream;

  /// Current discovered devices list (synchronized copy, not stream)
  List<Peripheral> get currentDiscoveredDevices;

  /// Raw discovery events map (device MAC → discovery data)
  /// Lower-level than discoveredDevices stream, includes signal strength, etc.
  Stream<Map<String, DiscoveredEventArgs>> get discoveryDataStream;

  /// Is scanning currently active?
  bool get isDiscoveryActive;

  /// Source of current scanning request (manual, burst, system)
  ScanningSource? get currentScanningSource;

  // ============================================================================
  // HINT-BASED DEVICE MATCHING
  // ============================================================================

  /// Stream of detected hint matches (contact names)
  /// Emitted when a device's advertising data matches stored contact hints
  /// Used for collision detection and device identification
  Stream<String> get hintMatchesStream;

  /// Build local collision hint for advertising in beacon data
  /// Deterministic identity hint for devices to recognize each other
  /// Returns:
  ///   Hint string (hashed identity) or null if not available
  Future<String?> buildLocalCollisionHint();

  // ============================================================================
  // SUPPORT ENUMS
  // ============================================================================
}

/// Enum to track the source of scanning requests for better coordination
enum ScanningSource {
  manual, // User-initiated scanning (DiscoveryOverlay)
  burst, // Adaptive power manager burst scanning
  system, // Other system-initiated scanning
}

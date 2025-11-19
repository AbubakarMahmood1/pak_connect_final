// Interface for BLE discovery service
// Extracted from BLEService as part of Phase 2A refactoring
// Handles BLE scanning, device deduplication, and discovery events

import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Scanning source enum to track who initiated the scan
enum ScanningSource {
  manual, // User-initiated scanning (DiscoveryOverlay)
  burst, // Adaptive power manager burst scanning
  system, // Other system-initiated scanning
}

/// Interface for BLE discovery operations
/// Responsible for:
/// - Starting/stopping BLE scans
/// - Device deduplication and filtering
/// - Discovery event streaming
/// - Hint scanning integration
abstract class IBLEDiscoveryService {
  /// Stream of discovered devices (deduplicated)
  Stream<List<Peripheral>> get discoveredDevices;

  /// Stream of raw discovery event data
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData;

  /// Check if discovery is currently active
  bool get isDiscoveryActive;

  /// Start BLE scanning for nearby devices
  ///
  /// [source] - Who initiated this scan (manual, burst, system)
  ///
  /// Handles:
  /// - Scanning conflicts (allows manual to override burst)
  /// - Clears discovered devices list
  /// - Starts discovery with service UUID filter
  Future<void> startScanning({ScanningSource source = ScanningSource.system});

  /// Stop BLE scanning
  Future<void> stopScanning();

  /// Start scanning with validation (Bluetooth state check)
  /// Delegates to startScanning but ensures BLE is ready
  Future<void> startScanningWithValidation({
    ScanningSource source = ScanningSource.manual,
  });

  /// Scan for a specific device by ID
  /// Returns the peripheral if found, null otherwise
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout});

  /// Stream of discovered devices (alternative getter)
  Stream<List<Peripheral>> get discoveredDevicesStream;

  /// Get current list of discovered devices
  List<Peripheral> get currentDiscoveredDevices;

  /// Stream of raw discovery event data (alternative getter)
  Stream<Map<String, DiscoveredEventArgs>> get discoveryDataStream;

  /// Get current scanning source (manual, burst, or system)
  ScanningSource? get currentScanningSource;

  /// Stream of hint scanner matches for collision detection
  Stream<String> get hintMatchesStream;

  /// Build local collision hint for device identification
  Future<String?> buildLocalCollisionHint();

  /// Initialize discovery service
  /// Sets up device deduplication listeners
  Future<void> initialize();

  /// Dispose discovery service
  /// Cleans up streams and listeners
  Future<void> dispose();
}

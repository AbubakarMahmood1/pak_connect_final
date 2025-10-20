// File: lib/core/discovery/device_deduplication_manager.dart
import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../security/hint_cache_manager.dart';
import '../../domain/entities/enhanced_contact.dart';

class DeviceDeduplicationManager {
  static final Map<String, DiscoveredDevice> _uniqueDevices = {};
  static final StreamController<Map<String, DiscoveredDevice>> _devicesController = 
      StreamController.broadcast();
  
  static Stream<Map<String, DiscoveredDevice>> get uniqueDevicesStream => 
      _devicesController.stream;
  
  static int get deviceCount => _uniqueDevices.length;
  
  static void processDiscoveredDevice(DiscoveredEventArgs event) {
    final deviceId = event.peripheral.uuid.toString();
    final ephemeralHint = _extractEphemeralHint(event);
    
    if (ephemeralHint == null) return; // Not our device
    
    final existingDevice = _uniqueDevices[deviceId];
    
    if (existingDevice == null) {
      final newDevice = DiscoveredDevice(
        deviceId: deviceId,
        ephemeralHint: ephemeralHint,
        peripheral: event.peripheral,
        rssi: event.rssi,
        advertisement: event.advertisement,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      );
      
      _uniqueDevices[deviceId] = newDevice;
      _verifyContactAsync(newDevice);
      
    } else {
      // ✅ EXISTING DEVICE - Update metadata only
      existingDevice.rssi = event.rssi;
      existingDevice.lastSeen = DateTime.now();
      existingDevice.advertisement = event.advertisement;
      
      // Check if ephemeral hint changed (key rotation)
      if (existingDevice.ephemeralHint != ephemeralHint) {
        existingDevice.ephemeralHint = ephemeralHint;
        _verifyContactAsync(existingDevice);
      }
    }
    
    _devicesController.add(Map.from(_uniqueDevices));
  }
  
  static void _verifyContactAsync(DiscoveredDevice device) async {
    final contactHint = HintCacheManager.getContactFromCache(device.ephemeralHint);
    device.isKnownContact = contactHint != null;
    device.contactInfo = contactHint?.contact;
    
    if (device.isKnownContact) {
      if (kDebugMode) {
        print('✅ RECOGNIZED CONTACT: ${device.contactInfo?.displayName}');
      }
    }
    
    _devicesController.add(Map.from(_uniqueDevices));
  }
  
  static String? _extractEphemeralHint(DiscoveredEventArgs event) {
    for (final manufacturerData in event.advertisement.manufacturerSpecificData) {
      if (manufacturerData.id == 0x2E19 && manufacturerData.data.length >= 4) {
        return manufacturerData.data
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      }
    }
    return null;
  }
  
  /// 🗑️ Remove a specific device immediately (real-time cleanup)
  ///
  /// Called when a device disconnects to ensure no stale data.
  /// This is event-driven cleanup, not periodic.
  static void removeDevice(String deviceId) {
    final removed = _uniqueDevices.remove(deviceId);
    if (removed != null) {
      _devicesController.add(Map.from(_uniqueDevices));
      Logger('DeviceDeduplicationManager').fine('🗑️ Removed device: $deviceId');
    }
  }

  static void removeStaleDevices() {
    final cutoff = DateTime.now().subtract(Duration(minutes: 2));
    _uniqueDevices.removeWhere((deviceId, device) =>
        device.lastSeen.isBefore(cutoff));
    _devicesController.add(Map.from(_uniqueDevices));
  }
  
  static void clearAll() {
    _uniqueDevices.clear();
    _devicesController.add({});
  }
  
  static void dispose() {
    if (!_devicesController.isClosed) {
      _devicesController.close();
    }
    clearAll();
  }
  
  static Duration _staleTimeout = Duration(minutes: 2);
  
  static void setStaleTimeout(Duration timeout) {
    _staleTimeout = timeout;
  }
  
  static void removeStaleDevicesWithConfigurableTimeout() {
    final cutoff = DateTime.now().subtract(_staleTimeout);
    _uniqueDevices.removeWhere((deviceId, device) => 
        device.lastSeen.isBefore(cutoff));
    _devicesController.add(Map.from(_uniqueDevices));
  }
}

class DiscoveredDevice {
  final String deviceId;
  String ephemeralHint;
  final Peripheral peripheral;
  int rssi;
  Advertisement advertisement;
  final DateTime firstSeen;
  DateTime lastSeen;
  bool isKnownContact = false;
  EnhancedContact? contactInfo;
  
  DiscoveredDevice({
    required this.deviceId,
    required this.ephemeralHint,
    required this.peripheral,
    required this.rssi,
    required this.advertisement,
    required this.firstSeen,
    required this.lastSeen,
  });
}
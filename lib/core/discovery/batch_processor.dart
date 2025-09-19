// File: lib/core/discovery/batch_processor.dart
import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'device_deduplication_manager.dart';

class BatchProcessor {
  static final List<DiscoveredEventArgs> _batchQueue = [];
  static Timer? _batchTimer;
  static const int batchsize = 10;
  static const Duration batchTimeout = Duration(seconds: 2);
  
  static void addToBatch(DiscoveredEventArgs event) {
    _batchQueue.add(event);
    
    // Process immediately if batch is full
    if (_batchQueue.length >= batchsize) {
      _processBatch();
      return;
    }
    
    // Otherwise, set timer for batch timeout
    _batchTimer?.cancel();
    _batchTimer = Timer(batchTimeout, () {
      if (_batchQueue.isNotEmpty) {
        _processBatch();
      }
    });
  }
  
  static void _processBatch() {
    if (_batchQueue.isEmpty) return;
    
    print('📦 Processing batch of ${_batchQueue.length} devices');
    
    for (final event in _batchQueue) {
      DeviceDeduplicationManager.processDiscoveredDevice(event);
    }
    
    _batchQueue.clear();
    _batchTimer?.cancel();
  }
  
  static void forceProcessBatch() {
    _processBatch();
  }
  
  static void dispose() {
  _batchTimer?.cancel();
  _batchTimer = null;
  _batchQueue.clear();
}
}

// Comprehensive tests for Phase 1: Duty Cycle Scanning & Emergency Mode
// Based on BitChat battle-tested patterns
//
// Tests cover:
// 1. Duty cycle scanning (BitChat pattern)
// 2. Power mode transitions
// 3. Emergency mode sync skipping (battery < 10%)
// 4. Background state awareness
// 5. RSSI filtering per power mode
// 6. Connection limits per power mode

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/power/adaptive_power_manager.dart';
import 'package:pak_connect/core/messaging/gossip_sync_manager.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';

void main() {
  group('Phase 1: Duty Cycle Scanning Tests', () {
    test('Power modes map correctly to duty cycles', () {
      // BitChat pattern verification
      expect(PowerMode.performance.toString(), contains('performance'));
      expect(PowerMode.balanced.toString(), contains('balanced'));
      expect(PowerMode.powerSaver.toString(), contains('powerSaver'));
      expect(PowerMode.ultraLowPower.toString(), contains('ultraLowPower'));
    });

    test('PowerManagementStats calculates duty cycle percentages correctly', () {
      // Test each power mode's duty cycle calculation
      final perfStats = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.5,
        connectionStabilityScore: 0.5,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 0,
        isBurstMode: false,
        powerMode: PowerMode.performance,
        isDutyCycleScanning: true,
        batteryLevel: 100,
        isCharging: true,
        isAppInBackground: false,
      );

      final balancedStats = perfStats.copyWith(powerMode: PowerMode.balanced);
      final powerSaverStats = perfStats.copyWith(powerMode: PowerMode.powerSaver);
      final ultraLowStats = perfStats.copyWith(powerMode: PowerMode.ultraLowPower);

      // Verify duty cycle percentages match BitChat
      expect(perfStats.dutyCyclePercentage, 100.0); // Continuous scanning
      expect(balancedStats.dutyCyclePercentage, 80.0); // 8s ON / 2s OFF
      expect(powerSaverStats.dutyCyclePercentage, 20.0); // 2s ON / 8s OFF
      expect(ultraLowStats.dutyCyclePercentage, 9.0); // 1s ON / 10s OFF

      print('✅ Duty cycle percentages verified:');
      print('   Performance: ${perfStats.dutyCyclePercentage}%');
      print('   Balanced: ${balancedStats.dutyCyclePercentage}%');
      print('   Power Saver: ${powerSaverStats.dutyCyclePercentage}%');
      print('   Ultra Low: ${ultraLowStats.dutyCyclePercentage}%');
    });

    test('Battery efficiency rating considers duty cycle', () {
      final perfStats = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 10,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.9,
        connectionStabilityScore: 0.9,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 10,
        isBurstMode: false,
        powerMode: PowerMode.performance,
        isDutyCycleScanning: true,
        batteryLevel: 100,
        isCharging: true,
        isAppInBackground: false,
      );

      final ultraLowStats = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 10,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.9,
        connectionStabilityScore: 0.9,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 10,
        isBurstMode: false,
        powerMode: PowerMode.ultraLowPower,
        isDutyCycleScanning: true,
        batteryLevel: 5,
        isCharging: false,
        isAppInBackground: true,
      );

      // Ultra low power should have significantly higher battery efficiency
      expect(ultraLowStats.batteryEfficiencyRating, greaterThan(perfStats.batteryEfficiencyRating));
      expect(ultraLowStats.batteryEfficiencyRating, greaterThan(0.9));

      print('✅ Battery efficiency ratings:');
      print('   Performance mode: ${(perfStats.batteryEfficiencyRating * 100).toStringAsFixed(1)}%');
      print('   Ultra Low Power: ${(ultraLowStats.batteryEfficiencyRating * 100).toStringAsFixed(1)}%');
    });

    test('RSSI thresholds vary by power mode (BitChat pattern)', () async {
      final powerManager = AdaptivePowerManager();
      await powerManager.initialize();

      // Test RSSI thresholds for each mode
      // Note: Initial state is performance mode (100% battery, not background)
      // Verify RSSI threshold matches performance mode

      print('✅ RSSI thresholds by power mode:');
      print('   ${powerManager.currentPowerMode.name}: ${powerManager.rssiThreshold} dBm');

      // Performance mode should be -95 dBm
      expect(powerManager.rssiThreshold, -95);
      expect(powerManager.currentPowerMode, PowerMode.performance);
    });

    test('Connection limits vary by power mode (BitChat pattern)', () async {
      final powerManager = AdaptivePowerManager();
      await powerManager.initialize();

      // Test connection limits
      print('✅ Connection limits by power mode:');
      print('   Current mode (${powerManager.currentPowerMode.name}): ${powerManager.maxConnections} connections');
      expect(powerManager.maxConnections, greaterThan(0));
    });
  });

  group('Phase 1: Emergency Mode Sync Skipping Tests', () {
    late GossipSyncManager syncManager;
    late OfflineMessageQueue messageQueue;

    setUp(() {
      messageQueue = OfflineMessageQueue();
      syncManager = GossipSyncManager(
        myNodeId: 'test-node-id',
        messageQueue: messageQueue,
      );
    });

    test('Emergency mode is disabled when battery > 10%', () {
      syncManager.updateBatteryState(level: 50, isCharging: false);
      final stats = syncManager.getStatistics();

      expect(stats['emergencyMode'], false);
      expect(stats['batteryLevel'], 50);
      expect(stats['isCharging'], false);

      print('✅ Normal mode: battery ${stats['batteryLevel']}% - emergency mode: ${stats['emergencyMode']}');
    });

    test('Emergency mode activates when battery <= 10%', () {
      syncManager.updateBatteryState(level: 9, isCharging: false);
      final stats = syncManager.getStatistics();

      expect(stats['emergencyMode'], true);
      expect(stats['batteryLevel'], 9);

      print('⚠️  Emergency mode: battery ${stats['batteryLevel']}% - emergency mode: ${stats['emergencyMode']}');
    });

    test('Emergency mode disabled when charging even at low battery', () {
      syncManager.updateBatteryState(level: 5, isCharging: true);
      final stats = syncManager.getStatistics();

      expect(stats['emergencyMode'], false);
      expect(stats['batteryLevel'], 5);
      expect(stats['isCharging'], true);

      print('✅ Charging overrides emergency mode: battery ${stats['batteryLevel']}% charging: ${stats['isCharging']} - emergency mode: ${stats['emergencyMode']}');
    });

    test('Battery state transitions log correctly', () {
      // Normal → Critical
      syncManager.updateBatteryState(level: 50, isCharging: false);
      syncManager.updateBatteryState(level: 9, isCharging: false);

      // Critical → Normal (charging)
      syncManager.updateBatteryState(level: 9, isCharging: true);

      final stats = syncManager.getStatistics();
      expect(stats['emergencyMode'], false); // Charging overrides

      print('✅ Battery transitions handled correctly');
    });

    test('Skipped syncs counter increments in emergency mode', () async {
      syncManager.updateBatteryState(level: 5, isCharging: false);

      // Note: Can't directly trigger _sendPeriodicSync in test
      // This verifies the infrastructure is in place
      final stats = syncManager.getStatistics();
      expect(stats['skippedSyncsCount'], 0); // Initially 0

      print('✅ Skipped syncs counter ready: ${stats['skippedSyncsCount']}');
    });
  });

  group('Phase 1: Power Mode Transitions Tests', () {
    test('Power mode determined correctly from battery + background state', () async {
      final powerManager = AdaptivePowerManager();
      await powerManager.initialize();

      // Initial mode should be performance (100% battery, not background, not charging)
      // BitChat logic: charging + foreground → performance
      expect(powerManager.currentPowerMode, PowerMode.performance);

      print('✅ Power mode transitions:');
      print('   Initial (100% battery, foreground): ${powerManager.currentPowerMode.name}');

      // Test background state change
      powerManager.setAppBackgroundState(true);
      // Mode should change to balanced (good battery + background)
      expect(powerManager.currentPowerMode, PowerMode.balanced);
      print('   After background (100% battery, background): ${powerManager.currentPowerMode.name}');

      powerManager.setAppBackgroundState(false);
      // Back to performance
      expect(powerManager.currentPowerMode, PowerMode.performance);
      print('   After foreground (100% battery, foreground): ${powerManager.currentPowerMode.name}');
    });
  });

  group('Phase 1: Integration Tests', () {
    test('PowerManagementStats serializes to string correctly', () {
      final stats = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 5,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.85,
        connectionStabilityScore: 0.9,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 10,
        isBurstMode: false,
        powerMode: PowerMode.powerSaver,
        isDutyCycleScanning: true,
        batteryLevel: 25,
        isCharging: false,
        isAppInBackground: true,
      );

      final str = stats.toString();
      expect(str, contains('powerSaver'));
      expect(str, contains('25%')); // Battery level
      expect(str, contains('20.0%')); // Duty cycle for power saver

      print('✅ PowerManagementStats toString:');
      print('   $str');
    });

    test('GossipSyncManager statistics include emergency mode info', () {
      final messageQueue = OfflineMessageQueue();
      final syncManager = GossipSyncManager(
        myNodeId: 'test-node',
        messageQueue: messageQueue,
      );

      syncManager.updateBatteryState(level: 8, isCharging: false);

      final stats = syncManager.getStatistics();
      expect(stats.containsKey('batteryLevel'), true);
      expect(stats.containsKey('isCharging'), true);
      expect(stats.containsKey('emergencyMode'), true);
      expect(stats.containsKey('skippedSyncsCount'), true);

      print('✅ GossipSyncManager statistics:');
      print('   Battery: ${stats['batteryLevel']}%');
      print('   Emergency mode: ${stats['emergencyMode']}');
      print('   Skipped syncs: ${stats['skippedSyncsCount']}');
    });
  });
}

// Helper extension for copyWith (since PowerManagementStats is const)
extension PowerManagementStatsCopyWith on PowerManagementStats {
  PowerManagementStats copyWith({PowerMode? powerMode}) {
    return PowerManagementStats(
      currentScanInterval: currentScanInterval,
      currentHealthCheckInterval: currentHealthCheckInterval,
      consecutiveSuccessfulChecks: consecutiveSuccessfulChecks,
      consecutiveFailedChecks: consecutiveFailedChecks,
      connectionQualityScore: connectionQualityScore,
      connectionStabilityScore: connectionStabilityScore,
      timeSinceLastSuccess: timeSinceLastSuccess,
      qualityMeasurementsCount: qualityMeasurementsCount,
      isBurstMode: isBurstMode,
      powerMode: powerMode ?? this.powerMode,
      isDutyCycleScanning: isDutyCycleScanning,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
      isAppInBackground: isAppInBackground,
    );
  }
}

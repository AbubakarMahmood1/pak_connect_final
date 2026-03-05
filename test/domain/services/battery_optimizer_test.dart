import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/battery_optimizer.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const batteryChannel = MethodChannel('dev.fluttercommunity.plus/battery');
  const chargingChannel = MethodChannel('dev.fluttercommunity.plus/charging');

  late BatteryOptimizer optimizer;
  late int batteryLevel;
  late String batteryState;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    batteryLevel = 80;
    batteryState = 'discharging';

    batteryChannel.setMockMethodCallHandler((call) async {
      switch (call.method) {
        case 'getBatteryLevel':
          return batteryLevel;
        case 'getBatteryState':
          return batteryState;
        default:
          return null;
      }
    });

    chargingChannel.setMockMethodCallHandler((call) async {
      if (call.method == 'listen' || call.method == 'cancel') {
        return null;
      }
      return null;
    });

    BatteryOptimizer.enableForRuntime();
    optimizer = BatteryOptimizer();
    optimizer.dispose();
  });

  tearDown(() async {
    optimizer.dispose();
    BatteryOptimizer.enableForRuntime();
    batteryChannel.setMockMethodCallHandler(null);
    chargingChannel.setMockMethodCallHandler(null);
  });

  test('BatteryInfo exposes charging and mode description metadata', () {
    final chargingInfo = BatteryInfo(
      level: 95,
      state: BatteryState.charging,
      powerMode: BatteryPowerMode.charging,
      lastUpdate: DateTime.fromMillisecondsSinceEpoch(1),
    );
    final criticalInfo = BatteryInfo(
      level: 9,
      state: BatteryState.discharging,
      powerMode: BatteryPowerMode.critical,
      lastUpdate: DateTime.fromMillisecondsSinceEpoch(2),
    );

    expect(chargingInfo.isCharging, isTrue);
    expect(chargingInfo.modeDescription, contains('Maximum Performance'));
    expect(criticalInfo.isCharging, isFalse);
    expect(criticalInfo.modeDescription, contains('Emergency'));
  });

  test('initialize and forceCheck map battery thresholds into power modes', () async {
    final modeChanges = <BatteryPowerMode>[];
    final updates = <BatteryInfo>[];

    batteryLevel = 90;
    batteryState = 'full';
    await optimizer.initialize(
      onPowerModeChanged: modeChanges.add,
      onBatteryUpdate: updates.add,
    );

    expect(optimizer.currentPowerMode, BatteryPowerMode.charging);
    expect(optimizer.isCharging, isTrue);

    batteryLevel = 45;
    batteryState = 'discharging';
    await optimizer.forceCheck();
    expect(optimizer.currentPowerMode, BatteryPowerMode.moderate);

    batteryLevel = 25;
    await optimizer.forceCheck();
    expect(optimizer.currentPowerMode, BatteryPowerMode.lowPower);

    batteryLevel = 10;
    await optimizer.forceCheck();
    expect(optimizer.currentPowerMode, BatteryPowerMode.critical);

    expect(modeChanges, isNotEmpty);
    expect(updates, isNotEmpty);
    expect(updates.last.level, 10);
  });

  test('forceCheck ignores insignificant level changes when state unchanged', () async {
    var updateCalls = 0;

    batteryLevel = 60;
    batteryState = 'discharging';
    await optimizer.initialize(onBatteryUpdate: (_) => updateCalls++);

    batteryLevel = 63; // <5% delta
    await optimizer.forceCheck();

    batteryLevel = 65; // >=5% delta
    await optimizer.forceCheck();

    expect(updateCalls, 1);
  });

  test('setEnabled toggles optimizer and persists preference', () async {
    var updateCalls = 0;
    batteryLevel = 70;
    batteryState = 'discharging';
    await optimizer.initialize(onBatteryUpdate: (_) => updateCalls++);

    await optimizer.setEnabled(false);
    expect(optimizer.isEnabled, isFalse);

    batteryLevel = 20;
    await optimizer.forceCheck();
    expect(updateCalls, 0);

    await optimizer.setEnabled(true);
    expect(optimizer.isEnabled, isTrue);
    expect(updateCalls, greaterThanOrEqualTo(1));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('battery_optimizer_enabled'), isTrue);
  });

  test('disableForTests short-circuits plugin initialization', () async {
    BatteryOptimizer.disableForTests();

    await optimizer.initialize();

    expect(optimizer.isEnabled, isFalse);
  });
}

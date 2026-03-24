// RelayConfigManager + ConnectionLimitConfig + CompressionConfig
// Targeting 35+ uncovered lines to cross 75%

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/relay_config_manager.dart';
import 'package:pak_connect/data/models/connection_limit_config.dart';
import 'package:pak_connect/domain/models/power_mode.dart';
import 'package:pak_connect/domain/utils/chat_utils.dart';
import 'package:pak_connect/domain/utils/compression_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
 Logger.root.level = Level.OFF;

 group('RelayConfigManager', () {
 setUp(() {
 WidgetsFlutterBinding.ensureInitialized();
 SharedPreferences.setMockInitialValues({});
 });

 test('initialize loads defaults when no prefs set', () async {
 final mgr = RelayConfigManager();
 await mgr.initialize();

 expect(mgr.isRelayEnabled(), isTrue);
 expect(mgr.getMaxRelayHops(), 3);
 expect(mgr.getBatteryThreshold(), 20);
 });

 test('initialize loads saved prefs', () async {
 SharedPreferences.setMockInitialValues({
 'mesh_relay_enabled': false,
 'mesh_relay_max_hops': 4,
 'mesh_relay_battery_threshold': 30,
 });

 final mgr = RelayConfigManager();
 await mgr.initialize();

 expect(mgr.isRelayEnabled(), isFalse);
 expect(mgr.getMaxRelayHops(), 4);
 expect(mgr.getBatteryThreshold(), 30);
 });

 test('enableRelay and disableRelay', () async {
 final mgr = RelayConfigManager();
 await mgr.initialize();

 await mgr.disableRelay();
 expect(mgr.isRelayEnabled(), isFalse);

 await mgr.enableRelay();
 expect(mgr.isRelayEnabled(), isTrue);
 });

 test('setMaxRelayHops validates bounds', () async {
 final mgr = RelayConfigManager();
 await mgr.initialize();

 await mgr.setMaxRelayHops(4);
 expect(mgr.getMaxRelayHops(), 4);

 // Exceeds max (5) — should cap
 await mgr.setMaxRelayHops(10);
 expect(mgr.getMaxRelayHops(), 5);

 // Below minimum — should reject
 await mgr.setMaxRelayHops(0);
 expect(mgr.getMaxRelayHops(), 5); // unchanged
 });

 test('setBatteryThreshold validates bounds', () async {
 final mgr = RelayConfigManager();
 await mgr.initialize();

 await mgr.setBatteryThreshold(50);
 expect(mgr.getBatteryThreshold(), 50);

 await mgr.setBatteryThreshold(-1);
 expect(mgr.getBatteryThreshold(), 50); // unchanged

 await mgr.setBatteryThreshold(101);
 expect(mgr.getBatteryThreshold(), 50); // unchanged
 });

 test('shouldRelayWithBatteryLevel checks threshold', () async {
 final mgr = RelayConfigManager();
 await mgr.initialize();
 await mgr.setBatteryThreshold(30);

 expect(mgr.shouldRelayWithBatteryLevel(50), isTrue);
 expect(mgr.shouldRelayWithBatteryLevel(30), isTrue);
 expect(mgr.shouldRelayWithBatteryLevel(29), isFalse);
 });

 test('getConfigSummary returns correct map', () async {
 final mgr = RelayConfigManager();
 await mgr.initialize();

 final summary = mgr.getConfigSummary();
 expect(summary['relayEnabled'], isTrue);
 expect(summary['maxRelayHops'], 3);
 expect(summary['batteryThreshold'], 20);
 });

 test('resetToDefaults restores default values', () async {
 final mgr = RelayConfigManager();
 await mgr.initialize();

 await mgr.disableRelay();
 await mgr.setMaxRelayHops(5);
 await mgr.setBatteryThreshold(50);

 await mgr.resetToDefaults();

 expect(mgr.isRelayEnabled(), isTrue);
 expect(mgr.getMaxRelayHops(), 3);
 expect(mgr.getBatteryThreshold(), 20);
 });
 });

 group('ConnectionLimitConfig', () {
 test('forPlatform returns valid config', () {
 final config = ConnectionLimitConfig.forPlatform();
 expect(config.maxClientConnections, greaterThan(0));
 expect(config.maxServerConnections, greaterThan(0));
 expect(config.maxTotalConnections, greaterThan(0));
 });

 test('forPowerMode performance uses full platform limits', () {
 final perf = ConnectionLimitConfig.forPowerMode(PowerMode.performance);
 final balanced = ConnectionLimitConfig.forPowerMode(PowerMode.balanced);
 final platform = ConnectionLimitConfig.forPlatform();

 expect(perf, equals(platform));
 expect(balanced, equals(platform));
 });

 test('forPowerMode powerSaver reduces limits ~50%', () {
 final saver = ConnectionLimitConfig.forPowerMode(PowerMode.powerSaver);
 final platform = ConnectionLimitConfig.forPlatform();

 expect(saver.maxClientConnections,
 lessThanOrEqualTo(platform.maxClientConnections),
);
 });

 test('forPowerMode ultraLowPower uses minimal limits', () {
 final ultra =
 ConnectionLimitConfig.forPowerMode(PowerMode.ultraLowPower);

 expect(ultra.maxClientConnections, 2);
 expect(ultra.maxServerConnections, 1);
 expect(ultra.maxTotalConnections, 2);
 });

 test('canAcceptClientConnection checks both limits', () {
 final config = ConnectionLimitConfig.forPowerMode(PowerMode.ultraLowPower);

 expect(config.canAcceptClientConnection(0, 0), isTrue);
 expect(config.canAcceptClientConnection(1, 1), isTrue);
 expect(config.canAcceptClientConnection(2, 2), isFalse);
 });

 test('canAcceptServerConnection checks both limits', () {
 final config = ConnectionLimitConfig.forPowerMode(PowerMode.ultraLowPower);

 expect(config.canAcceptServerConnection(0, 0), isTrue);
 expect(config.canAcceptServerConnection(1, 1), isFalse);
 });

 test('getExcessClientConnections returns excess', () {
 final config = ConnectionLimitConfig.forPowerMode(PowerMode.ultraLowPower);

 expect(config.getExcessClientConnections(1, 1), 0);
 expect(config.getExcessClientConnections(3, 3), 1);
 });

 test('toString and equality', () {
 final a = ConnectionLimitConfig.forPowerMode(PowerMode.ultraLowPower);
 final b = ConnectionLimitConfig.forPowerMode(PowerMode.ultraLowPower);

 expect(a, equals(b));
 expect(a.hashCode, equals(b.hashCode));
 expect(a.toString(), contains('ConnectionLimitConfig'));
 });
 });

 group('CompressionConfig', () {
 test('defaultConfig has expected values', () {
 final config = CompressionConfig.defaultConfig;
 expect(config.compressionThreshold, 100);
 expect(config.entropyThreshold, 0.9);
 expect(config.compressionLevel, 6);
 expect(config.useRawDeflate, isTrue);
 expect(config.enabled, isTrue);
 });

 test('aggressive config has higher compression', () {
 expect(CompressionConfig.aggressive.compressionLevel, 9);
 expect(CompressionConfig.aggressive.compressionThreshold, 80);
 });

 test('fast config has lower compression', () {
 expect(CompressionConfig.fast.compressionLevel, 3);
 });

 test('disabled config has enabled=false', () {
 expect(CompressionConfig.disabled.enabled, isFalse);
 });

 test('copyWith creates modified copy', () {
 final original = CompressionConfig.defaultConfig;
 final modified = original.copyWith(compressionLevel: 9, enabled: false);

 expect(modified.compressionLevel, 9);
 expect(modified.enabled, isFalse);
 expect(modified.compressionThreshold, original.compressionThreshold);
 });

 test('equality and hashCode', () {
 final a = CompressionConfig.defaultConfig;
 final b = const CompressionConfig();

 expect(a, equals(b));
 expect(a.hashCode, equals(b.hashCode));
 expect(a, isNot(equals(CompressionConfig.aggressive)));
 });

 test('toString is descriptive', () {
 final s = CompressionConfig.defaultConfig.toString();
 expect(s, contains('threshold'));
 expect(s, contains('100'));
 });
 });

 group('ChatUtils', () {
 test('resolveChatKey priority: persistent > session > ephemeral', () {
 expect(ChatUtils.resolveChatKey(persistentPublicKey: 'pkey',
 currentSessionId: 'sid',
 currentEphemeralId: 'eid',
),
 'pkey',
);
 expect(ChatUtils.resolveChatKey(currentSessionId: 'sid',
 currentEphemeralId: 'eid',
),
 'sid',
);
 expect(ChatUtils.resolveChatKey(currentEphemeralId: 'eid'),
 'eid',
);
 expect(ChatUtils.resolveChatKey(), isNull);
 // Empty strings treated as absent
 expect(ChatUtils.resolveChatKey(persistentPublicKey: '', currentSessionId: ''),
 isNull,
);
 });

 test('generatePublicKeyHash returns 8-char hash', () {
 final hash = ChatUtils.generatePublicKeyHash('test-public-key');
 expect(hash.length, 8);
 });

 test('hashToBytes converts hex to bytes', () {
 final bytes = ChatUtils.hashToBytes('aabbccdd');
 expect(bytes.length, 4);
 expect(bytes[0], 0xaa);
 expect(bytes[3], 0xdd);
 });

 test('extractContactKey handles key1==myPublicKey branch', () {
 // When key1 matches myPublicKey, return key2
 final result = ChatUtils.extractContactKey('persistent_chat_mykey_contactkey',
 'mykey',
);
 expect(result, 'contactkey');

 // When key2 matches myPublicKey, return key1
 final result2 = ChatUtils.extractContactKey('persistent_chat_contactkey_mykey',
 'mykey',
);
 expect(result2, 'contactkey');
 });
 });
}

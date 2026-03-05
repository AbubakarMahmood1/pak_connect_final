import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/routing/connection_quality_monitor.dart';
import 'package:pak_connect/domain/routing/routing_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

class _FakePeripheral implements Peripheral {
  _FakePeripheral(String uuid) : _uuid = UUID.fromString(uuid);

  final UUID _uuid;

  @override
  UUID get uuid => _uuid;
}

Future<MockConnectionService> _readyConnectionService() async {
  final service = MockConnectionService();
  await service.connectToDevice(
    _FakePeripheral('12345678-1234-1234-1234-1234567890ab'),
  );
  service.emitConnectionInfo(
    const ConnectionInfo(
      isConnected: true,
      isReady: true,
      statusMessage: 'ready',
    ),
  );
  return service;
}

void main() {
  group('ConnectionQualityMonitor', () {
    test('returns neutral defaults when no metrics exist', () async {
      final monitor = ConnectionQualityMonitor();

      expect(monitor.getConnectionMetrics('node-a'), isNull);
      expect(await monitor.getConnectionScore('node-a'), 0.5);
      expect(await monitor.getConnectionScoreId(ChatId('node-a')), 0.5);
      expect(monitor.getAllConnectionQualities(), isEmpty);
    });

    test('records send/ack counters and id-wrapper methods', () async {
      final monitor = ConnectionQualityMonitor();

      monitor.recordMessageSent('node-a', 'msg-1');
      monitor.recordMessageSentId('node-a', MessageId('msg-2'));
      monitor.recordMessageAcknowledged('node-a', 'msg-1', latency: 80.0);
      monitor.recordMessageAcknowledgedId(
        'node-a',
        MessageId('msg-2'),
        latency: 120.0,
      );

      final stats = monitor.getMonitoringStats();
      expect(stats.totalMessagesSent, 2);
      expect(stats.totalMessagesAcked, 2);
      expect(stats.deliveryRate, 1.0);
    });

    test('measures quality when service is connected and ready', () async {
      final monitor = ConnectionQualityMonitor();
      final service = await _readyConnectionService();
      addTearDown(service.dispose);

      monitor.recordMessageSent('node-a', 'msg-1');
      monitor.recordMessageAcknowledged('node-a', 'msg-1', latency: 100.0);

      await monitor.measureConnectionQuality('node-a', service);

      final metrics = monitor.getConnectionMetrics('node-a');
      expect(metrics, isNotNull);
      expect(metrics!.qualityScore, inInclusiveRange(0.0, 1.0));
      expect(metrics.quality, isA<ConnectionQuality>());
      expect(await monitor.getConnectionScore('node-a'), metrics.qualityScore);
    });

    test('skips measurement when disconnected or not ready', () async {
      final monitor = ConnectionQualityMonitor();
      final disconnected = MockConnectionService();
      addTearDown(disconnected.dispose);

      await monitor.measureConnectionQuality('node-a', disconnected);
      expect(monitor.getConnectionMetrics('node-a'), isNull);

      await disconnected.connectToDevice(
        _FakePeripheral('12345678-1234-1234-1234-1234567890ac'),
      );
      disconnected.emitConnectionInfo(
        const ConnectionInfo(
          isConnected: true,
          isReady: false,
          statusMessage: 'connecting',
        ),
      );

      await monitor.measureConnectionQuality('node-a', disconnected);
      expect(monitor.getConnectionMetrics('node-a'), isNull);
    });

    test('simulates degradation and improvement over existing metrics', () async {
      final monitor = ConnectionQualityMonitor();
      final service = await _readyConnectionService();
      addTearDown(service.dispose);

      monitor.recordMessageSent('node-a', 'msg-1');
      monitor.recordMessageAcknowledged('node-a', 'msg-1', latency: 90.0);
      await monitor.measureConnectionQuality('node-a', service);

      final baseline = monitor.getConnectionMetrics('node-a')!;

      await monitor.simulateConnectionDegradation(
        'node-a',
        signalReduction: 0.2,
        latencyIncrease: 700,
        packetLossIncrease: 0.1,
      );
      final degraded = monitor.getConnectionMetrics('node-a')!;

      await monitor.simulateConnectionImprovement(
        'node-a',
        signalBoost: 0.3,
        latencyReduction: 600,
        packetLossReduction: 0.08,
      );
      final improved = monitor.getConnectionMetrics('node-a')!;

      expect(degraded.qualityScore, lessThan(baseline.qualityScore));
      expect(improved.qualityScore, greaterThan(degraded.qualityScore));
      expect(monitor.getAllConnectionQualities().containsKey('node-a'), isTrue);
      expect(monitor.getConnectionMetricsId(ChatId('node-a')), isNotNull);
    });

    test('returns monitoring stats json and summary text', () async {
      final monitor = ConnectionQualityMonitor();
      final service = await _readyConnectionService();
      addTearDown(service.dispose);

      monitor.recordMessageSent('node-a', 'msg-1');
      monitor.recordMessageAcknowledged('node-a', 'msg-1', latency: 110.0);
      await monitor.measureConnectionQuality('node-a', service);

      final stats = monitor.getMonitoringStats();
      final json = stats.toJson();

      expect(json['monitoredConnections'], 1);
      expect(json['totalMessagesSent'], 1);
      expect(json['totalMessagesAcked'], 1);
      expect(stats.toString(), contains('connections: 1'));
      expect(stats.toString(), contains('delivery:'));
    });

    test('initialize is idempotent and dispose clears all data', () async {
      final monitor = ConnectionQualityMonitor();
      final service = await _readyConnectionService();
      addTearDown(service.dispose);

      await monitor.initialize();
      await monitor.initialize();

      monitor.recordMessageSent('node-a', 'msg-1');
      monitor.recordMessageAcknowledged('node-a', 'msg-1', latency: 95.0);
      await monitor.measureConnectionQuality('node-a', service);
      expect(monitor.getMonitoringStats().monitoredConnections, 1);

      monitor.clearAll();
      expect(monitor.getMonitoringStats().monitoredConnections, 0);

      monitor.dispose();
      expect(monitor.getMonitoringStats().monitoredConnections, 0);
    });
  });
}

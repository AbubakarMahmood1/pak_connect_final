import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/ble_experiment_metrics_recorder.dart';

void main() {
  group('BleExperimentMetricsRecorder', () {
    test('summarizes scan and handshake timings', () {
      final recorder = BleExperimentMetricsRecorder(
        logger: Logger('test.metrics'),
        sessionMode: 'concurrent',
      );

      recorder.recordScanStarted();
      recorder.recordPeerDiscovered('peer-a');
      recorder.recordScanStopped();

      recorder.recordOutboundConnectRequested('peer-a');
      recorder.recordMtuReady('peer-a', 185);
      recorder.recordNotifySubscribed('peer-a');
      recorder.recordHandshakeStarted('peer-a');
      recorder.recordHandshakeReady('peer-a');
      recorder.recordDisconnect('peer-a', 'test-end');

      final summary = recorder.snapshot();

      expect(summary.sessionMode, 'concurrent');
      expect(summary.scanStartedCount, 1);
      expect(summary.peerDiscoveredCount, 1);
      expect(summary.connectRequestedCount, 1);
      expect(summary.handshakeStartedCount, 1);
      expect(summary.handshakeReadyCount, 1);
      expect(summary.discoverySuccessRate, 1);
      expect(summary.connectSuccessRate, 1);
      expect(summary.handshakeSuccessRate, 1);
      expect(summary.disconnectCount, 1);
      expect(summary.medianTimeToFirstPeerMs, isNotNull);
      expect(summary.medianConnectToHandshakeReadyMs, isNotNull);
    });

    test('tracks reconnect attempt success and failure counts', () {
      final recorder = BleExperimentMetricsRecorder(
        logger: Logger('test.metrics.reconnect'),
        sessionMode: 'strict_tdm',
      );

      recorder.recordReconnectAttemptStarted(null);
      recorder.recordReconnectAttemptFinished(null, success: false);
      recorder.recordReconnectAttemptStarted('peer-a');
      recorder.recordReconnectAttemptFinished('peer-a', success: true);

      final summary = recorder.snapshot();

      expect(summary.reconnectAttemptStartedCount, 2);
      expect(summary.reconnectAttemptFinishedCount, 2);
      expect(summary.reconnectSuccessCount, 1);
      expect(summary.reconnectFailureCount, 1);
    });
  });
}

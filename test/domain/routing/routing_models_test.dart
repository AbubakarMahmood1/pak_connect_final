import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/routing/routing_models.dart';

void main() {
  group('RoutingDecision', () {
    test('factory constructors set expected fields and flags', () {
      final direct = RoutingDecision.direct('node-b');
      final relay = RoutingDecision.relay('node-c', ['node-a', 'node-c'], 0.72);
      final failed = RoutingDecision.failed('No route available');

      expect(direct.type, RoutingType.direct);
      expect(direct.nextHop, 'node-b');
      expect(direct.isSuccessful, isTrue);
      expect(direct.isDirect, isTrue);
      expect(direct.isRelay, isFalse);

      expect(relay.type, RoutingType.relay);
      expect(relay.routePath, ['node-a', 'node-c']);
      expect(relay.routeScore, 0.72);
      expect(relay.isRelay, isTrue);

      expect(failed.type, RoutingType.failed);
      expect(failed.reason, 'No route available');
      expect(failed.isSuccessful, isFalse);
    });

    test('json serialization round-trip preserves decision data', () {
      final original = RoutingDecision.relay('node-d', [
        'node-a',
        'node-c',
        'node-d',
      ], 0.61);

      final json = original.toJson();
      final restored = RoutingDecision.fromJson(json);

      expect(restored.type, RoutingType.relay);
      expect(restored.nextHop, 'node-d');
      expect(restored.routePath, ['node-a', 'node-c', 'node-d']);
      expect(restored.routeScore, closeTo(0.61, 0.0001));
      expect(restored.reason, 'Mesh relay required');
    });
  });

  group('MessageRoute', () {
    test('singleHop provides expected defaults and convenience getters', () {
      final route = MessageRoute.singleHop('node-a', 'node-b', 'node-c');

      expect(route.hops, ['node-a', 'node-b', 'node-c']);
      expect(route.from, 'node-a');
      expect(route.to, 'node-c');
      expect(route.hopCount, 2);
      expect(route.isSingleHop, isFalse);
      expect(route.isMultiHop, isTrue);
      expect(route.quality, RouteQuality.good);
      expect(route.estimatedLatency, 1000);
      expect(route.reliability, closeTo(0.85, 0.0001));
    });

    test('multiHop adapts score quality latency and reliability', () {
      final route = MessageRoute.multiHop([
        'node-a',
        'node-b',
        'node-c',
        'node-d',
        'node-e',
      ]);

      expect(route.score, closeTo(0.3, 0.0001));
      expect(route.quality, RouteQuality.poor);
      expect(route.estimatedLatency, 4000);
      expect(route.reliability, closeTo(0.18, 0.0001));
      expect(route.hopCount, 4);
      expect(route.isMultiHop, isTrue);
    });

    test('json serialization round-trip preserves route data', () {
      final original = MessageRoute(
        hops: ['node-a', 'node-c'],
        score: 0.9,
        quality: RouteQuality.excellent,
        estimatedLatency: 500,
        reliability: 0.95,
      );

      final json = original.toJson();
      final restored = MessageRoute.fromJson(json);

      expect(restored.hops, ['node-a', 'node-c']);
      expect(restored.score, closeTo(0.9, 0.0001));
      expect(restored.quality, RouteQuality.excellent);
      expect(restored.estimatedLatency, 500);
      expect(restored.reliability, closeTo(0.95, 0.0001));
    });
  });

  group('NetworkTopology', () {
    test('withConnection adds bidirectional link and quality lookup key', () {
      final topology = NetworkTopology(
        connections: {},
        connectionQualities: {},
      ).withConnection('node-a', 'node-b', ConnectionQuality.good);

      expect(topology.canReach('node-a', 'node-b'), isTrue);
      expect(topology.canReach('node-b', 'node-a'), isTrue);
      expect(topology.getConnectedNodes('node-a'), {'node-b'});
      expect(topology.getConnectedNodes('node-b'), {'node-a'});
      expect(
        topology.getConnectionQuality('node-a', 'node-b'),
        ConnectionQuality.good,
      );
      expect(
        topology.getConnectionQuality('node-b', 'node-a'),
        ConnectionQuality.good,
      );
    });

    test('withoutConnection removes both graph edge and quality entry', () {
      final base = NetworkTopology(
        connections: {},
        connectionQualities: {},
      ).withConnection('node-a', 'node-b', ConnectionQuality.excellent);

      final updated = base.withoutConnection('node-a', 'node-b');

      expect(updated.canReach('node-a', 'node-b'), isFalse);
      expect(updated.canReach('node-b', 'node-a'), isFalse);
      expect(updated.getConnectionQuality('node-a', 'node-b'), isNull);
      expect(updated.getConnectionQuality('node-b', 'node-a'), isNull);
      expect(updated.getConnectedNodes('unknown'), isEmpty);
    });

    test('json serialization round-trip preserves sets and enums', () {
      final original = NetworkTopology(
        connections: {
          'node-a': {'node-b', 'node-c'},
          'node-b': {'node-a'},
        },
        connectionQualities: {
          'node-a:node-b': ConnectionQuality.good,
          'node-a:node-c': ConnectionQuality.fair,
        },
      );

      final json = original.toJson();
      final restored = NetworkTopology.fromJson(json);

      expect(restored.getConnectedNodes('node-a'), {'node-b', 'node-c'});
      expect(restored.getConnectedNodes('node-b'), {'node-a'});
      expect(
        restored.getConnectionQuality('node-a', 'node-b'),
        ConnectionQuality.good,
      );
      expect(
        restored.getConnectionQuality('node-a', 'node-c'),
        ConnectionQuality.fair,
      );
    });
  });

  group('ConnectionMetrics', () {
    test('quality score is clamped and maps to quality bands', () {
      final excellent = ConnectionMetrics(
        signalStrength: 1.2,
        latency: 50,
        packetLoss: 0,
        throughput: 1.4,
      );
      final good = ConnectionMetrics(
        signalStrength: 0.7,
        latency: 1400,
        packetLoss: 0.1,
        throughput: 0.7,
      );
      final fair = ConnectionMetrics(
        signalStrength: 0.45,
        latency: 2600,
        packetLoss: 0.2,
        throughput: 0.4,
      );
      final poor = ConnectionMetrics(
        signalStrength: 0.25,
        latency: 3800,
        packetLoss: 0.45,
        throughput: 0.25,
      );
      final unreliable = ConnectionMetrics(
        signalStrength: -1,
        latency: 7000,
        packetLoss: 1.2,
        throughput: -0.5,
      );

      expect(excellent.qualityScore, inInclusiveRange(0.8, 1.0));
      expect(excellent.quality, ConnectionQuality.excellent);
      expect(good.quality, ConnectionQuality.good);
      expect(fair.quality, ConnectionQuality.fair);
      expect(poor.quality, ConnectionQuality.poor);
      expect(unreliable.quality, ConnectionQuality.unreliable);
      expect(unreliable.qualityScore, inInclusiveRange(0.0, 1.0));
    });

    test('json serialization round-trip preserves numeric fields', () {
      final original = ConnectionMetrics(
        signalStrength: 0.88,
        latency: 750,
        packetLoss: 0.05,
        throughput: 0.93,
      );

      final json = original.toJson();
      final restored = ConnectionMetrics.fromJson(json);

      expect(restored.signalStrength, closeTo(0.88, 0.0001));
      expect(restored.latency, closeTo(750, 0.0001));
      expect(restored.packetLoss, closeTo(0.05, 0.0001));
      expect(restored.throughput, closeTo(0.93, 0.0001));
    });
  });
}

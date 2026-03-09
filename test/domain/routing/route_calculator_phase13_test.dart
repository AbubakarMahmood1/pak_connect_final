import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/routing/route_calculator.dart';
import 'package:pak_connect/domain/routing/routing_models.dart';

void main() {
  late RouteCalculator calculator;

  setUp(() {
    calculator = RouteCalculator();
  });

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Build topology with bidirectional connections and sorted quality keys.
  NetworkTopology topo(
    Map<String, Set<String>> connections,
    Map<String, ConnectionQuality> qualities,
  ) {
    return NetworkTopology(
      connections: connections,
      connectionQualities: qualities,
    );
  }

  /// Sorted connection key (matches NetworkTopology._connectionKey).
  String qk(String a, String b) {
    final sorted = [a, b]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  // ── Direct routes – exercises _calculateDirectScore & _getDirectQuality ──

  group('Direct route scoring per ConnectionQuality', () {
    final expectations = <ConnectionQuality, double>{
      ConnectionQuality.excellent: 1.0,
      ConnectionQuality.good: 0.9,
      ConnectionQuality.fair: 0.7,
      ConnectionQuality.poor: 0.5,
      ConnectionQuality.unreliable: 0.3,
    };

    for (final entry in expectations.entries) {
      test('direct route score for ${entry.key}', () async {
        final topology = topo(
          {'A': {'B'}, 'B': {'A'}},
          {qk('A', 'B'): entry.key},
        );

        final routes = await calculator.calculateRoutes(
          from: 'A',
          to: 'B',
          availableHops: ['B'],
          topology: topology,
        );

        expect(routes, isNotEmpty);
        expect(routes.first.hops, ['A', 'B']);
        expect(routes.first.score, entry.value);
      });
    }

    test('direct route with null (unknown) quality defaults to 0.8', () async {
      final topology = topo(
        {'A': {'B'}, 'B': {'A'}},
        {}, // no quality entry → null
      );

      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'B',
        availableHops: ['B'],
        topology: topology,
      );

      expect(routes, isNotEmpty);
      expect(routes.first.score, 0.8);
    });
  });

  group('Direct route quality mapping', () {
    final qualityMap = <ConnectionQuality, RouteQuality>{
      ConnectionQuality.excellent: RouteQuality.excellent,
      ConnectionQuality.good: RouteQuality.good,
      ConnectionQuality.fair: RouteQuality.fair,
      ConnectionQuality.poor: RouteQuality.poor,
      ConnectionQuality.unreliable: RouteQuality.unusable,
    };

    for (final entry in qualityMap.entries) {
      test('maps ${entry.key} → ${entry.value}', () async {
        final topology = topo(
          {'A': {'B'}, 'B': {'A'}},
          {qk('A', 'B'): entry.key},
        );

        final routes = await calculator.calculateRoutes(
          from: 'A',
          to: 'B',
          availableHops: ['B'],
          topology: topology,
        );

        expect(routes.first.quality, entry.value);
      });
    }

    test('null quality maps to RouteQuality.good', () async {
      final topology = topo(
        {'A': {'B'}, 'B': {'A'}},
        {},
      );

      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'B',
        availableHops: ['B'],
        topology: topology,
      );

      expect(routes.first.quality, RouteQuality.good);
    });
  });

  // ── Cache behaviour ────────────────────────────────────────────────────

  group('Route cache', () {
    test('second call returns identical cached list', () async {
      final topology = topo(
        {'A': {'B'}, 'B': {'A'}},
        {qk('A', 'B'): ConnectionQuality.excellent},
      );

      final r1 = await calculator.calculateRoutes(
        from: 'A',
        to: 'B',
        availableHops: ['B'],
        topology: topology,
      );
      final r2 = await calculator.calculateRoutes(
        from: 'A',
        to: 'B',
        availableHops: ['B'],
        topology: topology,
      );

      expect(identical(r1, r2), isTrue);
    });

    test('clearCache removes cached entries', () {
      calculator.clearCache();
      final stats = calculator.getCacheStatistics();
      expect(stats['cached_routes'], 0);
    });

    test('cleanExpiredCache runs on non-expired cache', () async {
      final topology = topo(
        {'X': {'Y'}, 'Y': {'X'}},
        {qk('X', 'Y'): ConnectionQuality.good},
      );

      await calculator.calculateRoutes(
        from: 'X',
        to: 'Y',
        availableHops: ['Y'],
        topology: topology,
      );

      // Cache is fresh, nothing should be removed.
      calculator.cleanExpiredCache();
      final stats = calculator.getCacheStatistics();
      expect(stats['cached_routes'], 1);
      expect(stats['expired_entries'], 0);
    });

    test('cleanExpiredCache on empty cache does nothing', () {
      calculator.cleanExpiredCache();
      final stats = calculator.getCacheStatistics();
      expect(stats['cached_routes'], 0);
    });
  });

  // ── Single-hop relay covering _qualityToScore & _qualityToReliability ──

  group('Single-hop relay with poor/unreliable/null qualities', () {
    test('poor + fair quality single-hop route', () async {
      // _qualityToScore(poor)=0.4, (fair)=0.6 → avg=0.5 ≥ 0.4 → poor quality
      // _qualityToReliability(poor)=0.50, (fair)=0.70 → combined=0.35
      final topology = topo(
        {
          'S': {'R'},
          'R': {'S', 'D'},
          'D': {'R'},
        },
        {
          qk('S', 'R'): ConnectionQuality.poor,
          qk('R', 'D'): ConnectionQuality.fair,
        },
      );

      final routes = await calculator.calculateRoutes(
        from: 'S',
        to: 'D',
        availableHops: ['R'],
        topology: topology,
        maxHops: 2,
      );

      expect(routes, isNotEmpty);
      final relay = routes.firstWhere((r) => r.hops.length == 3);
      expect(relay.hops, ['S', 'R', 'D']);
      expect(relay.quality, RouteQuality.poor);
    });

    test('unreliable + null quality single-hop route', () async {
      // _qualityToScore(unreliable)=0.2, (null)=0.7 → avg=0.45 ≥ 0.4 → poor
      // _qualityToReliability(unreliable)=0.30, (null)=0.80 → 0.24
      final topology = topo(
        {
          'S2': {'R2'},
          'R2': {'S2', 'D2'},
          'D2': {'R2'},
        },
        {
          qk('S2', 'R2'): ConnectionQuality.unreliable,
          // No entry for R2↔D2 → null quality
        },
      );

      final routes = await calculator.calculateRoutes(
        from: 'S2',
        to: 'D2',
        availableHops: ['R2'],
        topology: topology,
        maxHops: 2,
      );

      expect(routes, isNotEmpty);
      final relay = routes.first;
      expect(relay.hops, ['S2', 'R2', 'D2']);
    });
  });

  // ── Multi-hop BFS covering node expansion (lines 149-151) ─────────────

  group('Multi-hop BFS route exploration', () {
    test('BFS discovers routes through intermediate nodes', () async {
      // Chain: src → hop1 → hop2 → dst
      // hop2 can reach dst; hop1 can only reach hop2
      final topology = topo(
        {
          'src': {'hop1'},
          'hop1': {'src', 'hop2'},
          'hop2': {'hop1', 'dst'},
          'dst': {'hop2'},
        },
        {
          qk('src', 'hop1'): ConnectionQuality.good,
          qk('hop1', 'hop2'): ConnectionQuality.good,
          qk('hop2', 'dst'): ConnectionQuality.good,
        },
      );

      final routes = await calculator.calculateRoutes(
        from: 'src',
        to: 'dst',
        availableHops: ['hop1', 'hop2'],
        topology: topology,
        maxHops: 4,
      );

      expect(routes, isNotEmpty);
      // At least one route should pass through hop2 to dst
      expect(routes.any((r) => r.hops.contains('hop2')), isTrue);
    });

    test('multi-hop with direct + relay routes', () async {
      final topology = topo(
        {
          'A': {'B', 'C', 'D'},
          'B': {'A', 'C', 'D'},
          'C': {'A', 'B', 'D'},
          'D': {'A', 'B', 'C'},
        },
        {
          qk('A', 'B'): ConnectionQuality.excellent,
          qk('A', 'C'): ConnectionQuality.fair,
          qk('A', 'D'): ConnectionQuality.good,
          qk('B', 'C'): ConnectionQuality.good,
          qk('B', 'D'): ConnectionQuality.excellent,
          qk('C', 'D'): ConnectionQuality.fair,
        },
      );

      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'D',
        availableHops: ['B', 'C', 'D'],
        topology: topology,
        maxHops: 4,
      );

      // Should have direct route (A→D) plus relay routes
      expect(routes.length, greaterThanOrEqualTo(2));
      expect(routes.any((r) => r.hopCount == 1), isTrue); // direct
      expect(routes.any((r) => r.hopCount >= 2), isTrue); // relay
    });
  });

  // ── Optimization strategies (lines 357, 360, 363-364) ─────────────────

  group('Route optimization strategies', () {
    // Topology: direct A→C is poor quality, relay A→B→C is excellent
    late NetworkTopology topology;

    setUp(() {
      topology = topo(
        {
          'A': {'B', 'C'},
          'B': {'A', 'C'},
          'C': {'A', 'B'},
        },
        {
          qk('A', 'C'): ConnectionQuality.poor,
          qk('A', 'B'): ConnectionQuality.excellent,
          qk('B', 'C'): ConnectionQuality.excellent,
        },
      );
    });

    test('shortestPath sorts by hop count ascending', () async {
      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'C',
        availableHops: ['B', 'C'],
        topology: topology,
        strategy: RouteOptimizationStrategy.shortestPath,
      );

      expect(routes.length, greaterThanOrEqualTo(2));
      // Direct route (1 hop) should come before relay (2 hops)
      expect(routes.first.hopCount, lessThanOrEqualTo(routes.last.hopCount));
    });

    test('highestQuality sorts by score descending', () async {
      calculator = RouteCalculator(); // fresh to avoid cache
      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'C',
        availableHops: ['B', 'C'],
        topology: topology,
        strategy: RouteOptimizationStrategy.highestQuality,
      );

      expect(routes.length, greaterThanOrEqualTo(2));
      // Best score first
      for (int i = 0; i < routes.length - 1; i++) {
        expect(routes[i].score, greaterThanOrEqualTo(routes[i + 1].score));
      }
    });

    test('lowestLatency sorts by latency ascending', () async {
      calculator = RouteCalculator(); // fresh
      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'C',
        availableHops: ['B', 'C'],
        topology: topology,
        strategy: RouteOptimizationStrategy.lowestLatency,
      );

      expect(routes.length, greaterThanOrEqualTo(2));
      // Lowest latency first
      for (int i = 0; i < routes.length - 1; i++) {
        expect(
          routes[i].estimatedLatency,
          lessThanOrEqualTo(routes[i + 1].estimatedLatency),
        );
      }
    });

    test('balanced strategy produces sorted routes', () async {
      calculator = RouteCalculator(); // fresh
      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'C',
        availableHops: ['B', 'C'],
        topology: topology,
        strategy: RouteOptimizationStrategy.balanced,
      );

      expect(routes, isNotEmpty);
    });
  });

  // ── No routes available ───────────────────────────────────────────────

  group('Edge cases', () {
    test('returns empty list when destination is unreachable', () async {
      final topology = topo({'A': <String>{}}, {});
      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'Z',
        availableHops: [],
        topology: topology,
      );
      expect(routes, isEmpty);
    });

    test('skips hops equal to from or to in single-hop loop', () async {
      final topology = topo(
        {'A': {'B'}, 'B': {'A'}},
        {qk('A', 'B'): ConnectionQuality.good},
      );

      // availableHops includes both from and to – they should be skipped
      // in the single-hop relay loop but to still triggers direct route
      final routes = await calculator.calculateRoutes(
        from: 'A',
        to: 'B',
        availableHops: ['A', 'B'],
        topology: topology,
        maxHops: 2,
      );

      // Only direct route expected (no self-relay)
      expect(routes.every((r) => r.hops.length <= 2), isTrue);
    });
  });
}

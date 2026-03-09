import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/proof_of_work_service.dart';

void main() {
  group('ProofOfWorkService', () {
    group('buildChallenge', () {
      test('produces deterministic challenge from hash + timestamp', () {
        final c1 = ProofOfWorkService.buildChallenge('abc123', 1700000000000);
        final c2 = ProofOfWorkService.buildChallenge('abc123', 1700000000000);
        expect(c1, equals(c2));
      });

      test('different inputs produce different challenges', () {
        final c1 = ProofOfWorkService.buildChallenge('abc', 1000);
        final c2 = ProofOfWorkService.buildChallenge('abc', 2000);
        final c3 = ProofOfWorkService.buildChallenge('def', 1000);
        expect(c1, isNot(equals(c2)));
        expect(c1, isNot(equals(c3)));
      });
    });

    group('compute', () {
      test('returns null for difficulty 0 (free tier)', () {
        final result = ProofOfWorkService.compute(
          challenge: 'test-challenge',
          difficulty: 0,
        );
        expect(result, isNull);
      });

      test('returns null for negative difficulty', () {
        final result = ProofOfWorkService.compute(
          challenge: 'test-challenge',
          difficulty: -1,
        );
        expect(result, isNull);
      });

      test('finds valid nonce at difficulty 1', () {
        final result = ProofOfWorkService.compute(
          challenge: 'test-challenge',
          difficulty: 1,
        );
        expect(result, isNotNull);
        expect(result!.nonce, greaterThanOrEqualTo(0));
        expect(result.iterations, greaterThan(0));
        expect(result.hash, isNotEmpty);
      });

      test('finds valid nonce at difficulty 8', () {
        final result = ProofOfWorkService.compute(
          challenge: 'difficulty-8-test',
          difficulty: 8,
        );
        expect(result, isNotNull);
        // First byte of hash must be 0x00
        expect(result!.hash.substring(0, 2), equals('00'));
      });

      test('finds valid nonce at difficulty 12', () {
        final result = ProofOfWorkService.compute(
          challenge: 'difficulty-12-test',
          difficulty: 12,
        );
        expect(result, isNotNull);
        // First 1.5 bytes: first byte = 0x00, upper nibble of second = 0
        expect(result!.hash.substring(0, 2), equals('00'));
        final secondByte = int.parse(result.hash.substring(2, 4), radix: 16);
        expect(secondByte & 0xF0, equals(0)); // upper nibble is 0
      });

      test('caps difficulty at maxDifficulty', () {
        // Difficulty 30 should be capped to 24 — still finds a solution
        final result = ProofOfWorkService.compute(
          challenge: 'cap-test',
          difficulty: 30,
        );
        // Should complete (capped to 24) but may take a while; just verify it works
        expect(result, isNotNull);
      });

      test('iterations increase with difficulty', () {
        final result4 = ProofOfWorkService.compute(
          challenge: 'iteration-test',
          difficulty: 4,
        );
        final result8 = ProofOfWorkService.compute(
          challenge: 'iteration-test',
          difficulty: 8,
        );
        // On average, difficulty 8 needs ~16x more iterations than difficulty 4
        // but this is probabilistic, so just check both succeed
        expect(result4, isNotNull);
        expect(result8, isNotNull);
        expect(result8!.iterations, greaterThanOrEqualTo(result4!.iterations));
      });
    });

    group('verify', () {
      test('returns true for difficulty 0 (free tier)', () {
        final valid = ProofOfWorkService.verify(
          challenge: 'any',
          nonce: null,
          difficulty: 0,
        );
        expect(valid, isTrue);
      });

      test('returns false for null nonce with positive difficulty', () {
        final valid = ProofOfWorkService.verify(
          challenge: 'test',
          nonce: null,
          difficulty: 8,
        );
        expect(valid, isFalse);
      });

      test('verifies a computed solution', () {
        const challenge = 'verify-test-challenge';
        const difficulty = 8;

        final result = ProofOfWorkService.compute(
          challenge: challenge,
          difficulty: difficulty,
        );
        expect(result, isNotNull);

        final valid = ProofOfWorkService.verify(
          challenge: challenge,
          nonce: result!.nonce,
          difficulty: difficulty,
        );
        expect(valid, isTrue);
      });

      test('rejects invalid nonce', () {
        final _ = ProofOfWorkService.verify(
          challenge: 'test-challenge',
          nonce: 999999999, // extremely unlikely to be valid
          difficulty: 16,
        );
        // This could theoretically be true, but with difficulty 16 it's 1 in 65536
        // We test the mechanism works; if this somehow passes, the hash genuinely had 16 leading zero bits
        // For reliability, use a higher difficulty where false positive is near impossible
        final valid20 = ProofOfWorkService.verify(
          challenge: 'definitely-not-valid-at-this-difficulty',
          nonce: 42,
          difficulty: 20,
        );
        expect(valid20, isFalse);
      });

      test('cross-validates compute and verify at multiple difficulties', () {
        for (final difficulty in [4, 8, 12]) {
          final challenge = 'cross-validate-$difficulty';
          final result = ProofOfWorkService.compute(
            challenge: challenge,
            difficulty: difficulty,
          );
          expect(result, isNotNull, reason: 'difficulty $difficulty');

          final valid = ProofOfWorkService.verify(
            challenge: challenge,
            nonce: result!.nonce,
            difficulty: difficulty,
          );
          expect(valid, isTrue, reason: 'difficulty $difficulty');

          // Wrong challenge should fail (at difficulty >= 4, false positive is ~1/16)
          // Use difficulty 8+ for reliable negative test
          if (difficulty >= 8) {
            final invalid = ProofOfWorkService.verify(
              challenge: 'wrong-challenge-$difficulty',
              nonce: result.nonce,
              difficulty: difficulty,
            );
            expect(invalid, isFalse, reason: 'wrong challenge at $difficulty');
          }
        }
      });
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/utils/app_logger.dart';

void main() {
  group('AppLogger redaction', () {
    test('redacts labeled key material in release mode', () {
      const raw =
          'Keys: PubKey=abcd1234efgh5678... | CurrentEphemeralID=deadbeefcafe1234... | NoiseSession=ffeeaabbccdd0011...';

      final sanitized = AppLogger.sanitizeForOutput(raw, releaseMode: true);

      expect(sanitized, contains('PubKey=<redacted>'));
      expect(sanitized, contains('CurrentEphemeralID=<redacted>'));
      expect(sanitized, contains('NoiseSession=<redacted>'));
      expect(sanitized, isNot(contains('abcd1234efgh5678')));
    });

    test('preserves message ids while redacting key-context tokens', () {
      const raw =
          'event=message_sent messageId=2.1.abcd1234efgh5678... to peer key deadbeefcafebabe00112233';

      final sanitized = AppLogger.sanitizeForOutput(raw, releaseMode: true);

      expect(sanitized, contains('messageId=2.1.abcd1234efgh5678...'));
      expect(sanitized, isNot(contains('deadbeefcafebabe00112233')));
      expect(sanitized, contains('<redacted>'));
    });

    test('normalizes encryption fallback phrase in release mode', () {
      const raw =
          'Encryption skipped (desktop/test platform - sqflite_common does not support SQLCipher)';

      final sanitized = AppLogger.sanitizeForOutput(raw, releaseMode: true);

      expect(sanitized, equals('event=encryption_unavailable'));
    });
  });

  group('AppLogger event helper', () {
    test('formats event with message id and duration', () {
      final line = AppLogger.event(
        type: 'queue_maintenance',
        messageId: 'msg-123',
        duration: Duration(milliseconds: 250),
        fields: {'result': 'ok'},
      );

      expect(line, contains('event=queue_maintenance'));
      expect(line, contains('messageId=msg-123'));
      expect(line, contains('durationMs=250'));
      expect(line, contains('result=ok'));
    });
  });
}

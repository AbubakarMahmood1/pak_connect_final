import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/connection_info.dart';

void main() {
  group('ConnectionInfo.copyWith', () {
    test('retains nullable fields when they are not provided', () {
      const info = ConnectionInfo(
        isConnected: true,
        isReady: true,
        otherUserName: 'Alice',
        statusMessage: 'Ready',
      );

      final updated = info.copyWith(isScanning: true);

      expect(updated.otherUserName, 'Alice');
      expect(updated.statusMessage, 'Ready');
      expect(updated.isScanning, isTrue);
    });

    test('allows clearing nullable fields by passing null', () {
      const info = ConnectionInfo(
        isConnected: true,
        isReady: true,
        otherUserName: 'Alice',
        statusMessage: 'Ready',
      );

      final updated = info.copyWith(otherUserName: null, statusMessage: null);

      expect(updated.otherUserName, isNull);
      expect(updated.statusMessage, isNull);
    });

    test('allows updating nullable fields to new non-null value', () {
      const info = ConnectionInfo(
        isConnected: true,
        isReady: true,
        otherUserName: 'Alice',
      );

      final updated = info.copyWith(otherUserName: 'Bob');

      expect(updated.otherUserName, 'Bob');
    });
  });
}

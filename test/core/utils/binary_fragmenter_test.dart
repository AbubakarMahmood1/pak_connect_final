import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/utils/binary_fragmenter.dart';

void main() {
  group('BinaryFragmenter', () {
    test('throws when MTU cannot fit header + minimum payload', () {
      final data = Uint8List.fromList(List.generate(4, (i) => i));
      expect(
        () => BinaryFragmenter.fragment(
          data: data,
          mtu: 24, // leaves <20B for payload after header/ATT overhead
          originalType: 0x01,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fragments respect ATT overhead and MTU budget', () {
      final data = Uint8List.fromList(List.generate(600, (i) => i & 0xFF));
      final frags = BinaryFragmenter.fragment(
        data: data,
        mtu: 128,
        originalType: 0x01,
      );

      expect(frags, isNotEmpty);
      for (final frag in frags) {
        expect(frag.length, lessThanOrEqualTo(128));
      }
    });
  });
}

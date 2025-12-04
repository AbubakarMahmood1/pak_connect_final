import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/utils/binary_fragmenter.dart';
import 'package:pak_connect/data/services/message_fragmentation_handler.dart';

void main() {
  group('MessageFragmentationHandler binary path', () {
    test('reassembles binary payload for local recipient', () async {
      final handler = MessageFragmentationHandler();
      handler.setLocalNodeId('node-a');

      final data = Uint8List.fromList(List.generate(32, (i) => i));
      final frags = BinaryFragmenter.fragment(
        data: data,
        mtu: 64,
        originalType: 0x90,
        recipient: 'node-a',
      );

      String? marker;
      for (final frag in frags) {
        marker = await handler.processReceivedData(
          data: frag,
          fromDeviceId: 'dev',
          fromNodeId: 'node-b',
        );
      }

      expect(marker, isNotNull);
      expect(marker!.startsWith('REASSEMBLY_COMPLETE_BIN:'), isTrue);

      final parts = marker!.split(':');
      final payload = handler.takeReassembledPayload(parts[1]);
      expect(payload, isNotNull);
      expect(payload!.originalType, 0x90);
      expect(payload.bytes, data);
      expect(payload.ttl, 0);
      expect(payload.suppressForwarding, isTrue);
      expect(payload.recipient, 'node-a');
    });

    test(
      'returns forward marker and decrements TTL for non-local recipient',
      () async {
        final handler = MessageFragmentationHandler();
        handler.setLocalNodeId('node-a');

        final data = Uint8List.fromList(List.generate(16, (i) => i + 1));
        final frags = BinaryFragmenter.fragment(
          data: data,
          mtu: 64,
          originalType: 0x91,
          recipient: 'node-b',
          ttl: 3,
        );

        final marker = await handler.processReceivedData(
          data: frags.first,
          fromDeviceId: 'dev',
          fromNodeId: 'node-b',
        );

        expect(marker, isNotNull);
        expect(marker!.startsWith('FORWARD_BIN:'), isTrue);

        final parts = marker.split(':');
        final forward = handler.takeForwardFragment(
          parts[1],
          int.parse(parts[2]),
        );
        expect(forward, isNotNull);
        // TTL should be decremented in forwarded envelope (offset 13).
        expect(forward![13], equals(2));
        expect(parts[3], 'dev');
        expect(parts[4], 'node-b');
      },
    );
    test(
      'buffers full payload for downstream re-fragmentation when forwarding',
      () async {
        final handler = MessageFragmentationHandler();
        handler.setLocalNodeId('node-a');

        final data = Uint8List.fromList(List.generate(180, (i) => i % 256));
        final frags = BinaryFragmenter.fragment(
          data: data,
          mtu: 64,
          originalType: 0x92,
          recipient: 'node-b',
          ttl: 4,
        );

        String? fragmentId;
        for (final frag in frags) {
          final envelope = BinaryFragmentEnvelope.decode(frag);
          fragmentId ??= envelope?.fragmentId;
          await handler.processReceivedData(
            data: frag,
            fromDeviceId: 'dev-c',
            fromNodeId: 'node-c',
          );
        }

        final buffered = handler.takeForwardReassembledPayload(
          fragmentId ?? 'missing',
        );
        expect(buffered, isNotNull);
        expect(buffered!.bytes, data);
        expect(buffered.originalType, 0x92);
        expect(buffered.recipient, 'node-b');
        expect(buffered.ttl, 4);
      },
    );
  });
}

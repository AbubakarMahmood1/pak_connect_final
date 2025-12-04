import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';

/// Builds binary fragment envelopes compatible with the fragment reassembler.
///
/// Format:
/// [0]      : 0xF0 magic
/// [1..8]   : fragmentId (8 random bytes, hex on receive)
/// [9..10]  : index (u16 BE)
/// [11..12] : total (u16 BE)
/// [13]     : ttl (u8) - decremented per hop
/// [14]     : originalType (u8) - caller-defined message type
/// [15]     : recipient length (u8)
/// [16..]   : recipient bytes (UTF-8), optional
/// [..end]  : data chunk
class BinaryFragmenter {
  static const int magic = 0xF0;
  static final _rng = Random.secure();
  static const int _attOverheadBytes =
      8; // Approximate ATT/GATT write-with-response overhead

  /// Split [data] into envelope-wrapped fragments that fit within [mtu].
  ///
  /// Throws if MTU cannot fit header + at least 1 byte of data.
  static List<Uint8List> fragment({
    required Uint8List data,
    required int mtu,
    required int originalType,
    String? recipient,
    int ttl = 5,
    int? forcedFragmentCount,
  }) {
    final recipientBytes = recipient == null || recipient.isEmpty
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(recipient));
    final headerBase = 1 + 8 + 2 + 2 + 1 + 1 + 1 + recipientBytes.length;
    final maxData = mtu - headerBase - _attOverheadBytes;
    if (maxData <= 0) {
      throw ArgumentError(
        'MTU too small: $mtu (needs > ${headerBase + _attOverheadBytes} for header + data + ATT overhead)',
      );
    }
    if (maxData < 20) {
      throw ArgumentError(
        'MTU too small for binary fragmentation: $mtu (only $maxData bytes available for payload)',
      );
    }

    final computedTotal = (data.length / maxData).ceil().clamp(1, 0xFFFF);
    final total = forcedFragmentCount != null
        ? forcedFragmentCount.clamp(1, 0xFFFF)
        : computedTotal;
    final fragId = _randomBytes(8);
    final fragments = <Uint8List>[];

    int offset = 0;
    for (var idx = 0; idx < total; idx++) {
      final remaining = data.length - offset;
      final chunkSize = remaining > maxData ? maxData : remaining;
      final chunk = data.sublist(offset, offset + chunkSize);
      offset += chunkSize;

      final buf = BytesBuilder();
      buf.addByte(magic);
      buf.add(fragId);
      buf.add(_u16(idx));
      buf.add(_u16(total));
      buf.addByte(ttl.clamp(0, 255));
      buf.addByte(originalType & 0xFF);
      buf.addByte(recipientBytes.length);
      if (recipientBytes.isNotEmpty) buf.add(recipientBytes);
      buf.add(chunk);
      fragments.add(buf.toBytes());
    }
    return fragments;
  }

  static Uint8List _randomBytes(int len) {
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static Uint8List _u16(int value) {
    final b = Uint8List(2);
    b[0] = (value >> 8) & 0xFF;
    b[1] = value & 0xFF;
    return b;
  }
}

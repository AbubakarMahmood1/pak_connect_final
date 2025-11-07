// Golomb-Coded Set (GCS) filter implementation for efficient sync
// Ported from BitChat Android's GCSFilter.kt
//
// Provides 98% bandwidth reduction for gossip sync:
// - Before: 32KB (1000 IDs × 32 bytes each)
// - After: 512 bytes (GCS filter)
//
// Algorithm:
// 1. Hash each ID to 64-bit value using SHA-256
// 2. Map to range [0, M) where M = N * 2^P
// 3. Sort mapped values and encode deltas using Golomb-Rice coding
// 4. Golomb-Rice: delta = quotient (unary) + remainder (P bits)

import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'dart:math' as math;

/// Golomb-Coded Set filter parameters
class GCSFilterParams {
  final int p; // Golomb-Rice parameter (controls false positive rate)
  final int m; // Range M = N * 2^P
  final Uint8List data; // Encoded Golomb-Rice bitstream

  const GCSFilterParams({required this.p, required this.m, required this.data});

  /// Convert to JSON for serialization
  Map<String, dynamic> toJson() => {'p': p, 'm': m, 'data': data.toList()};

  /// Create from JSON
  factory GCSFilterParams.fromJson(Map<String, dynamic> json) {
    return GCSFilterParams(
      p: json['p'] as int,
      m: json['m'] as int,
      data: Uint8List.fromList((json['data'] as List).cast<int>()),
    );
  }
}

/// GCS filter implementation
class GCSFilter {
  /// Derive P from target false positive rate
  /// FPR ~= 1 / 2^P
  ///
  /// Example:
  /// - FPR = 0.01 (1%) → P = 7
  /// - FPR = 0.001 (0.1%) → P = 10
  static int deriveP(double targetFpr) {
    final f = targetFpr.clamp(0.000001, 0.25);
    return (math.log(1.0 / f) / math.ln2).ceil().clamp(1, 32);
  }

  /// Estimate max elements that fit in given byte size
  /// Rule of thumb: each element takes approximately (P + 2) bits
  static int estimateMaxElementsForSize(int bytes, int p) {
    final bits = (bytes * 8).clamp(8, 1000000);
    final bitsPerElement = (p + 2).clamp(3, 100);
    return (bits / bitsPerElement).floor().clamp(1, 100000);
  }

  /// Build GCS filter from list of byte arrays (message IDs)
  ///
  /// Parameters:
  /// - ids: List of message IDs (16 bytes each, but can be any length)
  /// - maxBytes: Maximum size of filter in bytes (e.g., 512)
  /// - targetFpr: Target false positive rate (e.g., 0.01 for 1%)
  ///
  /// Returns: GCSFilterParams containing encoded filter
  static GCSFilterParams buildFilter({
    required List<Uint8List> ids,
    required int maxBytes,
    required double targetFpr,
  }) {
    final p = deriveP(targetFpr);
    var nCap = estimateMaxElementsForSize(maxBytes, p);
    final n = math.min(ids.length, nCap);
    final selected = ids.take(n).toList();

    // Map to [0, M) and deduplicate (hash collisions can create duplicates)
    final m = n << p; // n * 2^p
    final mapped = selected.map((id) => _h64(id) % m).toSet().toList()..sort();

    // Encode
    var encoded = _encode(mapped, p);

    // If estimate was too optimistic, trim until it fits
    var trimmedN = mapped.length; // Use actual deduplicated count
    while (encoded.length > maxBytes && trimmedN > 0) {
      trimmedN = (trimmedN * 9) ~/ 10; // drop 10%
      final mapped2 = mapped.take(trimmedN).toList();
      encoded = _encode(mapped2, p);
    }

    final finalM = trimmedN << p;

    return GCSFilterParams(p: p, m: finalM, data: encoded);
  }

  /// Decode filter to sorted set of values
  static List<int> decodeToSortedList(GCSFilterParams params) {
    final values = <int>[];
    final reader = _BitReader(params.data);
    var acc = 0;
    // final mask = (1 << params.p) - 1; // Unused

    while (!reader.eof()) {
      // Read unary quotient (q ones terminated by zero)
      var q = 0;
      while (true) {
        final bit = reader.readBit();
        if (bit == null) break;
        if (bit == 1) {
          q++;
        } else {
          break;
        }
      }
      if (reader.lastWasEOF) break;

      // Read remainder (P bits)
      final r = reader.readBits(params.p);
      if (r == null) break;

      final x = (q << params.p) + r + 1;
      acc += x;
      if (acc >= params.m) break; // out of range safeguard

      values.add(acc);
    }

    return values;
  }

  /// Check if value is in the filter (membership test)
  /// Uses binary search on decoded sorted values
  static bool contains(List<int> sortedValues, int candidate) {
    var lo = 0;
    var hi = sortedValues.length - 1;

    while (lo <= hi) {
      final mid = (lo + hi) >>> 1; // unsigned right shift
      final v = sortedValues[mid];

      if (v == candidate) return true;
      if (v < candidate) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }

    return false;
  }

  // Private methods

  /// Hash byte array to 64-bit unsigned integer
  /// Uses first 8 bytes of SHA-256 hash
  static int _h64(Uint8List id) {
    final digest = sha256.convert(id).bytes;
    var x = 0;

    // Take first 8 bytes (big-endian)
    for (var i = 0; i < 8; i++) {
      x = (x << 8) | (digest[i] & 0xFF);
    }

    // Ensure positive (mask off sign bit for Dart's signed int64)
    return x & 0x7FFFFFFFFFFFFFFF;
  }

  /// Encode sorted values using Golomb-Rice coding
  static Uint8List _encode(List<int> sorted, int p) {
    final bw = _BitWriter();
    var prev = 0;
    final mask = (1 << p) - 1;

    for (final v in sorted) {
      final delta = v - prev;

      // Safety check: delta must be >= 1 (values must be strictly increasing)
      if (delta <= 0) {
        throw ArgumentError(
          'Values must be strictly increasing (got delta=$delta at v=$v, prev=$prev)',
        );
      }

      prev = v;

      final x = delta;
      final q = (x - 1) >>> p; // quotient
      final r = (x - 1) & mask; // remainder

      // Write unary: q ones then a zero
      for (var i = 0; i < q; i++) {
        bw.writeBit(1);
      }
      bw.writeBit(0);

      // Write P bits of remainder (MSB-first)
      bw.writeBits(r, p);
    }

    return bw.toBytes();
  }
}

/// MSB-first bit writer
class _BitWriter {
  final List<int> _buffer = [];
  int _current = 0;
  int _nBits = 0;

  /// Write single bit (0 or 1)
  void writeBit(int bit) {
    _current = (_current << 1) | (bit & 1);
    _nBits++;

    if (_nBits == 8) {
      _buffer.add(_current);
      _current = 0;
      _nBits = 0;
    }
  }

  /// Write multiple bits (MSB-first)
  void writeBits(int value, int count) {
    if (count <= 0) return;

    for (var i = count - 1; i >= 0; i--) {
      final bit = (value >>> i) & 1;
      writeBit(bit);
    }
  }

  /// Convert to byte array (pads with zeros if needed)
  Uint8List toBytes() {
    if (_nBits > 0) {
      // Pad remaining bits with zeros
      final remaining = _current << (8 - _nBits);
      _buffer.add(remaining);
      _current = 0;
      _nBits = 0;
    }
    return Uint8List.fromList(_buffer);
  }
}

/// MSB-first bit reader
class _BitReader {
  final Uint8List _data;
  int _index = 0;
  int _nLeft = 8;
  int _current = 0;
  bool lastWasEOF = false;

  _BitReader(this._data) {
    if (_data.isNotEmpty) {
      _current = _data[0] & 0xFF;
    }
  }

  /// Check if at end of data
  bool eof() => _index >= _data.length;

  /// Read single bit
  int? readBit() {
    if (_index >= _data.length) {
      lastWasEOF = true;
      return null;
    }

    final bit = (_current >>> 7) & 1;
    _current = (_current << 1) & 0xFF;
    _nLeft--;

    if (_nLeft == 0) {
      _index++;
      if (_index < _data.length) {
        _current = _data[_index] & 0xFF;
        _nLeft = 8;
      }
    }

    return bit;
  }

  /// Read multiple bits (MSB-first)
  int? readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final bit = readBit();
      if (bit == null) return null;
      value = (value << 1) | bit;
    }
    return value;
  }
}

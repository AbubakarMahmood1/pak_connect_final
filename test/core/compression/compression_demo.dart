import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/utils/compression_util.dart';

/// Demo script to show compression module working
void main() {
  // Setup logger
  final logger = Logger('CompressionDemo');

  logger.info('=== Compression Module Demo ===\n');

  // Test 1: Text compression
  logger.info('1. Text Compression:');
  final text = 'Hello world! ' * 100; // 1300 bytes
  final textData = Uint8List.fromList(utf8.encode(text));

  final textResult = CompressionUtil.compress(textData);
  if (textResult != null) {
    logger.info('   Original: ${textData.length} bytes');
    logger.info('   Compressed: ${textResult.compressed.length} bytes');
    logger.info(
      '   Ratio: ${(textResult.stats.compressionRatio * 100).toStringAsFixed(1)}%',
    );
    logger.info(
      '   Saved: ${textResult.stats.bytesSaved} bytes (${textResult.stats.savingsPercent.toStringAsFixed(1)}%)',
    );

    // Verify round-trip
    final decompressed = CompressionUtil.decompress(textResult.compressed);
    logger.info(
      '   Round-trip: ${decompressed != null && decompressed.length == textData.length ? "✅ SUCCESS" : "❌ FAILED"}',
    );
  }
  logger.info('');

  // Test 2: JSON compression
  logger.info('2. JSON Compression:');
  final json = jsonEncode({
    'messages': List.generate(
      50,
      (i) => {
        'id': 'msg_$i',
        'content': 'Test message $i',
        'timestamp': 1234567890 + i,
        'isFromMe': i % 2 == 0,
      },
    ),
  });
  final jsonData = Uint8List.fromList(utf8.encode(json));

  final jsonResult = CompressionUtil.compress(jsonData);
  if (jsonResult != null) {
    logger.info('   Original: ${jsonData.length} bytes');
    logger.info('   Compressed: ${jsonResult.compressed.length} bytes');
    logger.info(
      '   Ratio: ${(jsonResult.stats.compressionRatio * 100).toStringAsFixed(1)}%',
    );
    logger.info(
      '   Saved: ${jsonResult.stats.bytesSaved} bytes (${jsonResult.stats.savingsPercent.toStringAsFixed(1)}%)',
    );
  }
  logger.info('');

  // Test 3: Small data (should skip)
  logger.info('3. Small Data (below threshold):');
  final small = Uint8List.fromList(utf8.encode('Hi'));
  final smallResult = CompressionUtil.compress(small);
  logger.info('   Original: ${small.length} bytes');
  logger.info(
    '   Compressed: ${smallResult == null ? "SKIPPED (below threshold)" : "${smallResult.compressed.length} bytes"}',
  );
  logger.info('');

  // Test 4: High entropy data (should skip)
  logger.info('4. High Entropy Data:');
  final random = Uint8List.fromList(List<int>.generate(256, (i) => i));
  final randomResult = CompressionUtil.compress(random);
  final entropy = CompressionUtil.calculateEntropy(random);
  logger.info('   Original: ${random.length} bytes');
  logger.info(
    '   Entropy: ${(entropy * 100).toStringAsFixed(1)}% (high = already compressed)',
  );
  logger.info(
    '   Compressed: ${randomResult == null ? "SKIPPED (high entropy)" : "${randomResult.compressed.length} bytes"}',
  );
  logger.info('');

  // Test 5: Self-test
  logger.info('5. Self-Test:');
  final selfTestPassed = CompressionUtil.runSelfTest();
  logger.info('   Self-test: ${selfTestPassed ? "✅ PASSED" : "❌ FAILED"}');
  logger.info('');

  logger.info('=== Demo Complete ===');
}

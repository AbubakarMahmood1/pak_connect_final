import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/services/media_send_handler.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';

// Generate mocks
@GenerateMocks([IMeshNetworkingService])
import 'media_send_handler_test.mocks.dart';

void main() {
  group('MediaSendHandler', () {
    late MockIMeshNetworkingService mockMeshService;
    late MediaSendHandler handler;
    late Directory testDir;

    setUp(() async {
      mockMeshService = MockIMeshNetworkingService();
      handler = MediaSendHandler(
        meshService: mockMeshService,
        logger: Logger.detached('MediaSendHandlerTest'),
      );

      // Create temp directory for test files
      testDir = await Directory.systemTemp.createTemp('media_send_test');
    });

    tearDown(() async {
      // Cleanup temp files
      if (await testDir.exists()) {
        await testDir.delete(recursive: true);
      }
    });

    group('sendImage', () {
      test('should send valid JPEG image successfully', () async {
        // Create test image file
        final testFile = File('${testDir.path}/test.jpg');
        final testBytes = Uint8List.fromList(
          List.generate(100, (i) => i % 256),
        );
        await testFile.writeAsBytes(testBytes);

        // Mock successful send
        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id-123');

        // Execute
        final transferId = await handler.sendImage(
          file: testFile,
          recipientId: 'recipient-123',
        );

        // Verify
        expect(transferId, equals('test-transfer-id-123'));
        verify(
          mockMeshService.sendBinaryMedia(
            data: testBytes,
            recipientId: 'recipient-123',
            originalType: BinaryPayloadType.media,
            metadata: argThat(
              isA<Map<String, dynamic>>()
                  .having((m) => m['filename'], 'filename', 'test.jpg')
                  .having((m) => m['mimeType'], 'mimeType', 'image/jpeg')
                  .having((m) => m['originalSize'], 'originalSize', 100),
              named: 'metadata',
            ),
          ),
        ).called(1);
      });

      test(
        'should throw MediaSendException.invalidFile when file does not exist',
        () async {
          // Create non-existent file reference
          final nonExistentFile = File('${testDir.path}/does-not-exist.jpg');

          // Execute and verify exception (FIXED: use expectLater for async)
          await expectLater(
            handler.sendImage(
              file: nonExistentFile,
              recipientId: 'recipient-123',
            ),
            throwsA(
              isA<MediaSendException>()
                  .having((e) => e.code, 'code', 'INVALID_FILE')
                  .having(
                    (e) => e.message,
                    'message',
                    contains('does not exist'),
                  ),
            ),
          );

          // Verify mesh service was never called
          verifyNever(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          );
        },
      );

      test(
        'should throw MediaSendException.tooLarge when file exceeds max size',
        () async {
          // Create large test file (3MB, exceeds 2MB limit)
          final largeFile = File('${testDir.path}/large.jpg');
          final largeBytes = Uint8List(3 * 1024 * 1024); // 3MB
          await largeFile.writeAsBytes(largeBytes);

          // Execute and verify exception (FIXED: use expectLater for async)
          await expectLater(
            handler.sendImage(file: largeFile, recipientId: 'recipient-123'),
            throwsA(
              isA<MediaSendException>()
                  .having((e) => e.code, 'code', 'FILE_TOO_LARGE')
                  .having((e) => e.message, 'message', contains('too large')),
            ),
          );

          // Verify mesh service was never called
          verifyNever(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          );
        },
      );

      test(
        'should throw MediaSendException.unsupportedType for non-image files',
        () async {
          // Create test text file
          final textFile = File('${testDir.path}/test.txt');
          await textFile.writeAsString('Not an image');

          // Execute and verify exception (FIXED: use expectLater for async)
          await expectLater(
            handler.sendImage(file: textFile, recipientId: 'recipient-123'),
            throwsA(
              isA<MediaSendException>()
                  .having((e) => e.code, 'code', 'UNSUPPORTED_TYPE')
                  .having((e) => e.message, 'message', contains('Unsupported')),
            ),
          );

          // Verify mesh service was never called
          verifyNever(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          );
        },
      );

      test('should handle various image formats (PNG, GIF, WEBP)', () async {
        final formats = {
          'test.png': 'image/png',
          'test.gif': 'image/gif',
          'test.webp': 'image/webp',
        };

        for (final entry in formats.entries) {
          // Create test file
          final testFile = File('${testDir.path}/${entry.key}');
          final testBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
          await testFile.writeAsBytes(testBytes);

          // Mock successful send
          when(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          ).thenAnswer((_) async => 'test-transfer-id');

          // Execute
          await handler.sendImage(file: testFile, recipientId: 'recipient-123');

          // Verify correct MIME type was used
          verify(
            mockMeshService.sendBinaryMedia(
              data: testBytes,
              recipientId: 'recipient-123',
              originalType: BinaryPayloadType.media,
              metadata: argThat(
                isA<Map<String, dynamic>>().having(
                  (m) => m['mimeType'],
                  'mimeType',
                  entry.value,
                ),
                named: 'metadata',
              ),
            ),
          ).called(1);

          reset(mockMeshService);
        }
      });

      test('should merge custom metadata with default metadata', () async {
        // Create test image file
        final testFile = File('${testDir.path}/test.jpg');
        await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

        // Mock successful send
        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id');

        // Execute with custom metadata
        await handler.sendImage(
          file: testFile,
          recipientId: 'recipient-123',
          metadata: {'customKey': 'customValue', 'anotherKey': 42},
        );

        // Verify merged metadata
        verify(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: argThat(
              isA<Map<String, dynamic>>()
                  .having((m) => m['filename'], 'filename', 'test.jpg')
                  .having((m) => m['customKey'], 'customKey', 'customValue')
                  .having((m) => m['anotherKey'], 'anotherKey', 42),
              named: 'metadata',
            ),
          ),
        ).called(1);
      });

      test('should wrap mesh service errors in MediaSendException', () async {
        // Create test image file
        final testFile = File('${testDir.path}/test.jpg');
        await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

        // Mock mesh service error
        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenThrow(Exception('Network error'));

        // Execute and verify exception wrapping (FIXED: use expectLater for async)
        await expectLater(
          handler.sendImage(file: testFile, recipientId: 'recipient-123'),
          throwsA(
            isA<MediaSendException>().having(
              (e) => e.message,
              'message',
              contains('Failed to send'),
            ),
          ),
        );
      });
    });

    group('sendFile', () {
      test('should send valid file successfully', () async {
        // Create test file
        final testFile = File('${testDir.path}/document.pdf');
        final testBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
        await testFile.writeAsBytes(testBytes);

        // Mock successful send
        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id-456');

        // Execute
        final transferId = await handler.sendFile(
          file: testFile,
          recipientId: 'recipient-456',
        );

        // Verify
        expect(transferId, equals('test-transfer-id-456'));
        verify(
          mockMeshService.sendBinaryMedia(
            data: testBytes,
            recipientId: 'recipient-456',
            originalType: BinaryPayloadType.media,
            metadata: argThat(
              isA<Map<String, dynamic>>()
                  .having((m) => m['filename'], 'filename', 'document.pdf')
                  .having((m) => m['mimeType'], 'mimeType', 'application/pdf'),
              named: 'metadata',
            ),
          ),
        ).called(1);
      });

      test('should handle custom max size limit', () async {
        // Create handler with smaller max size (1MB)
        final smallHandler = MediaSendHandler(
          meshService: mockMeshService,
          logger: Logger.detached('Test'),
          maxFileSizeBytes: 1 * 1024 * 1024, // 1MB
        );

        // Create 2MB file
        final largeFile = File('${testDir.path}/large.pdf');
        await largeFile.writeAsBytes(Uint8List(2 * 1024 * 1024));

        // Execute and verify exception (FIXED: use expectLater for async)
        await expectLater(
          smallHandler.sendFile(file: largeFile, recipientId: 'recipient-123'),
          throwsA(
            isA<MediaSendException>().having(
              (e) => e.code,
              'code',
              'FILE_TOO_LARGE',
            ),
          ),
        );
      });
    });

    group('MIME type detection', () {
      test('should detect various file types correctly', () async {
        final testCases = {
          'test.jpg': 'image/jpeg',
          'test.jpeg': 'image/jpeg',
          'test.png': 'image/png',
          'test.pdf': 'application/pdf',
          'test.txt': 'text/plain',
          'test.mp3': 'audio/mpeg',
          'test.mp4': 'video/mp4',
          'test.unknown': 'application/octet-stream',
        };

        for (final entry in testCases.entries) {
          final testFile = File('${testDir.path}/${entry.key}');
          await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

          when(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          ).thenAnswer((_) async => 'test-transfer-id');

          await handler.sendFile(file: testFile, recipientId: 'recipient-123');

          verify(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: argThat(
                isA<Map<String, dynamic>>().having(
                  (m) => m['mimeType'],
                  'mimeType',
                  entry.value,
                ),
                named: 'metadata',
              ),
            ),
          ).called(1);

          reset(mockMeshService);
        }
      });

      test('should handle uppercase file extensions', () async {
        final testCases = {
          'test.JPG': 'image/jpeg',
          'test.JPEG': 'image/jpeg',
          'test.PNG': 'image/png',
          'test.PDF': 'application/pdf',
        };

        for (final entry in testCases.entries) {
          final testFile = File('${testDir.path}/${entry.key}');
          await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

          when(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          ).thenAnswer((_) async => 'test-transfer-id');

          await handler.sendFile(file: testFile, recipientId: 'recipient-123');

          verify(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: argThat(
                isA<Map<String, dynamic>>().having(
                  (m) => m['mimeType'],
                  'mimeType',
                  entry.value,
                ),
                named: 'metadata',
              ),
            ),
          ).called(1);

          reset(mockMeshService);
        }
      });

      test('should prefer knownMimeType over extension detection', () async {
        final testFile = File('${testDir.path}/test.jpg');
        await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id');

        await handler.sendImage(
          file: testFile,
          recipientId: 'recipient-123',
          knownMimeType: 'image/png', // Override JPEG extension
        );

        verify(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: argThat(
              isA<Map<String, dynamic>>().having(
                (m) => m['mimeType'],
                'mimeType',
                'image/png',
              ),
              named: 'metadata',
            ),
          ),
        ).called(1);
      });
    });

    group('Zero-byte file handling', () {
      test(
        'should throw MediaSendException.invalidFile for empty image',
        () async {
          final emptyFile = File('${testDir.path}/empty.jpg');
          await emptyFile.writeAsBytes(Uint8List(0)); // Zero bytes

          await expectLater(
            handler.sendImage(file: emptyFile, recipientId: 'recipient-123'),
            throwsA(
              isA<MediaSendException>()
                  .having((e) => e.code, 'code', 'INVALID_FILE')
                  .having(
                    (e) => e.message,
                    'message',
                    contains('does not exist'),
                  ),
            ),
          );

          verifyNever(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          );
        },
      );

      test(
        'should throw MediaSendException.invalidFile for empty file',
        () async {
          final emptyFile = File('${testDir.path}/empty.pdf');
          await emptyFile.writeAsBytes(Uint8List(0)); // Zero bytes

          await expectLater(
            handler.sendFile(file: emptyFile, recipientId: 'recipient-123'),
            throwsA(
              isA<MediaSendException>()
                  .having((e) => e.code, 'code', 'INVALID_FILE')
                  .having(
                    (e) => e.message,
                    'message',
                    contains('does not exist'),
                  ),
            ),
          );

          verifyNever(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          );
        },
      );
    });

    group('Error cause preservation', () {
      test(
        'should preserve underlying error cause in MediaSendException',
        () async {
          final testFile = File('${testDir.path}/test.jpg');
          await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

          final mockError = Exception('Network timeout');
          when(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          ).thenThrow(mockError);

          MediaSendException? caughtException;
          try {
            await handler.sendImage(
              file: testFile,
              recipientId: 'recipient-123',
            );
          } on MediaSendException catch (e) {
            caughtException = e;
          }

          expect(caughtException, isNotNull);
          expect(caughtException!.cause, equals(mockError));
          expect(caughtException.message, contains('Failed to send'));
        },
      );
    });

    group('MIME type normalization', () {
      test('should normalize uppercase MIME types', () async {
        final testFile = File('${testDir.path}/test.jpg');
        await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id');

        // Pass uppercase MIME type
        await handler.sendImage(
          file: testFile,
          recipientId: 'recipient-123',
          knownMimeType: 'IMAGE/JPEG',
        );

        // Verify it was normalized to lowercase
        verify(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: argThat(
              isA<Map<String, dynamic>>().having(
                (m) => m['mimeType'],
                'mimeType',
                'image/jpeg',
              ),
              named: 'metadata',
            ),
          ),
        ).called(1);
      });

      test('should strip MIME type parameters', () async {
        final testFile = File('${testDir.path}/test.jpg');
        await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id');

        // Pass MIME type with parameters
        await handler.sendImage(
          file: testFile,
          recipientId: 'recipient-123',
          knownMimeType: 'image/jpeg; charset=binary',
        );

        // Verify parameters were stripped
        verify(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: argThat(
              isA<Map<String, dynamic>>().having(
                (m) => m['mimeType'],
                'mimeType',
                'image/jpeg',
              ),
              named: 'metadata',
            ),
          ),
        ).called(1);
      });
    });

    group('Noise session gating', () {
      late MediaSendHandler handlerWithSecurity;
      late String? capturedRecipientId;
      late bool hasNoiseSession;

      setUp(() {
        capturedRecipientId = null;
        hasNoiseSession = true;
        handlerWithSecurity = MediaSendHandler(
          meshService: mockMeshService,
          hasEstablishedNoiseSession: (recipientId) {
            capturedRecipientId = recipientId;
            return hasNoiseSession;
          },
          logger: Logger.detached('MediaSendHandlerTest'),
        );
      });

      test(
        'should throw encryptionNotReady when Noise session not established',
        () async {
          final testFile = File('${testDir.path}/test.jpg');
          await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));
          hasNoiseSession = false;

          await expectLater(
            handlerWithSecurity.sendImage(
              file: testFile,
              recipientId: 'recipient-123',
            ),
            throwsA(
              isA<MediaSendException>()
                  .having((e) => e.code, 'code', 'ENCRYPTION_NOT_READY')
                  .having(
                    (e) => e.message,
                    'message',
                    contains('encryption session not established'),
                  ),
            ),
          );

          // Verify mesh service was never called
          verifyNever(
            mockMeshService.sendBinaryMedia(
              data: anyNamed('data'),
              recipientId: anyNamed('recipientId'),
              originalType: anyNamed('originalType'),
              metadata: anyNamed('metadata'),
            ),
          );
          expect(capturedRecipientId, equals('recipient-123'));
        },
      );

      test('should proceed when Noise session is established', () async {
        final testFile = File('${testDir.path}/test.jpg');
        final testBytes = Uint8List.fromList([1, 2, 3]);
        await testFile.writeAsBytes(testBytes);

        hasNoiseSession = true;
        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id');

        final transferId = await handlerWithSecurity.sendImage(
          file: testFile,
          recipientId: 'recipient-123',
        );

        expect(transferId, equals('test-transfer-id'));
        expect(capturedRecipientId, equals('recipient-123'));
        verify(
          mockMeshService.sendBinaryMedia(
            data: testBytes,
            recipientId: 'recipient-123',
            originalType: BinaryPayloadType.media,
            metadata: anyNamed('metadata'),
          ),
        ).called(1);
      });

      test('should skip Noise check when callback is null', () async {
        // Use handler without noise-session callback
        final testFile = File('${testDir.path}/test.jpg');
        await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

        when(
          mockMeshService.sendBinaryMedia(
            data: anyNamed('data'),
            recipientId: anyNamed('recipientId'),
            originalType: anyNamed('originalType'),
            metadata: anyNamed('metadata'),
          ),
        ).thenAnswer((_) async => 'test-transfer-id');

        final transferId = await handler.sendImage(
          file: testFile,
          recipientId: 'recipient-123',
        );

        expect(transferId, equals('test-transfer-id'));
        // No Noise check should have been performed
      });
    });
  });
}

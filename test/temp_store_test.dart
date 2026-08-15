import 'package:flutter_test/flutter_test.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/storage/temp_store.dart';

void main() {
  test('parses PNG dimensions', () {
    final bytes = List<int>.filled(24, 0);
    bytes[0] = 0x89;
    bytes[1] = 0x50;
    bytes[2] = 0x4E;
    bytes[3] = 0x47;
    bytes[12] = 0x49;
    bytes[13] = 0x48;
    bytes[14] = 0x44;
    bytes[15] = 0x52;
    bytes[18] = 0x07;
    bytes[19] = 0x80;
    bytes[22] = 0x04;
    bytes[23] = 0x38;
    _expectSize(parseImageSize(bytes), 1920, 1080);
  });

  test('parses JPEG, WebP, GIF and BMP dimensions', () {
    final jpeg = List<int>.filled(21, 0);
    jpeg[0] = 0xFF;
    jpeg[1] = 0xD8;
    jpeg[2] = 0xFF;
    jpeg[3] = 0xC0;
    jpeg[4] = 0x00;
    jpeg[5] = 0x11;
    jpeg[6] = 0x08;
    jpeg[7] = 0x04;
    jpeg[8] = 0x38;
    jpeg[9] = 0x07;
    jpeg[10] = 0x80;
    _expectSize(parseImageSize(jpeg), 1920, 1080);

    final webp = List<int>.filled(30, 0);
    webp.setAll(0, 'RIFF'.codeUnits);
    webp.setAll(8, 'WEBP'.codeUnits);
    webp.setAll(12, 'VP8X'.codeUnits);
    webp[24] = 1919 & 0xFF;
    webp[25] = 1919 >> 8;
    webp[27] = 1079 & 0xFF;
    webp[28] = 1079 >> 8;
    _expectSize(parseImageSize(webp), 1920, 1080);

    final webpLossless = List<int>.filled(25, 0);
    webpLossless.setAll(0, 'RIFF'.codeUnits);
    webpLossless.setAll(8, 'WEBP'.codeUnits);
    webpLossless.setAll(12, 'VP8L'.codeUnits);
    webpLossless[20] = 0x2F;
    webpLossless[21] = 1;
    webpLossless[22] = 2 << 6;
    _expectSize(parseImageSize(webpLossless), 2, 3);

    final gif = <int>[...'GIF89a'.codeUnits, 0x80, 0x07, 0x38, 0x04];
    _expectSize(parseImageSize(gif), 1920, 1080);

    final bmp = List<int>.filled(26, 0);
    bmp[0] = 0x42;
    bmp[1] = 0x4D;
    bmp[18] = 0x80;
    bmp[19] = 0x07;
    bmp[22] = 0x38;
    bmp[23] = 0x04;
    _expectSize(parseImageSize(bmp), 1920, 1080);
  });

  test('rejects unsupported extensions explicitly', () {
    expect(
      () => imageExtensionForPath('capture.heic'),
      throwsA(isA<FormatException>()),
    );
    expect(imageExtensionForPath('capture.PNG'), 'png');
  });

  test('returns null for unknown headers', () {
    expect(parseImageSize(List<int>.filled(64, 0)), isNull);
  });
}

void _expectSize(ImageSize? size, int width, int height) {
  expect(size, isNotNull);
  expect(size!.width, width);
  expect(size.height, height);
}

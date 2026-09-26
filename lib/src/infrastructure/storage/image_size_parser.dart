import 'dart:io';
import 'dart:typed_data';

import 'package:pixelforge/src/domain/models.dart';

const _imageHeaderBytes = 512 * 1024;
const _jpegExifMarker = 0xE1;
const _jpegStartOfScanMarker = 0xDA;
const _jpegEndOfImageMarker = 0xD9;
const _exifOrientationTag = 0x0112;
const _exifShortType = 3;
const _exifHeaderLength = 6;
const _tiffHeaderLength = 8;
const _tiffIfdEntryBytes = 12;
const _tiffMagicNumber = 42;

class _ExifDirectory {
  const _ExifDirectory({
    required this.bytes,
    required this.entriesStart,
    required this.entryCount,
    required this.tiffOffset,
    required this.end,
    required this.littleEndian,
  });

  final List<int> bytes;
  final int entriesStart;
  final int entryCount;
  final int tiffOffset;
  final int end;
  final bool littleEndian;
}

/// 从文件头解析图片尺寸，并应用 JPEG EXIF 方向。
ImageSize? parseImageSize(List<int> head) {
  if (_isPng(head)) {
    return ImageSize(
      (head[16] << 24) | (head[17] << 16) | (head[18] << 8) | head[19],
      (head[20] << 24) | (head[21] << 16) | (head[22] << 8) | head[23],
    );
  }
  final jpeg = _parseJpegSize(head);
  if (jpeg != null) return jpeg;
  final webp = _parseWebpSize(head);
  if (webp != null) return webp;
  final gif = _parseGifSize(head);
  if (gif != null) return gif;
  return _parseBmpSize(head);
}

bool _isPng(List<int> head) =>
    head.length >= 24 &&
    head[0] == 0x89 &&
    head[1] == 0x50 &&
    head[2] == 0x4E &&
    head[3] == 0x47 &&
    head[12] == 0x49 &&
    head[13] == 0x48 &&
    head[14] == 0x44 &&
    head[15] == 0x52;

ImageSize? _parseJpegSize(List<int> head) {
  if (head.length < 4 || head[0] != 0xFF || head[1] != 0xD8) return null;
  var index = 2;
  var orientation = 1;
  ImageSize? dimensions;
  while (index + 3 < head.length) {
    if (head[index] != 0xFF) {
      index++;
      continue;
    }
    while (index < head.length && head[index] == 0xFF) {
      index++;
    }
    if (index >= head.length) return null;
    final marker = head[index++];
    if (marker == _jpegStartOfScanMarker || marker == _jpegEndOfImageMarker) {
      break;
    }
    if (marker == 0xD8 || marker == 0x01) continue;
    if (index + 1 >= head.length) return null;
    final length = (head[index] << 8) | head[index + 1];
    if (length < 2 || index + length > head.length) return null;
    if (marker == _jpegExifMarker) {
      orientation =
          _parseExifOrientation(head, index + 2, index + length) ?? orientation;
    }
    if (_isJpegFrameMarker(marker) && length >= 7) {
      dimensions = ImageSize(
        (head[index + 5] << 8) | head[index + 6],
        (head[index + 3] << 8) | head[index + 4],
      );
    }
    index += length;
  }
  return dimensions == null
      ? null
      : _applyExifOrientation(dimensions, orientation);
}

bool _isJpegFrameMarker(int marker) =>
    marker >= 0xC0 && marker <= 0xC3 ||
    marker >= 0xC5 && marker <= 0xC7 ||
    marker >= 0xC9 && marker <= 0xCB ||
    marker >= 0xCD && marker <= 0xCF;

int? _parseExifOrientation(List<int> bytes, int start, int end) {
  if (end - start < _exifHeaderLength + _tiffHeaderLength) return null;
  if (!_hasExifHeader(bytes, start)) return null;
  final tiff = start + _exifHeaderLength;
  final littleEndian = _isLittleEndian(bytes, tiff);
  if (littleEndian == null ||
      _readExif16(bytes, tiff + 2, littleEndian) != _tiffMagicNumber) {
    return null;
  }
  final directoryOffset = _readExif32(bytes, tiff + 4, littleEndian);
  if (directoryOffset < _tiffHeaderLength || directoryOffset > end - tiff) {
    return null;
  }
  final directory = tiff + directoryOffset;
  if (directory + 2 > end) return null;
  final entryCount = _readExif16(bytes, directory, littleEndian);
  return _findOrientationEntry(
    _ExifDirectory(
      bytes: bytes,
      entriesStart: directory + 2,
      entryCount: entryCount,
      tiffOffset: tiff,
      end: end,
      littleEndian: littleEndian,
    ),
  );
}

bool _hasExifHeader(List<int> bytes, int offset) =>
    bytes[offset] == 0x45 &&
    bytes[offset + 1] == 0x78 &&
    bytes[offset + 2] == 0x69 &&
    bytes[offset + 3] == 0x66 &&
    bytes[offset + 4] == 0 &&
    bytes[offset + 5] == 0;

bool? _isLittleEndian(List<int> bytes, int offset) {
  if (bytes[offset] == 0x49 && bytes[offset + 1] == 0x49) return true;
  if (bytes[offset] == 0x4D && bytes[offset + 1] == 0x4D) return false;
  return null;
}

int? _findOrientationEntry(_ExifDirectory directory) {
  for (var index = 0; index < directory.entryCount; index++) {
    final entry = directory.entriesStart + index * _tiffIfdEntryBytes;
    if (entry + _tiffIfdEntryBytes > directory.end) return null;
    final tag = _readExif16(directory.bytes, entry, directory.littleEndian);
    final type =
        _readExif16(directory.bytes, entry + 2, directory.littleEndian);
    final count =
        _readExif32(directory.bytes, entry + 4, directory.littleEndian);
    if (tag != _exifOrientationTag || type != _exifShortType || count == 0) {
      continue;
    }
    final valueOffset = count == 1
        ? entry + 8
        : directory.tiffOffset +
              _readExif32(directory.bytes, entry + 8, directory.littleEndian);
    if (valueOffset + 2 > directory.end) return null;
    final value =
        _readExif16(directory.bytes, valueOffset, directory.littleEndian);
    return value >= 1 && value <= 8 ? value : null;
  }
  return null;
}

int _readExif16(List<int> bytes, int offset, bool littleEndian) => littleEndian
    ? bytes[offset] | (bytes[offset + 1] << 8)
    : (bytes[offset] << 8) | bytes[offset + 1];

int _readExif32(List<int> bytes, int offset, bool littleEndian) => littleEndian
    ? bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24)
    : (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];

ImageSize _applyExifOrientation(ImageSize size, int orientation) {
  if (orientation < 5) return size;
  return ImageSize(size.height, size.width);
}

ImageSize? _parseWebpSize(List<int> head) {
  if (head.length < 16 ||
      head[0] != 0x52 ||
      head[1] != 0x49 ||
      head[2] != 0x46 ||
      head[3] != 0x46 ||
      head[8] != 0x57 ||
      head[9] != 0x45 ||
      head[10] != 0x42 ||
      head[11] != 0x50) {
    return null;
  }
  final chunk = String.fromCharCodes(head.sublist(12, 16));
  if (chunk == 'VP8X' && head.length >= 30) {
    final width = 1 + (head[24] | (head[25] << 8) | (head[26] << 16));
    final height = 1 + (head[27] | (head[28] << 8) | (head[29] << 16));
    return ImageSize(width, height);
  }
  if (chunk == 'VP8 ' && head.length >= 30) {
    return ImageSize(head[26] | (head[27] << 8), head[28] | (head[29] << 8));
  }
  if (chunk == 'VP8L' && head.length >= 25 && head[20] == 0x2F) {
    final width = 1 + (head[21] | ((head[22] & 0x3F) << 8));
    final height =
        1 + ((head[22] >> 6) | (head[23] << 2) | ((head[24] & 0x0F) << 10));
    return ImageSize(width, height);
  }
  return null;
}

ImageSize? _parseGifSize(List<int> head) {
  if (head.length < 10 ||
      String.fromCharCodes(head.sublist(0, 6)) != 'GIF87a' &&
          String.fromCharCodes(head.sublist(0, 6)) != 'GIF89a') {
    return null;
  }
  return ImageSize(head[6] | (head[7] << 8), head[8] | (head[9] << 8));
}

ImageSize? _parseBmpSize(List<int> head) {
  if (head.length < 26 || head[0] != 0x42 || head[1] != 0x4D) return null;
  final width = _signedLittleEndian(head, 18, 4).abs();
  final height = _signedLittleEndian(head, 22, 4).abs();
  return ImageSize(width, height);
}

int _signedLittleEndian(List<int> bytes, int offset, int length) {
  var value = 0;
  for (var i = 0; i < length; i++) {
    value |= bytes[offset + i] << (8 * i);
  }
  final signBit = 1 << (length * 8 - 1);
  return (value & signBit) == 0 ? value : value - (signBit << 1);
}

/// Read a bounded header so large EXIF segments do not force a full decode.
Future<ImageSize> readImageSize(File file) async {
  if (!await file.exists()) {
    throw FileSystemException('图片文件不存在', file.path);
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, _imageHeaderBytes)) {
    builder.add(chunk);
  }
  final size = parseImageSize(builder.takeBytes());
  if (size == null || size.width <= 0 || size.height <= 0) {
    throw FormatException('无法识别图片尺寸: ${file.path}');
  }
  return size;
}

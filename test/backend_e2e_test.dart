import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:braille_scan_ai/services/braille_scanner_backend.dart';

/// Menggambar satu karakter Braille sebagai titik-titik bulat kecil.
void drawChar(
  img.Image canvas, {
  required int charX,
  required int charWidth,
  required int charHeight,
  required List<int> dots,
}) {
  final double xC = charX + charWidth / 4.0;
  final double y1 = charHeight * 0.17;
  final double yM = charHeight * 0.5;
  final double y3 = charHeight * 0.83;
  final int r = (charWidth / 8.0).round().clamp(2, 20);

  final Map<int, (int, double)> pos = <int, (int, double)>{
    1: (0, y1),
    2: (0, yM),
    3: (0, y3),
    4: (1, y1),
    5: (1, yM),
    6: (1, y3),
  };

  for (final int d in dots) {
    final (int c, double y) = pos[d]!;
    final int cx = (xC + c * (charWidth / 2.0)).round();
    final int cy = y.round();
    _fillCircle(canvas, cx, cy, r);
  }
}

void _fillCircle(img.Image canvas, int cx, int cy, int r) {
  for (int dy = -r; dy <= r; dy++) {
    for (int dx = -r; dx <= r; dx++) {
      if (dx * dx + dy * dy <= r * r) {
        final int x = cx + dx;
        final int y = cy + dy;
        if (x >= 0 && y >= 0 && x < canvas.width && y < canvas.height) {
          canvas.setPixelRgba(x, y, 40, 40, 40, 255);
        }
      }
    }
  }
}

img.Image buildRowOfChars(List<List<int>> chars, {int height = 60}) {
  const int charWidth = 50;
  final int width = chars.length * charWidth;
  final img.Image canvas = img.Image(width: width, height: height);
  img.fill(canvas, color: img.ColorRgb8(245, 245, 245));
  for (int i = 0; i < chars.length; i++) {
    drawChar(
      canvas,
      charX: i * charWidth,
      charWidth: charWidth,
      charHeight: height,
      dots: chars[i],
    );
  }
  return canvas;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backend end-to-end (Tahap 1-5): "budi" terbaca menjadi kalimat', () async {
    final BrailleScannerBackend backend = BrailleScannerBackend();

    // "budi" = b(userid), u, d, i
    final img.Image row = buildRowOfChars([
      const [1, 2], // b
      const [1, 3, 6], // u
      const [1, 4, 5], // d
      const [2, 4], // i
    ]);
    final Uint8List bytes = Uint8List.fromList(img.encodePng(row));

    final BrailleScanResult result = await backend.scanDocument(bytes);

    // Tahap 5: huruf-huruf dirangkai menjadi kata (tanpa spasi berlebih).
    expect(result.text, contains('budi'), reason: 'text=${result.text}');

    // Overlay: ada baris & sel ber-label.
    expect(result.overlayLines, isNotEmpty);
    final BrailleOverlayLine line = result.overlayLines.first;
    expect(line.cells, isNotEmpty);
    expect(line.text.trim(), isNotEmpty);
    expect(line.height, greaterThan(0));

    // Metadata gambar sumber ikut serta.
    expect(result.imageWidth, row.width);
    expect(result.imageHeight, row.height);
    expect(result.imageBytes, isNotNull);

    backend.dispose();
  });
}
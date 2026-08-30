import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:braille_scan_ai/services/image_processing_service.dart';
import 'package:braille_scan_ai/services/braille_decoder.dart';

/// Menggambar satu karakter Braille pada [canvas] sebagai titik-titik bulat
/// kecil (mewakili Braille timbul asli). [charX] = offset x kiri karakter.
void drawChar(
  img.Image canvas, {
  required int charX,
  required int charWidth,
  required int charHeight,
  required List<int> dots, // braille dot 1..6
}) {
  // Pusat titik Braille: horizontal di 1/4 & 3/4 lebar, vertikal 1/6, 1/2, 5/6.
  final double xC = charX + charWidth / 4.0;
  final double y1 = charHeight * 0.17;
  final double yM = charHeight * 0.5;
  final double y3 = charHeight * 0.83;
  final int r = (charWidth / 8.0).round().clamp(2, 20);

  // posisi braille: dot1 kiri-atas, dot2 kiri-tengah, dot3 kiri-bawah,
  // dot4 kanan-atas, dot5 kanan-tengah, dot6 kanan-bawah
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
    _fillCircle(canvas, cx, cy, r, img.ColorRgb8(0, 0, 0));
  }
}

void _fillCircle(img.Image canvas, int cx, int cy, int r, img.Color color) {
  for (int dy = -r; dy <= r; dy++) {
    for (int dx = -r; dx <= r; dx++) {
      if (dx * dx + dy * dy <= r * r) {
        final int x = cx + dx;
        final int y = cy + dy;
        if (x >= 0 && y >= 0 && x < canvas.width && y < canvas.height) {
          canvas.setPixelRgba(x, y, color.r, color.g, color.b, 255);
        }
      }
    }
  }
}

img.Image buildRowOfChars(List<List<int>> chars, {int height = 60}) {
  const int charWidth = 50;
  final int width = chars.length * charWidth;
  final img.Image canvas = img.Image(width: width, height: height);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
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
  final ImageProcessingService svc = ImageProcessingService();
  final BrailleDecoder decoder = BrailleDecoder();

  test('segmentDocument menghasilkan sel per karakter dan decode benar', () {
    // Kata "halo"
    final img.Image row = buildRowOfChars([
      const [1, 2, 5], // h
      const [1], // a
      const [1, 2, 3], // l
      const [1, 3, 5], // o
    ]);
    final List<List<img.Image>> lines = svc.segmentDocument(row);
    expect(lines.length, 1, reason: 'Harus ada satu baris');

    final List<img.Image> cells = lines.first;
    expect(cells.length, greaterThanOrEqualTo(4),
        reason: 'Harus ada >= 4 sel, tapi ada ${cells.length}');

    // Decode 4 sel pertama
    final String decoded = cells.take(4).map((c) => decoder.decodeCell(c) ?? '?').join();
    expect(decoded, 'halo', reason: 'Terdecode: "$decoded"');
  });

  test('segmentDocument + decode menghasilkan kata dengan spasi', () {
    // "halo dunia" -> halo<spasi>dunia (10 karakter)
    final img.Image row = buildRowOfChars([
      const [1, 2, 5], // h
      const [1], // a
      const [1, 2, 3], // l
      const [1, 3, 5], // o
      const <int>[], // spasi
      const [1, 4, 5], // d
      const [1, 3, 6], // u
      const [1, 3, 4, 5], // n
      const [2, 4], // i
      const [1], // a
    ]);
    final List<List<img.Image>> lines = svc.segmentDocument(row);
    expect(lines.length, 1);
    final String decoded =
        lines.first.map((c) => decoder.decodeCell(c) ?? ' ').join();
    expect(decoded, 'halo dunia', reason: 'Terdecode: "$decoded"');
  });

  test('invarian skala: foto kecil & besar menghasilkan teks yang sama', () {
    // Gambar ukuran penuh
    final img.Image full = buildRowOfChars([
      const [1, 2, 5], // h
      const [1], // a
      const [1, 2, 3], // l
      const [1, 3, 5], // o
      const [2, 4], // i
    ]);

    // Versi 50% dan 200%
    final img.Image small = img.copyResize(
      full,
      width: (full.width * 0.5).round(),
      interpolation: img.Interpolation.average,
    );
    final img.Image big = img.copyResize(
      full,
      width: full.width * 2,
      interpolation: img.Interpolation.average,
    );

    String decodeRow(img.Image row) {
      final List<List<img.Image>> lines = svc.segmentDocument(row);
      if (lines.isEmpty) return '';
      return lines.first.map((c) => decoder.decodeCell(c) ?? '?').join();
    }

    expect(decodeRow(full), 'haloi', reason: 'full');
    expect(decodeRow(small), 'haloi', reason: 'small (50%)');
    expect(decodeRow(big), 'haloi', reason: 'big (200%)');
  });

  test('segmentDetailed mengembalikan koordinat baris/sel yang menaik', () {
    final img.Image row = buildRowOfChars([
      const [1, 2, 5], // h
      const [1], // a
      const [1, 2, 3], // l
      const [1, 3, 5], // o
    ]);
    final BrailleSegmentation seg = svc.segmentDetailed(row);
    expect(seg.isEmpty, isFalse);
    expect(seg.lines.length, 1);

    final BrailleLineRegion line = seg.lines.first;
    expect(line.height, greaterThan(0));
    expect(line.y, greaterThanOrEqualTo(0));

    // Sel-sel harus berurutan dari kiri ke kanan
    for (int i = 1; i < line.cells.length; i++) {
      expect(
        line.cells[i].x,
        greaterThan(line.cells[i - 1].x),
        reason: 'sel ke-$i tidak lebih kanan dari sel ${i - 1}',
      );
    }
  });
}

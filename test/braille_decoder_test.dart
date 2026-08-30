import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:braille_scan_ai/services/braille_decoder.dart';

/// Membangun sel 28x28 sintetis dengan titik-titik aktif (gelap) pada
/// posisi baris/kolom yang diberikan.
///
/// Posisi titik: [row] 0..2 (atas-tengah-bawah), [col] 0..1 (kiri-kanan).
img.Image buildCell({required List<int> activeRows, required List<int> cols}) {
  final img.Image cell = img.Image(width: 28, height: 28);
  img.fill(cell, color: img.ColorRgb8(255, 255, 255));

  const int subW = 14;
  const int subH = 9;
  for (int r = 0; r < activeRows.length; r++) {
    final int row = activeRows[r];
    final int col = cols[r];
    final int x0 = col * subW;
    final int y0 = row * subH;
    img.fillRect(
      cell,
      x1: x0,
      y1: y0,
      x2: (x0 + subW).clamp(0, 27),
      y2: (y0 + subH).clamp(0, 27),
      color: img.ColorRgb8(0, 0, 0),
    );
  }
  return cell;
}

void main() {
  final BrailleDecoder decoder = BrailleDecoder();

  test('decode sel huruf a (dot 1 - baris atas, kolom kiri)', () {
    final img.Image cell = buildCell(activeRows: const [0], cols: const [0]);
    expect(decoder.decodeCell(cell), 'a');
  });

  test('decode sel huruf b (dot 1,2 - kolom kiri atas & tengah)', () {
    final img.Image cell =
        buildCell(activeRows: const [0, 1], cols: const [0, 0]);
    expect(decoder.decodeCell(cell), 'b');
  });

  test('decode sel huruf c (dot 1,4 - kiri atas, kanan atas)', () {
    final img.Image cell =
        buildCell(activeRows: const [0, 0], cols: const [0, 1]);
    expect(decoder.decodeCell(cell), 'c');
  });

  test('decode sel huruf g (dot 1,2,4,5)', () {
    final img.Image cell = buildCell(
      activeRows: const [0, 1, 0, 1],
      cols: const [0, 0, 1, 1],
    );
    expect(decoder.decodeCell(cell), 'g');
  });

  test('sel kosong bernilai null', () {
    final img.Image cell = img.Image(width: 28, height: 28);
    img.fill(cell, color: img.ColorRgb8(255, 255, 255));
    expect(decoder.decodeCell(cell), isNull);
  });
}

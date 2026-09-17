import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:braillescan_ai/services/braille_classifier.dart';

// Geometri Braille realistis pada kanvas uji.
const int _canvasW = 140;
const int _canvasH = 210;
const int _dotRadius = 7; // diameter 14 (< ambang kolom 18 px)
const List<int> _colX = <int>[52, 88]; // kolom kiri & kanan
const List<int> _rowY = <int>[70, 94, 118]; // baris atas, tengah, bawah

/// Menggambar titik-titik Braille (nomor 1-6) sebagai tonjolan bulat.
void drawDisc(img.Image canvas, int cx, int cy, int r) {
  for (int dy = -r; dy <= r; dy++) {
    for (int dx = -r; dx <= r; dx++) {
      if (dx * dx + dy * dy <= r * r) {
        final int x = cx + dx;
        final int y = cy + dy;
        if (x >= 0 && y >= 0 && x < canvas.width && y < canvas.height) {
          canvas.setPixelRgb(x, y, 30, 30, 30);
        }
      }
    }
  }
}

/// Bangun citra KATA: beberapa sel Braille berjajar kiri -> kanan.
/// pitch kolom = pitch baris = 24, jarak antar sel = 60 (sel lebih renggang).
img.Image buildWord(List<List<int>> cells) {
  const int w = 400;
  const int h = 210;
  const int x0 = 40;
  const int y0 = 80;
  const int colPitch = 24;
  const int rowPitch = 24;
  const int cellPitch = 60;
  const List<(int, int)> posInCell = <(int, int)>[
    (0, 0), // dot 1
    (0, 1), // dot 2
    (0, 2), // dot 3
    (1, 0), // dot 4
    (1, 1), // dot 5
    (1, 2), // dot 6
  ];
  final img.Image canvas = img.Image(width: w, height: h);
  img.fill(canvas, color: img.ColorRgb8(240, 240, 240));
  for (int ci = 0; ci < cells.length; ci++) {
    final int baseX = x0 + ci * cellPitch;
    for (final int d in cells[ci]) {
      final (int col, int row) = posInCell[d - 1];
      drawDisc(canvas, baseX + col * colPitch, y0 + row * rowPitch, _dotRadius);
    }
  }
  return canvas;
}

img.Image buildCell(List<int> dots) {
  final img.Image canvas = img.Image(width: _canvasW, height: _canvasH);
  img.fill(canvas, color: img.ColorRgb8(240, 240, 240));

  final Map<int, (int, int)> pos = <int, (int, int)>{
    1: (_colX[0], _rowY[0]),
    2: (_colX[0], _rowY[1]),
    3: (_colX[0], _rowY[2]),
    4: (_colX[1], _rowY[0]),
    5: (_colX[1], _rowY[1]),
    6: (_colX[1], _rowY[2]),
  };

  for (final int d in dots) {
    final (int cx, int cy) = pos[d]!;
    drawDisc(canvas, cx, cy, _dotRadius);
  }
  return canvas;
}

int countDark(img.Image image, {int xMin = 0, int xMax = 28, int yMin = 0, int yMax = 28}) {
  int count = 0;
  for (int y = yMin; y < yMax; y++) {
    for (int x = xMin; x < xMax; x++) {
      if (img.getLuminance(image.getPixel(x, y)) < 210) count++;
    }
  }
  return count;
}

// Pusat 6 titik pada citra keluaran 28x28 (kanvas 140x210 diperkecil 0.2x/0.133x):
// kolom kiri x~9, kanan x~19 ; baris atas y~7, tengah y~14, bawah y~21.
const List<int> _outColX = <int>[9, 19];
const List<int> _outRowY = <int>[7, 14, 21];

/// Apakah titik Braille (row 0-2, col 0-1) menyala pada citra 28x28.
bool cellOn(img.Image image, int row, int col) {
  final int cx = _outColX[col];
  final int cy = _outRowY[row];
  int dark = 0;
  for (int y = cy - 2; y <= cy + 2; y++) {
    for (int x = cx - 2; x <= cx + 2; x++) {
      if (x >= 0 && y >= 0 && x < image.width && y < image.height) {
        if (img.getLuminance(image.getPixel(x, y)) < 128) dark++;
      }
    }
  }
  return dark > 0;
}

/// Himpunan sel menyala sebagai string "row,col".
Set<String> litCells(img.Image image) {
  final Set<String> cells = <String>{};
  for (int r = 0; r < 3; r++) {
    for (int c = 0; c < 2; c++) {
      if (cellOn(image, r, c)) cells.add('$r,$c');
    }
  }
  return cells;
}

/// Simulasi jalur penuh: kompensasi -90° di Dart, lalu plugin native
/// memutar +90° CW. Hasil harus identik dengan citra tegak lurus semula.
img.Image simulatePluginRoundTrip(
  BrailleClassifier classifier,
  img.Image upright,
) {
  final img.Image sent = classifier.applyOrientationCompensation(upright);
  return img.copyRotate(sent, angle: 90);
}

/// Bandingkan dua citra piksel per piksel (luminance).
void expectImagesIdentical(img.Image actual, img.Image expected) {
  expect(actual.width, expected.width);
  expect(actual.height, expected.height);
  for (int y = 0; y < expected.height; y++) {
    for (int x = 0; x < expected.width; x++) {
      expect(
        img.getLuminance(actual.getPixel(x, y)).round(),
        img.getLuminance(expected.getPixel(x, y)).round(),
        reason: 'piksel ($x,$y) berbeda',
      );
    }
  }
}

void main() {
  final BrailleClassifier classifier = BrailleClassifier();

  test('preprocessed: sel kosong menghasilkan kanvas putih 28x28', () {
    final img.Image out = classifier.preprocessed(buildCell(const []));

    expect(out.width, 28);
    expect(out.height, 28);
    expect(countDark(out), 0);
  });

  test('preprocessed: huruf "b" (titik 1,2) -> kolom kiri, baris atas+tengah', () {
    final img.Image out = classifier.preprocessed(buildCell(const [1, 2]));

    // Kolom kiri (separuh kiri) & hanya pada dua baris atas (y < 19).
    expect(countDark(out, xMin: 0, xMax: 14), greaterThan(0));
    expect(countDark(out, xMin: 14, xMax: 28), 0);
    expect(countDark(out, yMin: 0, yMax: 19), greaterThan(0));
    expect(countDark(out, yMin: 19, yMax: 28), 0);
  });

  test('preprocessed: huruf "k" (titik 1,3) -> baris atas & bawah, tanpa tengah', () {
    final img.Image out = classifier.preprocessed(buildCell(const [1, 3]));

    // Kolom kiri saja.
    expect(countDark(out, xMin: 0, xMax: 14), greaterThan(0));
    expect(countDark(out, xMin: 14, xMax: 28), 0);
    // Ada titik di baris atas dan di baris bawah (bukan cuma menumpuk atas).
    expect(countDark(out, yMin: 0, yMax: 10), greaterThan(0));
    expect(countDark(out, yMin: 19, yMax: 28), greaterThan(0));
  });

  test('preprocessed: huruf "c" (titik 1,4) -> dua kolom, baris atas', () {
    final img.Image out = classifier.preprocessed(buildCell(const [1, 4]));

    expect(countDark(out, xMin: 0, xMax: 14), greaterThan(0));
    expect(countDark(out, xMin: 14, xMax: 28), greaterThan(0));
    expect(countDark(out, yMin: 19, yMax: 28), 0);
  });

  test('preprocessed: pola lebih padat daripada sel kosong', () {
    final int filled = countDark(classifier.preprocessed(buildCell(const [1, 2])));
    final int blank = countDark(classifier.preprocessed(buildCell(const [])));
    expect(filled, greaterThan(blank));
  });

  test(
    'preprocessed: noise & bayangan bawah tidak menciptakan titik palsu '
    'di baris 3',
    () {
      // Sel 'b' (baris 0 & 1) + noise: satu titik normal jauh di bawah sel
      // dan satu lipatan/bayangan memanjang.
      final img.Image canvas = buildCell(const [1, 2]);
      drawDisc(canvas, 52, 195, 7); // titik palsu jauh di bawah
      for (int y = 168; y <= 172; y++) {
        for (int x = 20; x <= 120; x++) {
          canvas.setPixelRgb(x, y, 40, 40, 40); // lipatan kertas memanjang
        }
      }

      final img.Image out = classifier.preprocessed(canvas);

      // Tanpa filter, noise ini bisa ter-clamp ke baris 3 (bawah, y >= 19).
      expect(countDark(out, yMin: 19, yMax: 28), 0);
      // Titik asli 'b' (baris 0 & 1) tetap ada.
      expect(countDark(out, xMin: 0, xMax: 14, yMin: 0, yMax: 19), greaterThan(0));
    },
  );

  // ---------------------------------------------------------------
  // Orientasi global: berlaku untuk SEMUA bentuk huruf, bukan hanya D.
  // Jalur: preprocessed (tegak lurus seperti Colab) -> kompensasi -90° di
  // Dart -> plugin native +90° CW. Hasil akhir harus identik piksel-per-piksel
  // dengan citra tegak lurus, dan posisi sel titik harus persis sama.
  // ---------------------------------------------------------------
  group('orientasi global multi-huruf (-90° lalu +90° plugin)', () {
    // Nomor titik Braille -> sel (row, col): dot1(0,0) dot2(1,0) dot3(2,0)
    // dot4(0,1) dot5(1,1) dot6(2,1).
    String dotCell(int dot) => '${(dot - 1) % 3},${(dot - 1) ~/ 3}';

    // Bentuk-bentuk yang diminta: 1 titik, vertikal, horizontal, diagonal.
    final Map<String, List<int>> letters = <String, List<int>>{
      'a': <int>[1], // 1 titik
      'b': <int>[1, 2], // vertikal murni
      'l': <int>[1, 2, 3], // vertikal murni penuh
      'c': <int>[1, 4], // horizontal murni
      'd': <int>[1, 4, 5], // diagonal / asimetris
      'e': <int>[1, 5], // asimetris
      'f': <int>[1, 2, 4], // asimetris
    };

    setUp(() => BrailleClassifier.orientationCompensationDegrees = -90);
    tearDown(() => BrailleClassifier.orientationCompensationDegrees = -90);

    letters.forEach((String letter, List<int> dots) {
      test('huruf "$letter" titik $dots: sel & round-trip identik', () {
        final Set<String> expected = dots.map(dotCell).toSet();

        // 1) Citra tegak lurus (orientasi kanvas Colab) ada di sel yang benar.
        final img.Image upright = classifier.preprocessed(buildCell(dots));
        expect(litCells(upright), expected, reason: 'sel awal huruf $letter');

        // 2) Setelah -90° (Dart) lalu +90° (plugin), sel tetap sama persis.
        final img.Image roundTrip =
            simulatePluginRoundTrip(classifier, upright);
        expect(
          litCells(roundTrip),
          expected,
          reason: 'sel huruf $letter berubah setelah round-trip orientasi',
        );

        // 3) Identik piksel-per-piksel => tidak ada flip/geser tersembunyi.
        expectImagesIdentical(roundTrip, upright);
      });
    });

    test(
      'tidak ada flip horizontal/vertikal: sel asimetris tetap di posisinya',
      () {
        // 'b' hanya di kolom kiri; flip horizontal akan memindahkannya ke
        // kolom kanan. 'l' memakai baris atas-tengah-bawah; flip vertikal
        // akan menukar barisnya. Keduanya harus tetap persis.
        expect(litCells(classifier.preprocessed(buildCell(const [1, 2]))),
            <String>{'0,0', '1,0'});
        expect(litCells(classifier.preprocessed(buildCell(const [1, 2, 3]))),
            <String>{'0,0', '1,0', '2,0'});
        expect(litCells(classifier.preprocessed(buildCell(const [1, 4, 5]))),
            <String>{'0,0', '0,1', '1,1'});
      },
    );
  });

  // ---------------------------------------------------------------
  // Segmentasi KATA (predictWord): blob dikelompokkan menjadi sel-sel Braille
  // berdasarkan jarak horizontal (dalam sel lebih rapat daripada antar sel),
  // lalu diurutkan kiri -> kanan.
  // ---------------------------------------------------------------
  group('segmentasi kata menjadi sel Braille', () {
    test('4 sel campuran: 1 / 2 / 2 / 3 titik, urut kiri->kanan', () {
      // a=[1] ; b=[1,2] ; c=[1,4] ; d=[1,4,5]
      final img.Image word = buildWord(const <List<int>>[
        <int>[1],
        <int>[1, 2],
        <int>[1, 4],
        <int>[1, 4, 5],
      ]);

      final List<BrailleCell> cells = classifier.segmentCellsForTest(word);

      expect(cells.length, 4);
      expect(
        cells.map((BrailleCell c) => c.dotCount).toList(),
        <int>[1, 2, 2, 3],
      );
      for (int i = 1; i < cells.length; i++) {
        expect(
          cells[i - 1].minX,
          lessThan(cells[i].minX),
          reason: 'sel harus terurut dari kiri ke kanan',
        );
      }
    });

    test('huruf 1-kolom berurutan tidak tergabung (a, b, l)', () {
      // Semua hanya kolom kiri; jarak ke sel berikutnya tetap lebih besar.
      final img.Image word = buildWord(const <List<int>>[
        <int>[1], // a
        <int>[1, 2], // b
        <int>[1, 2, 3], // l
      ]);

      final List<BrailleCell> cells = classifier.segmentCellsForTest(word);

      expect(cells.length, 3);
      expect(
        cells.map((BrailleCell c) => c.dotCount).toList(),
        <int>[1, 2, 3],
      );
    });

    test('dua kolom bergabung jadi satu sel, antar sel tetap terpisah', () {
      // c, c (masing-masing titik 1 & 4 = 2 kolom dalam 1 sel).
      final img.Image word = buildWord(const <List<int>>[
        <int>[1, 4],
        <int>[1, 4],
      ]);

      final List<BrailleCell> cells = classifier.segmentCellsForTest(word);

      expect(cells.length, 2);
      expect(
        cells.map((BrailleCell c) => c.dotCount).toList(),
        <int>[2, 2],
      );
    });

    test('tanpa titik -> tidak ada sel', () {
      final img.Image blank = img.Image(width: 300, height: 210);
      img.fill(blank, color: img.ColorRgb8(240, 240, 240));
      expect(classifier.segmentCellsForTest(blank), isEmpty);
    });
  });
}
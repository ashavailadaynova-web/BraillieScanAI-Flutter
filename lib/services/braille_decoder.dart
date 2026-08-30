import 'package:image/image.dart' as img;

/// Decoder Braille berbasis aturan/template (tanpa ML) yang membaca pola
/// 2x3 titik pada sebuah sel gambar lalu memetakannya ke huruf sesuai
/// Braille Grade 1 standar.
///
/// Pendekatan ini jauh lebih andal daripada model AI untuk gambar Braille
/// yang bersih & terang (termasuk hasil upload dari galeri), karena pola
/// Braille bersifat deterministik: setiap huruf = kombinasi spesifik dari
/// 6 titik.
///
/// Stempel posisi titik (dot 1-6) pada sel 2 kolom x 3 baris:
///
///   1 4
///   2 5
///   3 6
class BrailleDecoder {
  /// Pendeteksi sel kosong (spasi) berbasis variansi -- disisipkan agar
  /// decoder bisa langsung dipakai menggantikan `ImageProcessingService`.
  static const double varianceThreshold = 35.0;

  /// Tabel Braille Grade 1 (alfabet a-z) berdasarkan kombinasi enam titik.
  ///
  /// Indeks bit (bit 0..5 = dot 1..6) dengan bobot:
  ///   dot1=1, dot2=2, dot3=4, dot4=8, dot5=16, dot6=32
  ///
  /// Braille standar (a-z):
  ///   a=1 b=12 c=14 d=145 e=15 f=124 g=1245 h=125 i=24 j=245
  ///   k=13 l=123 m=134 n=1345 o=135 p=1234 q=12345 r=1235 s=234 t=2345
  ///   u=136 v=1236 w=2456 x=1346 y=13456 z=1356
  static const Map<int, String> _letterMap = {
    1: 'a', // dot 1
    3: 'b', // dot 12
    9: 'c', // dot 14
    25: 'd', // dot 145
    17: 'e', // dot 15
    11: 'f', // dot 124
    27: 'g', // dot 1245
    19: 'h', // dot 125
    10: 'i', // dot 24
    26: 'j', // dot 245
    5: 'k', // dot 13
    7: 'l', // dot 123
    13: 'm', // dot 134
    29: 'n', // dot 1345
    21: 'o', // dot 135
    15: 'p', // dot 1234
    31: 'q', // dot 12345
    23: 'r', // dot 1235
    14: 's', // dot 234
    30: 't', // dot 2345
    37: 'u', // dot 136
    39: 'v', // dot 1236
    58: 'w', // dot 2456
    45: 'x', // dot 1346
    61: 'y', // dot 13456
    53: 'z', // dot 1356
  };

  /// Menentukan posisi 6 titik di dalam sebuah sel gambar berukuran bebas,
  /// lalu men-decode pola titik tersebut menjadi huruf a-z.
  ///
  /// Mengembalikan `null` bila sel dianggap kosong (tidak ada titik sama
  /// sekali), dan `'?'` bila pola titik dikenali tapi tidak dikenal.
  String? decodeCell(img.Image cell) {
    if (cell.width == 0 || cell.height == 0) return null;

    const int cols = 2;
    const int rows = 3;
    final int cellW = cell.width ~/ cols;
    final int cellH = cell.height ~/ rows;

    if (cellW < 2 || cellH < 2) return null;

    // Baca rata-rata luminans di WILAYAH INTI tiap sub-sel titik. Titik
    // Braille terletak di pusat sub-sel, jadi mengambil seluruh strip
    // (termasuk kertas di tepi) hanya melemahkan sinyal. Ambil 50% tengah.
    final double coreInsetX = cellW * 0.25;
    final double coreInsetY = cellH * 0.25;
    final int coreW = (cellW * 0.5).round().clamp(1, cellW);
    final int coreH = (cellH * 0.5).round().clamp(1, cellH);

    final List<double> dotMean = List<double>.filled(6, 0.0);
    for (int dot = 0; dot < 6; dot++) {
      final int col = dot % cols;
      final int row = dot ~/ cols;
      final int x0 = (col * cellW + coreInsetX).round();
      final int y0 = (row * cellH + coreInsetY).round();
      dotMean[dot] = _meanLuminance(
        cell,
        x0: x0,
        y0: y0,
        w: coreW,
        h: coreH,
      );
    }

    // Normalisasi: bayangan/titik tampil lebih gelap (luminans rendah).
    // Hitung rentang untuk adaptive threshold per sel. Threshold sedikit
    // di bawah nilai tertinggi agar titik yang kontras sedang tetap terbaca.
    double minLum = 255.0;
    double maxLum = 0.0;
    for (int i = 0; i < 6; i++) {
      if (dotMean[i] < minLum) minLum = dotMean[i];
      if (dotMean[i] > maxLum) maxLum = dotMean[i];
    }
    final double range = maxLum - minLum;
    if (range < 1.0) return null; // datar -> kosong

    final double threshold = maxLum - (range * 0.4);

    // Bobot Braille untuk tiap posisi dot (indeks 0..5 = kolom-major):
    //   dot0=kiri-atas(dot1)=1, dot1=kanan-atas(dot4)=8,
    //   dot2=kiri-tengah(dot2)=2, dot3=kanan-tengah(dot5)=16,
    //   dot4=kiri-bawah(dot3)=4, dot5=kanan-bawah(dot6)=32.
    const List<int> dotWeights = <int>[1, 8, 2, 16, 4, 32];

    int pattern = 0;
    for (int i = 0; i < 6; i++) {
      if (dotMean[i] < threshold) {
        pattern |= dotWeights[i];
      }
    }

    if (pattern == 0) return null; // tidak ada titik -> kosong

    return _letterMap[pattern] ?? '?';
  }

  static bool isCellEmpty(img.Image cell) {
    if (cell.width == 0 || cell.height == 0) return true;

    double sum = 0;
    int count = 0;
    for (int y = 0; y < cell.height; y++) {
      for (int x = 0; x < cell.width; x++) {
        sum += cell.getPixel(x, y).luminance;
        count++;
      }
    }
    if (count == 0) return true;
    final double mean = sum / count;

    double varianceSum = 0;
    for (int y = 0; y < cell.height; y++) {
      for (int x = 0; x < cell.width; x++) {
        final double l = cell.getPixel(x, y).luminance.toDouble();
        varianceSum += (l - mean) * (l - mean);
      }
    }
    return (varianceSum / count) < varianceThreshold;
  }

  static double _meanLuminance(img.Image img2, {
    required int x0,
    required int y0,
    required int w,
    required int h,
  }) {
    double sum = 0;
    int count = 0;
    for (int dy = 0; dy < h; dy++) {
      final int y = y0 + dy;
      if (y >= img2.height) break;
      for (int dx = 0; dx < w; dx++) {
        final int x = x0 + dx;
        if (x >= img2.width) break;
        sum += img2.getPixel(x, y).luminance;
        count++;
      }
    }
    return count == 0 ? 255.0 : sum / count;
  }
}

import 'package:image/image.dart' as img;

/// Merepresentasikan satu rentang indeks (band) hasil analisis proyeksi
/// kegelapan piksel 1 dimensi. Dipakai untuk mendeteksi baris maupun kolom.
class _Band {
  final int start;
  final int end;
  const _Band(this.start, this.end);
}

/// Satu sel Braille (satu karakter) hasil pemotongan, beserta posisinya
/// dalam koordinat citra kerja (sebelum resize ke 28x28).
class BrailleCellRegion {
  final int x;
  final int y;
  final int width;
  final int height;
  final img.Image normalized;

  const BrailleCellRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.normalized,
  });
}

/// Satu baris Braille hasil deteksi, beserta posisi & sel-sel di dalamnya.
class BrailleLineRegion {
  final int y;
  final int height;
  final List<BrailleCellRegion> cells;

  const BrailleLineRegion({
    required this.y,
    required this.height,
    required this.cells,
  });
}

/// Hasil segmentasi lengkap: citra kerja (mungkin sudah dinormalisasi
/// skala) plus semua baris/sel yang terdeteksi beserta koordinatnya.
class BrailleSegmentation {
  final img.Image image;
  final double scale;
  final List<BrailleLineRegion> lines;

  const BrailleSegmentation({
    required this.image,
    required this.scale,
    required this.lines,
  });

  bool get isEmpty => lines.isEmpty;
}

/// Service yang menangani seluruh operasi pra-pemrosesan citra dokumen
/// Braille: penajaman bayangan bintik timbul (shadow-depth), deteksi sel
/// kosong (spasi), normalisasi skala, dan pemotongan dokumen penuh menjadi
/// sel-sel individual berukuran 28x28 piksel.
class ImageProcessingService {
  /// Ukuran KERJA INTERNAL tiap sel Braille (2x3 titik) setelah dipotong
  /// dari dokumen -- representasi seragam antar sel, sesuai Concept Paper
  /// (sel 28x28). Resize final ke ukuran input model dilakukan di dalam
  /// `TFLiteService` (yang menyesuaikan kontrak model 28x28x1 / 224x224x3),
  /// sehingga service ini tetap independen terhadap model AI tertentu.
  static const int cellSize = 28;

  /// Ukuran minimum (dalam piksel) sebuah band baris/kolom agar dianggap
  /// valid, untuk menyaring noise kecil pada proyeksi.
  static const int _minRowBandSize = 6;
  static const int _minColBandSize = 5;

  /// Tinggi target satu baris karakter Braille setelah normalisasi skala.
  /// Foto kamera bisa membuat sel sangat kecil atau sangat besar; dengan
  /// menormalkan ke tinggi ini, deteksi dot-pitch menjadi konsisten.
  static const double _targetLineHeight = 64.0;

  /// Preprocessing Shadow-Depth: mengubah citra ke grayscale, mempertajam
  /// bayangan bintik timbul (kernel directional yang mensimulasikan cahaya
  /// samping 30-45 derajat), lalu menaikkan kontras lokal agar titik
  /// Braille lebih mudah dibedakan dari kertas.
  img.Image preprocessForShadowDepth(img.Image input) {
    // 1. Grayscale.
    final img.Image gray = img.grayscale(input);

    // 2. Kernel emboss terarah -- memodelkan bayangan bintik timbul yang
    //    timbul saat dokumen difoto dengan kemiringan 30-45 derajat.
    final List<double> directionalShadowKernel = <double>[
      -1, -1, 0,
      -1, 1, 1,
      0, 1, 1,
    ];

    img.Image processed = img.convolution(
      gray,
      filter: directionalShadowKernel,
      div: 1,
      offset: 128,
    );

    // 3. Normalisasi + penajaman kontras agar titik vs kertas lebih tegas.
    processed = img.normalize(processed, min: 0, max: 255);
    processed = img.adjustColor(processed, contrast: 1.35, brightness: 1.02);

    // 4. Sedikit gaussian blur untuk meredam noise sensor kamera sebelum
    //    tahap segmentasi grid.
    processed = img.gaussianBlur(processed, radius: 1);

    return processed;
  }

  /// **Binarisasi Otsu (adaptive threshold)** -- Tahap 1 Concept Paper.
  ///
  /// Kertas Braille tidak punya tinta, hanya tonjolan + bayangan. Setelah
  /// penguatan bayangan, histogram luminance menjadi bimodal (titik gelap
  /// vs kertas terang). Otsu memilih ambang yang memisahkan dua kelas itu
  /// secara otomatis sehingga titik menjadi hitam pekat dan kertas putih
  /// bersih -- memudahkan segmentasi maupun deteksi pola titik.
  img.Image otsuBinarize(img.Image input) {
    final img.Image gray = img.grayscale(input);
    final int w = gray.width;
    final int h = gray.height;
    final int total = w * h;
    if (total == 0) return gray;

    // Histogram luminance.
    final List<int> hist = List<int>.filled(256, 0);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int l = gray.getPixel(x, y).luminance.toInt().clamp(0, 255);
        hist[l]++;
      }
    }

    // Otsu: cari ambang yang memaksimalkan antara-kelas variance.
    double sumAll = 0;
    for (int i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }
    double sumB = 0;
    int wB = 0;
    double maxBetween = -1;
    int threshold = 128;
    for (int t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final int wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final double mB = sumB / wB;
      final double mF = (sumAll - sumB) / wF;
      final double diff = mB - mF;
      final double between = wB * wF * diff * diff;
      if (between > maxBetween) {
        maxBetween = between;
        threshold = t;
      }
    }

    // Terapkan: luminance di bawah ambang -> hitam (titik/bayangan).
    final img.Image out = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int l = gray.getPixel(x, y).luminance.toInt();
        final int v = l < threshold ? 0 : 255;
        out.setPixelRgba(x, y, v, v, v, 255);
      }
    }
    return out;
  }

  /// Memotong dokumen penuh menjadi baris-baris (berdasarkan proyeksi
  /// kegelapan horizontal), lalu tiap baris dipotong menjadi sel-sel
  /// karakter yang dinormalisasi ke ukuran 28x28 piksel.
  ///
  /// Mengembalikan `List<List<img.Image>>`: satu List per baris, berisi
  /// sel-sel terurut dari kiri ke kanan. (Kebalikan kompatibel dari
  /// [segmentDetailed].)
  List<List<img.Image>> segmentDocument(img.Image input) {
    final BrailleSegmentation segmentation = segmentDetailed(input);
    return segmentation.lines
        .map((BrailleLineRegion l) =>
            l.cells.map((BrailleCellRegion c) => c.normalized).toList())
        .toList();
  }

  /// Segmentasi penuh dengan koordinat & normalisasi skala.
  ///
  /// Bergerak dari citra mentah -> menormalkan skala -> mendeteksi baris ->
  /// memotong tiap baris menjadi sel-sel karakter (advancing grille).
  /// Mengembalikan citra kerja (bisa saja berubah ukuran) bersama [scale]
  /// (koordinat citra kerja ÷ koordinat citra asli) dan semua baris.
  BrailleSegmentation segmentDetailed(img.Image input) {
    // 1. Normalisasi skala agar tinggi baris ~ _targetLineHeight.
    final img.Image work = _normalizeScale(input);
    final double scale = work.width / input.width;

    final List<_Band> rowBands = _detectRowBands(work);
    if (rowBands.isEmpty) {
      return BrailleSegmentation(image: work, scale: scale, lines: []);
    }

    // Satu baris teks Braille = TIGA baris titik (atas-tengah-bawah) yang
    // sangat berdekatan. Deteksi band baris naif memecahnya menjadi beberapa
    // band; gabungkan band-band yang saling berdekatan jadi satu baris.
    final List<_Band> lineBands = _groupBandsIntoLines(rowBands);

    final List<BrailleLineRegion> lines = <BrailleLineRegion>[];
    for (final _Band lineBand in lineBands) {
      final img.Image lineImage = img.copyCrop(
        work,
        x: 0,
        y: lineBand.start,
        width: work.width,
        height: lineBand.end - lineBand.start,
      );

      final List<BrailleCellRegion> cells = _sliceLineToCellsDetailed(
        lineImage,
        yOffset: lineBand.start,
      );

      if (cells.isNotEmpty) {
        lines.add(
          BrailleLineRegion(
            y: lineBand.start,
            height: lineBand.end - lineBand.start,
            cells: cells,
          ),
        );
      }
    }

    return BrailleSegmentation(image: work, scale: scale, lines: lines);
  }

  /// Menormalkan skala citra: pertama mengecilkan jika terlalu lebar (untuk
  /// kinerja), lalu me-resize sehingga tinggi baris Braille pertama ~
  /// [_targetLineHeight] piksel. Dengan begitu pitch dot selalu konsisten
  /// terlepas dari seberapa jauh/kecil braille difoto.
  img.Image _normalizeScale(img.Image input) {
    img.Image work = input;

    // Batasi lebar maksimal untuk kinerja & kestabilan deteksi.
    if (work.width > 1600) {
      work = img.copyResize(
        work,
        width: 1600,
        interpolation: img.Interpolation.average,
      );
    }

    // Estimasi tinggi baris Braille pertama.
    final List<_Band> rowBands = _detectRowBands(work);
    if (rowBands.length < 2) return work;
    final List<_Band> lineBands = _groupBandsIntoLines(rowBands);
    if (lineBands.isEmpty) return work;

    final int cellH = lineBands.first.end - lineBands.first.start;
    if (cellH <= 0) return work;

    final double targetScale = _targetLineHeight / cellH;
    if (targetScale <= 0) return work;
    if ((targetScale - 1.0).abs() < 0.08) return work;
    if (targetScale < 0.05 || targetScale > 10.0) return work;

    return img.copyResize(
      work,
      width: (work.width * targetScale).round().clamp(1, 6000),
      interpolation: img.Interpolation.average,
    );
  }

  /// Menggabungkan band-baristitik yang berdekatan (bagian dari satu baris
  /// teks Braille) menjadi satu band baris yang utuh.
  ///
  /// Jarak (gap) antar baris titik di dalam satu karakter jauh lebih kecil
  /// daripada celah kosong antar baris teks. Gap yang lebih kecil atau sama
  /// dengan tinggi band tipikal dianggap masih satu baris.
  List<_Band> _groupBandsIntoLines(List<_Band> bands) {
    final List<_Band> result = <_Band>[];

    int sumH = 0;
    for (final _Band b in bands) {
      sumH += b.end - b.start;
    }
    final double avgH = sumH / bands.length;
    final double mergeThreshold = avgH * 1.2;
    if (avgH <= 0) return <_Band>[_Band(bands.first.start, bands.last.end)];

    int start = bands.first.start;
    int prevEnd = bands.first.end;

    for (int i = 1; i < bands.length; i++) {
      final _Band b = bands[i];
      final int gap = b.start - prevEnd;
      if (gap <= mergeThreshold) {
        prevEnd = b.end;
      } else {
        result.add(_Band(start, prevEnd));
        start = b.start;
        prevEnd = b.end;
      }
    }
    result.add(_Band(start, prevEnd));
    return result;
  }

  /// Memotong satu baris menjadi sel-sel karakter Braille (masing-masing
  /// berisi grid 2x3 titik) dengan teknik **Advancing Grille**.
  ///
  /// Alih-alih menganggap satu kolom kegelapan = satu sel (yang keliru
  /// karena satu karakter Braille terdiri dari DUA kolom titik yang
  /// dipisahkan lembah terang), teknik ini:
  ///  1. Mendeteksi kolom-kolom titik sebagai band gelap.
  ///  2. Mengestimasi "dot pitch" (jarak antar kolom titik) dari jarak antar
  ///     pusat band yang paling umum.
  ///  3. Membangun grid dengan lebar-sel = 2 × pitch (titik kiri + kanan),
  ///     bergerak maju sepanjang baris.
  List<BrailleCellRegion> _sliceLineToCellsDetailed(
    img.Image line, {
    required int yOffset,
  }) {
    // Deteksi kolom-kolom titik sebagai band gelap. Tiap kolom titik (kiri
    // atau kanan dari karakter) menjadi satu band.
    final List<_Band> colBands = _detectColumnBands(line);
    if (colBands.length < 2) {
      return _sliceByBandDetailed(line, yOffset: yOffset);
    }

    // Pusat tiap band kolom = posisi kolom titik.
    final List<double> centers = <double>[];
    for (final _Band b in colBands) {
      centers.add((b.start + b.end) / 2.0);
    }

    // Estimasi dot pitch = median jarak antar pusat band berurutan.
    final List<double> distances = <double>[];
    for (int i = 1; i < centers.length; i++) {
      distances.add(centers[i] - centers[i - 1]);
    }
    distances.sort();
    final double dotPitch = distances[distances.length ~/ 2];
    if (dotPitch < 4.0) return _sliceByBandDetailed(line, yOffset: yOffset);

    // Lebar satu karakter = 2 × dot pitch (kolom titik kiri + kanan).
    final double cellWidth = dotPitch * 2.0;

    // Kiri sel pertama: sejajarkan ke pusat band pertama minus satu pitch.
    double left = centers.first - dotPitch;
    if (left < 1) left = 1;

    final List<BrailleCellRegion> cells = <BrailleCellRegion>[];
    double cursor = left;
    while (cursor < line.width) {
      final int x0 = cursor.round();
      if (x0 >= line.width) break;
      int w = cellWidth.round();
      final int xEnd = (x0 + w >= line.width) ? line.width : x0 + w;
      w = xEnd - x0;
      if (w < 2) break;

      cells.add(
        _makeCellRegion(
          line,
          x: x0,
          yOffset: yOffset,
          width: w,
        ),
      );

      cursor += cellWidth;
      if (xEnd >= line.width) break;
    }

    return cells;
  }

  BrailleCellRegion _makeCellRegion(
    img.Image line, {
    required int x,
    required int yOffset,
    required int width,
  }) {
    final img.Image rawCell = img.copyCrop(
      line,
      x: x,
      y: 0,
      width: width,
      height: line.height,
    );
    final img.Image normalized = img.copyResize(
      rawCell,
      width: cellSize,
      height: cellSize,
      interpolation: img.Interpolation.average,
    );
    return BrailleCellRegion(
      x: x,
      y: yOffset,
      width: width,
      height: line.height,
      normalized: normalized,
    );
  }

  /// Fallback lama: satu band kolom = satu sel. Tetap dipakai bila deteksi
  /// pitch gagal (mis. gambar terlalu kabur).
  List<BrailleCellRegion> _sliceByBandDetailed(
    img.Image line, {
    required int yOffset,
  }) {
    final List<_Band> colBands = _detectColumnBands(line);
    return colBands
        .map(
          (_Band colBand) => _makeCellRegion(
            line,
            x: colBand.start,
            yOffset: yOffset,
            width: colBand.end - colBand.start,
          ),
        )
        .toList();
  }

  /// Mendeteksi rentang baris berdasarkan proyeksi kegelapan piksel
  /// horizontal. Baris Braille dipisahkan oleh jalur kosong vertikal.
  List<_Band> _detectRowBands(img.Image input) {
    final List<double> rowDarkness = List<double>.filled(input.height, 0);

    for (int y = 0; y < input.height; y++) {
      double sum = 0;
      for (int x = 0; x < input.width; x++) {
        sum += 255 - input.getPixel(x, y).luminance;
      }
      rowDarkness[y] = sum / input.width;
    }

    return _bandsFromProjection(rowDarkness, minBandSize: _minRowBandSize);
  }

  /// Mendeteksi rentang kolom (sel) dalam satu baris berdasarkan proyeksi
  /// kegelapan piksel vertikal.
  List<_Band> _detectColumnBands(img.Image line) {
    final List<double> colDarkness = List<double>.filled(line.width, 0);

    for (int x = 0; x < line.width; x++) {
      double sum = 0;
      for (int y = 0; y < line.height; y++) {
        sum += 255 - line.getPixel(x, y).luminance;
      }
      colDarkness[x] = sum / line.height;
    }

    return _bandsFromProjection(colDarkness, minBandSize: _minColBandSize);
  }

  /// Algoritma umum untuk mengekstrak band (rentang indeks aktif) dari
  /// sebuah array proyeksi 1 dimensi, dipisahkan oleh celah (gap) di bawah
  /// **ambang adaptif**.
  ///
  /// Ambang dihitung relatif terhadap kegelapan maksimum agar bekerja baik
  /// untuk foto dengan baseline cahaya yang tinggi (bayangan, kertas tidak
  /// putih murni) maupun yang kontrasnya rendah.
  List<_Band> _bandsFromProjection(
    List<double> projection, {
    required int minBandSize,
  }) {
    final List<_Band> bands = <_Band>[];

    double maxVal = 0;
    for (final double v in projection) {
      if (v > maxVal) maxVal = v;
    }
    if (maxVal < 2.0) return bands;

    // 18% dari puncak maksimum, minimal 2.0 -- cukup untuk memisahkan
    // titik (gelap) dari kertas (terang).
    final double threshold = mathMax(maxVal * 0.18, 2.0);

    int? start;
    for (int i = 0; i < projection.length; i++) {
      final bool isActive = projection[i] > threshold;

      if (isActive && start == null) {
        start = i;
      } else if (!isActive && start != null) {
        if (i - start >= minBandSize) {
          bands.add(_Band(start, i));
        }
        start = null;
      }
    }

    if (start != null && projection.length - start >= minBandSize) {
      bands.add(_Band(start, projection.length));
    }

    return bands;
  }

  static double mathMax(double a, double b) => a > b ? a : b;
}
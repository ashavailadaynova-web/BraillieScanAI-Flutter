import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'braille_decoder.dart';
import 'braille_parser.dart';
import 'image_processing_service.dart';
import 'tflite_service.dart';

/// Posisi + label satu sel Braille untuk digambar di atas gambar sumber.
class BrailleOverlayCell {
  final double x;
  final double y;
  final double width;
  final double height;
  final String label;
  final bool isLowConfidence;

  const BrailleOverlayCell({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.label,
    required this.isLowConfidence,
  });
}

/// Satu baris hasil terjemahan + kotak batasnya untuk keperluan overlay
/// (mirip Google Lens): kalimat muncul tepat di atas baris Braille sumber.
class BrailleOverlayLine {
  final double x;
  final double y;
  final double width;
  final double height;
  final String text;
  final List<BrailleOverlayCell> cells;

  const BrailleOverlayLine({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.text,
    required this.cells,
  });
}

/// Hasil lengkap satu kali proses pemindaian dokumen Braille.
class BrailleScanResult {
  final String text;

  /// Byte gambar sumber (untuk ditampilkan di layar hasil/overlay).
  final Uint8List? imageBytes;
  final int imageWidth;
  final int imageHeight;

  final List<List<BrailleCellPrediction>> rawPredictionsPerLine;

  /// Baris-baris terdeteksi dengan kotak batas + teks, koordinat mengacu ke
  /// citra sumber (imageWidth x imageHeight).
  final List<BrailleOverlayLine> overlayLines;

  const BrailleScanResult({
    required this.text,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.rawPredictionsPerLine,
    required this.overlayLines,
  });
}

class BrailleScanException implements Exception {
  final String message;
  const BrailleScanException(this.message);

  @override
  String toString() => 'BrailleScanException: $message';
}

/// Orkestrator utama pipeline BrailleScan AI:
///
///   gambar dokumen -> preprocessing -> segmentasi grid -> deteksi sel
///   kosong -> inferensi AI/decoder pola -> rekonstruksi kalimat Bahasa
///   Indonesia + metadata kotak baris untuk overlay.
///
/// Ini adalah satu-satunya kelas yang perlu dipanggil dari layer UI/View.
class BrailleScannerBackend {
  final ImageProcessingService _imageService;
  final TFLiteService _tfliteService;
  final BrailleParser _parser;
  final BrailleDecoder _decoder;

  bool _initialized = false;

  BrailleScannerBackend({
    ImageProcessingService? imageService,
    TFLiteService? tfliteService,
    BrailleParser? parser,
    BrailleDecoder? decoder,
  })  : _imageService = imageService ?? ImageProcessingService(),
        _tfliteService = tfliteService ?? TFLiteService(),
        _parser = parser ?? BrailleParser(),
        _decoder = decoder ?? BrailleDecoder();

  /// Memuat model TFLite. WAJIB dipanggil sekali (atau biarkan otomatis
  /// dipanggil oleh [scanDocument] pada pemakaian pertama) sebelum
  /// melakukan pemindaian.
  Future<void> initialize() async {
    if (_initialized) return;
    await _tfliteService.loadModel();
    _initialized = true;
  }

  /// Menjalankan seluruh pipeline dari byte gambar dokumen Braille penuh
  /// hingga menghasilkan teks terjemahan + data overlay.
  Future<BrailleScanResult> scanDocument(Uint8List imageBytes) async {
    if (!_initialized) {
      await initialize();
    }

    // Decode gambar mentah.
    final img.Image? decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw const BrailleScanException(
        'Gagal mendekode gambar. Pastikan format gambar valid (JPG/PNG).',
      );
    }
    final int sourceWidth = decoded.width;
    final int sourceHeight = decoded.height;

    // ---------------------------------------------------------------
    // TAHAP 1 -- Preprocessing & Shadow-Depth Enhancement:
    //  grayscale -> emboss bayangan 30-45 derajat -> kontras -> binarisasi
    //  Otsu agar tonjolan/bayangan titik menjadi HITAM PEKAT vs kertas putih.
    // ---------------------------------------------------------------
    final img.Image enhanced = _imageService.preprocessForShadowDepth(decoded);
    final img.Image binary = _imageService.otsuBinarize(enhanced);

    // ---------------------------------------------------------------
    // TAHAP 2 & 3 -- Segmentation: potong per baris lalu per sel (2x3 titik),
    //  resize tiap sel ke 28x28. Koordinat ikut direkam untuk overlay.
    //  Urutan coba: binary (paling tegas) -> enhanced -> grayscale mentah.
    // ---------------------------------------------------------------
    BrailleSegmentation segmentation = _imageService.segmentDetailed(binary);
    if (segmentation.isEmpty) {
      segmentation = _imageService.segmentDetailed(enhanced);
    }
    if (segmentation.isEmpty) {
      segmentation = _imageService.segmentDetailed(img.grayscale(decoded));
    }

    if (segmentation.isEmpty) {
      throw const BrailleScanException(
        'Tidak ada baris Braille yang terdeteksi pada gambar. '
        'Pastikan foto cukup terang, fokus, dan braille terlihat jelas '
        'di dalam frame.',
      );
    }

    final double scale = segmentation.scale;

    final List<List<BrailleCellPrediction>> predictionsPerLine = [];
    final List<List<String>> tokenLines = [];
    final List<BrailleOverlayLine> overlayLines = <BrailleOverlayLine>[];

    for (final BrailleLineRegion lineRegion in segmentation.lines) {
      final List<BrailleCellPrediction> linePredictions = [];
      final List<String> lineTokens = [];
      final List<BrailleOverlayCell> overlayCells = <BrailleOverlayCell>[];

      for (final BrailleCellRegion cellRegion in lineRegion.cells) {
        final img.Image cell = cellRegion.normalized;

        // ---------------------------------------------------------------
        // TAHAP 4 -- Bedakan Spasi vs Huruf:
        //  decodeCell mengembalikan null bila kotak rata (SPASI, tanpa perlu
        //  AI); '?' bila ada titik tapi polanya tak dikenal.
        // ---------------------------------------------------------------
        final String? decodedLetter = _decoder.decodeCell(cell);

        BrailleCellPrediction prediction;
        String token;

        if (decodedLetter == null) {
          // Sel kosong (spasi).
          prediction = const BrailleCellPrediction(
            label: ' ',
            confidence: 1.0,
            isLowConfidence: false,
          );
          token = ' ';
        } else if (decodedLetter == '?' && _tfliteService.isLoaded) {
          // Pola titik dikenali tapi bukan huruf: coba fallback model AI.
          prediction = await _tfliteService.predictCharacter(cell);
          token = prediction.isLowConfidence ? '?' : prediction.label;
        } else if (decodedLetter == '?') {
          prediction = const BrailleCellPrediction(
            label: '?',
            confidence: 0.1,
            isLowConfidence: true,
          );
          token = '?';
        } else {
          prediction = BrailleCellPrediction(
            label: decodedLetter,
            confidence: 1.0,
            isLowConfidence: false,
          );
          token = decodedLetter;
        }

        linePredictions.add(prediction);
        lineTokens.add(token);

        // Konversi koordinat citra kerja -> citra sumber (÷ scale).
        final double cx = cellRegion.x / scale;
        final double cy = lineRegion.y / scale;
        final double cw = cellRegion.width / scale;
        final double ch = lineRegion.height / scale;

        if (token != ' ') {
          overlayCells.add(
            BrailleOverlayCell(
              x: cx,
              y: cy,
              width: cw,
              height: ch,
              label: token,
              isLowConfidence: prediction.isLowConfidence,
            ),
          );
        }
      }

      predictionsPerLine.add(linePredictions);
      tokenLines.add(lineTokens);

      final String lineText = _parser.parseLine(lineTokens);
      overlayLines.add(
        BrailleOverlayLine(
          x: 0,
          y: lineRegion.y / scale,
          width: segmentation.image.width / scale,
          height: lineRegion.height / scale,
          text: lineText,
          cells: overlayCells,
        ),
      );
    }

    // ---------------------------------------------------------------
    // TAHAP 5 -- Merangkai kalimat: gabungkan huruf per baris, bersihkan
    //  spasi ganda, terapkan aturan Tanda Kapital (^) & Tanda Angka (#).
    // ---------------------------------------------------------------
    final String finalText = _parser.parseDocument(tokenLines);

    return BrailleScanResult(
      text: finalText,
      imageBytes: imageBytes,
      imageWidth: sourceWidth,
      imageHeight: sourceHeight,
      rawPredictionsPerLine: predictionsPerLine,
      overlayLines: overlayLines,
    );
  }

  void dispose() {
    _tfliteService.dispose();
  }
}
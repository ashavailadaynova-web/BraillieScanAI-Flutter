// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pytorch_lite/pytorch_lite.dart';

class BrailleClassifier {
  // Balik warna (negatif) bila true: titik gelap -> terang, latar terang -> gelap.
  static bool invertColor = false;

  static const String _modelPath = 'assets/models/braille_model.ptl';
  static const int inputSize = 28;

  // Normalisasi 0-1 (bukan default ImageNet mean/std) agar cocok dengan
  // standar dataset 28x28. (pixel/255 - mean) / std dengan mean=0, std=1.
  static const List<double> _normMean = [0.0, 0.0, 0.0];
  static const List<double> _normStd = [1.0, 1.0, 1.0];

  ClassificationModel? _pytorchModel;
  List<String> _labels = [];
  bool _isModelLoaded = false;

  bool get isLoaded => _isModelLoaded;

  Future<void> loadModel() async {
    try {
      print("--> [DEBUG] Memuat PyTorch model & labels.txt...");

      // Validasi anti-placeholder: file 0 bytes / bukan TorchScript membuat
      // native gagal memuat (index model = -1) sehingga memicu
      // IndexOutOfBoundsException + NullPointerException di Bitmap.getWidth().
      final ByteData modelBytes = await rootBundle.load(_modelPath);
      print("--> [DEBUG] Ukuran file model: ${modelBytes.lengthInBytes} bytes");
      if (modelBytes.lengthInBytes < 4 * 1024) {
        throw Exception(
          'File model $_modelPath terlalu kecil '
          '(${modelBytes.lengthInBytes} bytes). '
          'Ganti dengan file TorchScript Mobile (.ptl) asli!',
        );
      }

      // pytorch_lite mendukung label .txt (satu label per baris) atau .csv.
      _pytorchModel = await PytorchLite.loadClassificationModel(
        'assets/models/braille_model.ptl',
        28,
        28,
        labelPath: 'assets/models/labels.txt',
      );
      _labels = List<String>.from(_pytorchModel!.labels);

      _isModelLoaded = true;
      print("--> [SUCCESS] PyTorch Model berhasil aktif!");
    } catch (e, stackTrace) {
      _isModelLoaded = false;
      print("--> [ERROR LOAD MODEL]: $e");
      print("--> [STACK TRACE]: $stackTrace");
    }
  }

  /// Pipeline pengolahan citra sebelum masuk model:
  /// grayscale -> tingkatkan kontras -> binarisasi Otsu (titik Braille hitam
  /// tegas, latar putih bersih) -> invert opsional -> resize 28x28 dengan
  /// [img.Interpolation.average].
  ///
  /// Otomatis membalik warna bila [invertColor] (toggle global) aktif.
  img.Image preprocessed(img.Image imageInput, {bool invert = false}) {
    var gray = img.grayscale(imageInput);
    gray = img.adjustColor(gray, contrast: 1.5);
    final img.Image binary = _binarizeOtsu(gray);
    final img.Image finalImage = (invert || invertColor)
        ? img.invert(binary)
        : binary;
    return img.copyResize(
      finalImage,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.average,
    );
  }

  /// Binarisasi ambang otomatis dengan metode Otsu.
  /// Piksel lebih gelap dari ambang -> hitam (0), sisanya -> putih (255).
  img.Image _binarizeOtsu(img.Image gray) {
    final List<int> histogram = List<int>.filled(256, 0);
    int total = 0;
    for (final img.Pixel pixel in gray) {
      final int value = img.getLuminance(pixel).round().clamp(0, 255);
      histogram[value]++;
      total++;
    }
    if (total == 0) return gray;

    double sumAll = 0;
    for (int i = 0; i < 256; i++) {
      sumAll += i * histogram[i];
    }

    double sumBackground = 0;
    int weightBackground = 0;
    double maxVariance = 0;
    int threshold = 127;
    for (int t = 0; t < 256; t++) {
      weightBackground += histogram[t];
      if (weightBackground == 0) continue;
      final int weightForeground = total - weightBackground;
      if (weightForeground == 0) break;
      sumBackground += t * histogram[t];
      final double meanBackground = sumBackground / weightBackground;
      final double meanForeground = (sumAll - sumBackground) / weightForeground;
      final double diff = meanBackground - meanForeground;
      final double variance =
          weightBackground.toDouble() * weightForeground * diff * diff;
      if (variance > maxVariance) {
        maxVariance = variance;
        threshold = t;
      }
    }

    final img.Image output = img.Image(width: gray.width, height: gray.height);
    for (final img.Pixel pixel in gray) {
      final num luminance = img.getLuminance(pixel);
      final int value = luminance < threshold ? 0 : 255;
      output.setPixelRgb(pixel.x, pixel.y, value, value, value);
    }
    return output;
  }

  Future<Map<String, dynamic>> predict(
    img.Image croppedImage, {
    bool invert = false,
  }) async {
    if (!isLoaded) {
      throw Exception(
        'Model belum siap dipakai. Pastikan loadModel() berhasil '
        '(cek assets/models/braille_model.ptl dan labels.txt). '
        'isLoaded=$isLoaded',
      );
    }

    final img.Image resized = preprocessed(croppedImage, invert: invert);
    print(
      '--> [DEBUG] Proses gambar: ${resized.width}x${resized.height} '
      '(grayscale, kontras, Otsu, '
      '${(invert || invertColor) ? 'invert' : 'normal'}, resize)',
    );

    // Diagnostik matriks piksel: cek nilai tengah [14,14] + 3x3 di sekitarnya
    // untuk memastikan citra tidak "flat" (semua sama) sebelum inferensi.
    const int center = inputSize ~/ 2;
    final StringBuffer pixelDump = StringBuffer();
    for (int y = center - 1; y <= center + 1; y++) {
      final List<String> rowValues = [];
      for (int x = center - 1; x <= center + 1; x++) {
        final num lum = img.getLuminance(resized.getPixel(x, y));
        rowValues.add(lum.round().toString().padLeft(3));
      }
      pixelDump.write('[$y] ${rowValues.join(' ')}   ');
    }
    final img.Pixel pixelCenter = resized.getPixel(center, center);
    print(
      '--> [DEBUG] Matriks piksel 3x3 di sekitar [14,14]: ${pixelDump.toString().trim()}',
    );
    print(
      '--> [DEBUG] Piksel tengah [14,14]: r=${pixelCenter.r}, '
      'g=${pixelCenter.g}, b=${pixelCenter.b}, '
      'luminance=${img.getLuminance(pixelCenter).round()}',
    );

    // Simpan gambar 28x28 ke cache agar bisa diperiksa / dipakai sebagai
    // thumbnail hasil olahan. Path: /data/user/0/<pkg>/cache/debug_input_28x28.png
    final Directory tempDir = await getTemporaryDirectory();
    final File debugFile = File('${tempDir.path}/debug_input_28x28.png');
    await debugFile.writeAsBytes(img.encodePng(resized), flush: true);
    print('--> [DEBUG] Gambar 28x28 disimpan: ${debugFile.path}');

    final Uint8List imageBytes = await debugFile.readAsBytes();

    final stopwatch = Stopwatch()..start();
    String prediction;
    List<double?>? probabilities;
    try {
      // Gunakan bytes hasil encode PNG agar native dapat mendekode Bitmap.
      prediction = await _pytorchModel!.getImagePrediction(
        imageBytes,
        mean: _normMean,
        std: _normStd,
      );
      probabilities = await _pytorchModel!.getImagePredictionList(
        imageBytes,
        mean: _normMean,
        std: _normStd,
      );
    } catch (e) {
      print('--> [ERROR INFERENCE]: $e');
      throw Exception('Gagal menjalankan inferensi PyTorch Lite: $e');
    }
    stopwatch.stop();
    final int latencyMs = stopwatch.elapsedMilliseconds;

    final List<double> scores =
        probabilities?.whereType<double>().toList() ?? <double>[];
    double maxScore = 0.0;
    if (scores.isNotEmpty) {
      maxScore = scores.reduce((double a, double b) => a > b ? a : b);

      // Susun indeks kelas berdasarkan skor tertinggi, lalu cetak 5 teratas.
      final List<int> order = List<int>.generate(scores.length, (int i) => i)
        ..sort((int a, int b) => scores[b].compareTo(scores[a]));
      print('--> [DEBUG] Top-5 prediksi:');
      for (int i = 0; i < order.length && i < 5; i++) {
        final int index = order[i];
        final String label = index < _labels.length
            ? _labels[index]
            : 'class_$index';
        print(
          '    ${i + 1}. $label : ${(scores[index] * 100).toStringAsFixed(2)}%',
        );
      }
    }

    print(
      '--> Prediksi: $prediction (${(maxScore * 100).toStringAsFixed(2)}%)',
    );
    print('--> Latensi: $latencyMs ms');

    return {
      'label': prediction,
      'confidence': maxScore,
      'latency_ms': latencyMs,
      'processed_image_path': debugFile.path,
    };
  }

  void dispose() {
    _pytorchModel = null;
    _labels = [];
    _isModelLoaded = false;
  }
}

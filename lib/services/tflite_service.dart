import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Hasil prediksi AI untuk satu sel Braille.
class BrailleCellPrediction {
  /// Label mentah hasil klasifikasi: huruf 'a'-'z', atau '?' jika
  /// confidence terlalu rendah untuk dipercaya.
  final String label;
  final double confidence;
  final bool isLowConfidence;

  const BrailleCellPrediction({
    required this.label,
    required this.confidence,
    required this.isLowConfidence,
  });

  @override
  String toString() => '$label (${(confidence * 100).toStringAsFixed(1)}%)';
}

/// Service untuk memuat model TFLite `braille_model.tflite` dan menjalankan
/// inferensi klasifikasi karakter Braille (huruf a-z) per sel gambar.
///
/// Preprocessing sengaja ADAPTIF terhadap kontrak tensor input model yang
/// dibaca langsung saat load, sehingga service ini bekerja baik untuk model
/// input grayscale `[1, 28, 28, 1]` (sesuai Concept Paper) maupun model
/// input RGB `[1, H, W, 3]` (mis. model yang di-training dengan MobileNetV2).
///
/// Kontrak model saat ini (hasil inspeksi file .tflite):
///   - Input  : float32, shape [1, 224, 224, 3] (RGB, 0.0 - 1.0)
///   - Output : float32, shape [1, 26]          (26 huruf a-z)
///
/// Jika model di-retrain ulang dengan input 28x28 grayscale, service ini
/// otomatis menyesuaikan tanpa perubahan kode.
class TFLiteService {
  static const String modelAssetPath = 'assets/models/braille_model.tflite';
  static const double confidenceThreshold = 0.40;

  /// Urutan label HARUS sama persis dengan urutan kelas output model
  /// (huruf a sampai z). Jika model di-retrain dengan kelas tambahan
  /// (angka '#', kapital '^'), tambahkan sesuai urutan training.
  static const List<String> labels = [
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j',
    'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
    'u', 'v', 'w', 'x', 'y', 'z',
  ];

  Interpreter? _interpreter;
  bool _isLoaded = false;

  // Kontrak tensor model yang dibaca saat load (default asumsi 28x28x1).
  int _inputH = 28;
  int _inputW = 28;
  int _inputC = 1;
  int _outputSize = labels.length;

  bool get isLoaded => _isLoaded;

  /// Memuat model TFLite dari assets. Di platform Web (di mana
  /// tflite_flutter belum didukung penuh) atau jika file model tidak
  /// valid/rusak, service otomatis beralih ke mode mock agar pipeline
  /// tetap bisa diuji end-to-end.
  Future<void> loadModel() async {
    if (kIsWeb) {
      _isLoaded = false;
      // ignore: avoid_print
      print('[TFLiteService] Platform Web terdeteksi -> menggunakan mode mock.');
      return;
    }

    try {
      final InterpreterOptions options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        modelAssetPath,
        options: options,
      );

      final List<int> inputShape = _interpreter!.getInputTensor(0).shape;
      final List<int> outputShape = _interpreter!.getOutputTensor(0).shape;

      if (inputShape.length == 4 && inputShape[0] == 1) {
        _inputH = inputShape[1];
        _inputW = inputShape[2];
        _inputC = inputShape[3];
      }
      if (outputShape.isNotEmpty) {
        _outputSize = outputShape.last;
      }

      // ignore: avoid_print
      print('[TFLiteService] Model dimuat. '
          'Input: $inputShape, Output: $outputShape');
      // ignore: avoid_print
      print('[TFLiteService] -> buffer inferensi '
          '[$_inputH x $_inputW x $_inputC] -> [$labels.length kelas]');

      if (_outputSize != labels.length) {
        // ignore: avoid_print
        print('[TFLiteService] PERINGATAN: jumlah kelas output ($_outputSize) '
            'tidak sama dengan daftar label (${labels.length}). Periksa '
            'kembali daftar [labels] saat model diganti.');
      }

      _isLoaded = true;
    } catch (e) {
      _isLoaded = false;
      _interpreter = null;
      // ignore: avoid_print
      print('[TFLiteService] Gagal memuat model dari "$modelAssetPath": $e');
      // ignore: avoid_print
      print('[TFLiteService] -> Melanjutkan dengan mode MOCK.');
    }
  }

  /// Mengkonversi sebuah sel gambar (ukuran bebas, mis. 28x28 hasil
  /// segmentasi) menjadi Float32List sesuai kontrak tensor input model:
  /// di-resize ke [inputW] x [inputH], grayscale bila input model 1 kanal
  /// atau RGB bila 3 kanal, ternormalisasi 0.0 - 1.0.
  Float32List _cellToInputTensor(img.Image cell) {
    final img.Image resized =
        (cell.width == _inputW && cell.height == _inputH)
            ? cell
            : img.copyResize(
                cell,
                width: _inputW,
                height: _inputH,
                interpolation: img.Interpolation.average,
              );

    final Float32List buffer =
        Float32List(_inputW * _inputH * _inputC);
    int index = 0;

    if (_inputC >= 3) {
      // Model RGB: [1, H, W, 3]
      for (int y = 0; y < _inputH; y++) {
        for (int x = 0; x < _inputW; x++) {
          final img.Pixel pixel = resized.getPixel(x, y);
          buffer[index++] = (pixel.r / 255.0).clamp(0.0, 1.0);
          buffer[index++] = (pixel.g / 255.0).clamp(0.0, 1.0);
          buffer[index++] = (pixel.b / 255.0).clamp(0.0, 1.0);
        }
      }
    } else {
      // Model grayscale: [1, H, W, 1]
      for (int y = 0; y < _inputH; y++) {
        for (int x = 0; x < _inputW; x++) {
          final double luminance = resized.getPixel(x, y).luminance / 255.0;
          buffer[index++] = luminance.clamp(0.0, 1.0);
        }
      }
    }

    return buffer;
  }

  /// Menjalankan inferensi TFLite pada satu sel gambar Braille ([cell]).
  /// Hasilnya berupa label huruf a-z terbanyak (argmax) beserta confidence.
  ///
  /// Jika confidence hasil < [confidenceThreshold], label dikembalikan
  /// sebagai '?' agar tidak ikut membentuk huruf acak.
  ///
  /// Jika model belum berhasil dimuat (mis. di Web, atau file model tidak
  /// valid), fungsi ini otomatis fallback ke [_mockPredict].
  Future<BrailleCellPrediction> predictCharacter(img.Image cell) async {
    if (!_isLoaded || _interpreter == null) {
      return _mockPredict(cell);
    }

    try {
      final Float32List flatInput = _cellToInputTensor(cell);
      final input = flatInput.reshape([1, _inputH, _inputW, _inputC]);
      final output = List<double>.filled(_outputSize, 0.0);

      _interpreter!.run(input, output);

      int bestIndex = 0;
      double bestScore = output[0];
      for (int i = 1; i < output.length; i++) {
        if (output[i] > bestScore) {
          bestScore = output[i];
          bestIndex = i;
        }
      }

      final bool isLow = bestScore < confidenceThreshold;
      final String label = isLow || bestIndex >= labels.length
          ? '?'
          : labels[bestIndex];

      return BrailleCellPrediction(
        label: label,
        confidence: bestScore,
        isLowConfidence: isLow,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[TFLiteService] Error saat inferensi: $e -> fallback ke mock.');
      return _mockPredict(cell);
    }
  }

  /// Fallback sederhana ketika model TFLite tidak tersedia/tidak valid.
  /// PENTING: ini BUKAN pengganti model asli -- hanya menjaga pipeline
  /// tetap berjalan (dengan confidence rendah) untuk masa empty-state.
  BrailleCellPrediction _mockPredict(img.Image cell) {
    double sum = 0;
    int count = 0;
    for (int y = 0; y < cell.height; y++) {
      for (int x = 0; x < cell.width; x++) {
        sum += cell.getPixel(x, y).luminance;
        count++;
      }
    }
    final double avgLuminance = count == 0 ? 255.0 : sum / count;
    final int pseudoIndex = (avgLuminance.toInt() % labels.length)
        .clamp(0, labels.length - 1);

    return BrailleCellPrediction(
      label: labels[pseudoIndex],
      confidence: 0.35, // di bawah threshold -> ditandai '?' oleh caller
      isLowConfidence: true,
    );
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
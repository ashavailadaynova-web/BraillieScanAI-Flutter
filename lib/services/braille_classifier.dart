// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// Mode input tensor:
// - true  (default): kirim nilai piksel MENTAH 0-255 (float32), cocok jika
//   model punya rescaling internal (Keras include_preprocessing=True).
// - false: normalisasi manual pixel / 255.0 -> rentang 0.0-1.0.
bool useRawPixelValues = true;

class BrailleClassifier {
  static const String _modelPath = 'assets/models/braille_model.tflite';
  static const String _labelsPath = 'assets/models/class_names.json';

  Interpreter? _interpreter;
  List<String>? _labels;
  bool _isModelLoaded = false;

  bool get isLoaded =>
      _isModelLoaded && _interpreter != null && (_labels?.isNotEmpty ?? false);

  Future<void> loadModel() async {
    try {
      print("--> Membaca class_names.json...");
      final jsonString = await rootBundle.loadString(_labelsPath);
      final Map<String, dynamic> jsonMap = json.decode(jsonString);
      _labels = List<String>.from(jsonMap['labels']);
      print('--> [DEBUG] Labels berhasil dibaca: ${_labels?.length} kelas');

      print("--> Memuat braille_model.tflite...");
      _interpreter = await Interpreter.fromAsset(_modelPath);
      print('--> [DEBUG] TFLite Interpreter berhasil dimuat!');

      _isModelLoaded = true;
    } catch (e) {
      print('--> [ERROR LOAD MODEL]: $e');
      rethrow;
    }
  }

  Map<String, dynamic> predict(img.Image imageInput) {
    if (!isLoaded) {
      throw Exception(
        'Model belum siap dipakai. Pastikan loadModel() berhasil '
        '(cek assets/models/braille_model.tflite dan class_names.json). '
        'isLoaded=$isLoaded',
      );
    }

    final resized = img.copyResize(imageInput, width: 224, height: 224);

    final rawP10 = resized.getPixel(10, 10);
    final rawP112 = resized.getPixel(112, 112);
    final rawP200 = resized.getPixel(200, 200);
    print("--> Raw pixel [10,10]: r=${rawP10.r}, g=${rawP10.g}, b=${rawP10.b}");
    print(
      "--> Raw pixel [112,112]: r=${rawP112.r}, g=${rawP112.g}, b=${rawP112.b}",
    );
    print(
      "--> Raw pixel [200,200]: r=${rawP200.r}, g=${rawP200.g}, b=${rawP200.b}",
    );

    var input = List.generate(
      1,
      (b) => List.generate(
        224,
        (y) => List.generate(224, (x) {
          final pixel = resized.getPixel(x, y);
          if (useRawPixelValues) {
            // Mode RAW: kirim nilai piksel mentah 0-255 tanpa dibagi apa pun.
            return [pixel.r.toDouble(), pixel.g.toDouble(), pixel.b.toDouble()];
          }
          // Mode NORMALIZED: rescale sederhana pixel / 255.0 -> [0.0, 1.0]
          return [
            pixel.r.toDouble() / 255.0,
            pixel.g.toDouble() / 255.0,
            pixel.b.toDouble() / 255.0,
          ];
        }),
      ),
    );

    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    double sumVal = 0.0;
    int count = 0;
    for (final batch in input) {
      for (final row in batch) {
        for (final pixel in row) {
          for (final value in pixel) {
            if (value < minVal) minVal = value;
            if (value > maxVal) maxVal = value;
            sumVal += value;
            count++;
          }
        }
      }
    }
    final meanVal = count > 0 ? sumVal / count : 0.0;
    print("--> Mode: ${useRawPixelValues ? 'RAW 0-255' : 'NORMALIZED 0-1'}");
    print("--> Input stats -> min: $minVal, max: $maxVal, mean: $meanVal");

    print("--> Input tensor type: ${_interpreter!.getInputTensor(0).type}");
    print("--> Input tensor shape: ${_interpreter!.getInputTensor(0).shape}");
    print("--> Output tensor type: ${_interpreter!.getOutputTensor(0).type}");
    print("--> Output tensor shape: ${_interpreter!.getOutputTensor(0).shape}");

    var output = List.generate(1, (_) => List.filled(26, 0.0));

    final stopwatch = Stopwatch()..start();
    _interpreter!.run(input, output);
    stopwatch.stop();

    final probabilities = output[0].cast<double>();

    print('--> Probabilitas semua kelas:');
    for (int i = 0; i < probabilities.length; i++) {
      print(
        '    ${_labels![i]}: ${(probabilities[i] * 100).toStringAsFixed(2)}%',
      );
    }

    int bestIndex = 0;
    double maxProb = -1.0;
    for (int i = 0; i < probabilities.length; i++) {
      if (probabilities[i] > maxProb) {
        maxProb = probabilities[i];
        bestIndex = i;
      }
    }

    return {
      'label': _labels![bestIndex],
      'confidence': maxProb,
      'latency_ms': stopwatch.elapsedMilliseconds,
    };
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _labels = null;
    _isModelLoaded = false;
  }
}

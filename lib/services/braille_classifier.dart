// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pytorch_lite/pytorch_lite.dart';

/// Informasi satu sel Braille hasil deteksi, lengkap dengan Bounding Box pada citra asli.
class BrailleCellInfo {
  final String label;
  final double confidence;
  final Rect boundingBox;
  final String imagePath;

  BrailleCellInfo({
    required this.label,
    required this.confidence,
    required this.boundingBox,
    required this.imagePath,
  });
}

class BrailleClassifier {
  static bool invertColor = false;
  static int orientationCompensationDegrees = -90;
  static const String _modelPath = 'assets/models/braille_model.ptl';
  static const int inputSize = 28;

  static const List<double> _normMean = [0.0, 0.0, 0.0];
  static const List<double> _normStd = [1.0, 1.0, 1.0];

  ClassificationModel? _pytorchModel;
  List<String> _labels = [];
  bool _isModelLoaded = false;
  bool get isLoaded => _isModelLoaded;

  Future<void> loadModel() async {
    try {
      print("--> [DEBUG] Memuat PyTorch model & labels.txt...");
      final ByteData modelBytes = await rootBundle.load(_modelPath);
      if (modelBytes.lengthInBytes < 4 * 1024) {
        throw Exception(
          'File model $_modelPath terlalu kecil (${modelBytes.lengthInBytes} bytes).',
        );
      }

      _pytorchModel = await PytorchLite.loadClassificationModel(
        _modelPath,
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

  img.Image applyOrientationCompensation(img.Image image) {
    final int angle = orientationCompensationDegrees % 360;
    if (angle == 0) return image;
    return img.copyRotate(image, angle: angle);
  }

  img.Image preprocessed(img.Image imageInput, {bool invert = false}) {
    final img.Image gray = img.grayscale(imageInput);
    final img.Image grayW = _workingScale(gray);
    final img.Image blackHat = _blackHatMorphology(grayW);
    final img.Image binaryHat = _binarizeOtsu(img.invert(blackHat));
    List<_Blob> blobs = _connectedBlackComponents(binaryHat);
    img.Image cell;
    if (blobs.isNotEmpty) {
      cell = _gridToCanvas(_blobsToGrid(blobs));
    } else {
      final img.Image binaryGray = _binarizeOtsu(grayW);
      blobs = _connectedBlackComponents(binaryGray);
      if (blobs.isNotEmpty) {
        cell = _gridToCanvas(_blobsToGrid(blobs));
      } else {
        cell = binaryGray;
      }
    }

    final img.Image resized = img.copyResize(
      cell,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.average,
    );
    return (invert || invertColor) ? img.invert(resized) : resized;
  }

  img.Image _workingScale(img.Image gray) {
    const int targetH = 210;
    if (gray.height == targetH) return gray;
    final int w = math.max(1, (gray.width * targetH / gray.height).round());
    return img.copyResize(
      gray,
      width: w,
      height: targetH,
      interpolation: img.Interpolation.average,
    );
  }

  List<(int, int)> _ellipseKernelList(int radius) {
    final List<(int, int)> kernel = <(int, int)>[];
    final int rr = radius * radius;
    for (int dy = -radius; dy <= radius; dy++) {
      for (int dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy * dy <= rr) kernel.add((dx, dy));
      }
    }
    return kernel;
  }

  img.Image _blackHatMorphology(img.Image gray) {
    final int radius = (gray.height * 0.05).round().clamp(3, 12);
    final List<(int, int)> kernel = _ellipseKernelList(radius);
    final img.Image closed = _morphErode(_morphDilate(gray, kernel), kernel);
    final img.Image out = img.Image(width: gray.width, height: gray.height);
    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final int closedLum = img.getLuminance(closed.getPixel(x, y)).round();
        final int grayLum = img.getLuminance(gray.getPixel(x, y)).round();
        final int diff = math.min(255, math.max(0, closedLum - grayLum));
        out.setPixelRgb(x, y, diff, diff, diff);
      }
    }
    return out;
  }

  img.Image _morphDilate(img.Image src, List<(int, int)> kernel) {
    final img.Image out = img.Image(width: src.width, height: src.height);
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        int best = 0;
        for (final (int dx, int dy) in kernel) {
          final int nx = x + dx;
          final int ny = y + dy;
          if (nx >= 0 && nx < src.width && ny >= 0 && ny < src.height) {
            final int v = img.getLuminance(src.getPixel(nx, ny)).round();
            if (v > best) best = v;
          }
        }
        out.setPixelRgb(x, y, best, best, best);
      }
    }
    return out;
  }

  img.Image _morphErode(img.Image src, List<(int, int)> kernel) {
    final img.Image out = img.Image(width: src.width, height: src.height);
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        int best = 255;
        for (final (int dx, int dy) in kernel) {
          final int nx = x + dx;
          final int ny = y + dy;
          if (nx >= 0 && nx < src.width && ny >= 0 && ny < src.height) {
            final int v = img.getLuminance(src.getPixel(nx, ny)).round();
            if (v < best) best = v;
          }
        }
        out.setPixelRgb(x, y, best, best, best);
      }
    }
    return out;
  }

  List<_Blob> _connectedBlackComponents(img.Image binary) {
    const List<(int, int)> neighbors = <(int, int)>[
      (0, 1),
      (0, -1),
      (1, 0),
      (-1, 0),
    ];
    const int minArea = 2; // Dilonggarkan agar titik tipis terangkat
    final int w = binary.width;
    final int h = binary.height;
    final Uint8List visited = Uint8List(w * h);
    final List<_Blob> blobs = <_Blob>[];
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int idx = y * w + x;
        if (visited[idx] != 0) continue;
        if (img.getLuminance(binary.getPixel(x, y)) >= 128) continue;
        final List<int> stack = <int>[idx];
        visited[idx] = 1;
        int area = 0;
        double sumX = 0, sumY = 0;
        int minX = x, maxX = x, minY = y, maxY = y;
        while (stack.isNotEmpty) {
          final int cur = stack.removeLast();
          final int cx = cur % w;
          final int cy = cur ~/ w;
          area++;
          sumX += cx;
          sumY += cy;
          if (cx < minX) minX = cx;
          if (cx > maxX) maxX = cx;
          if (cy < minY) minY = cy;
          if (cy > maxY) maxY = cy;
          for (final (int dx, int dy) in neighbors) {
            final int nx = cx + dx;
            final int ny = cy + dy;
            if (nx >= 0 && nx < w && ny >= 0 && ny < h) {
              final int nIdx = ny * w + nx;
              if (visited[nIdx] == 0 &&
                  img.getLuminance(binary.getPixel(nx, ny)) < 128) {
                visited[nIdx] = 1;
                stack.add(nIdx);
              }
            }
          }
        }
        if (area >= minArea) {
          blobs.add(
            _Blob(
              area: area,
              cx: sumX / area,
              cy: sumY / area,
              minX: minX,
              maxX: maxX,
              minY: minY,
              maxY: maxY,
            ),
          );
        }
      }
    }
    blobs.sort((a, b) => b.area.compareTo(a.area));
    return blobs;
  }

  List<List<bool>> _blobsToGrid(List<_Blob> blobs) {
    final List<List<bool>> grid = List<List<bool>>.generate(
      3,
      (_) => List<bool>.filled(2, false),
    );
    if (blobs.isEmpty) return grid;
    final List<_Blob> kept = _filterBlobs(blobs);
    if (kept.isEmpty) return grid;

    // KASUS KHUSUS 1 TITIK (misalnya huruf A):
    // Jika hanya ada 1 titik dalam sel, Braille standar selalu menempatkannya di Dot 1 (kiri atas).
    if (kept.length == 1) {
      grid[0][0] = true;
      return grid;
    }

    double minX = kept.first.minX.toDouble();
    double maxX = kept.first.maxX.toDouble();
    double minY = kept.first.minY.toDouble();
    double maxY = kept.first.maxY.toDouble();
    final List<double> widths = <double>[];
    final List<double> heights = <double>[];
    for (final _Blob b in kept) {
      if (b.minX < minX) minX = b.minX.toDouble();
      if (b.maxX > maxX) maxX = b.maxX.toDouble();
      if (b.minY < minY) minY = b.minY.toDouble();
      if (b.maxY > maxY) maxY = b.maxY.toDouble();
      widths.add((b.maxX - b.minX).toDouble());
      heights.add((b.maxY - b.minY).toDouble());
    }
    final List<double> sortedW = widths..sort();
    final List<double> sortedH = heights..sort();
    final double dotWidth = sortedW[sortedW.length ~/ 2];
    final double dotHeight = sortedH[sortedH.length ~/ 2];

    final double spanX = maxX - minX;
    final double spanY = maxY - minY;
    final bool twoColumns = spanX >= 16;
    final double midX = (minX + maxX) / 2.0;

    final double rowPitch = spanY > 10
        ? math.max(1.0, spanY / (spanY > 35 ? 2.0 : 1.0))
        : (twoColumns
            ? math.max(1.0, spanX - dotWidth)
            : math.max(1.0, dotHeight * 1.6));

    final double maxRowY = minY + 2.0 * rowPitch + 1.2 * dotHeight;
    final double minRowY = minY - 1.2 * dotHeight;

    for (final _Blob b in kept) {
      if (b.cy < minRowY || b.cy > maxRowY) continue;
      final int col = twoColumns ? (b.cx < midX ? 0 : 1) : 0;
      int row = ((b.cy - minY) / rowPitch).round();
      if (row < 0) row = 0;
      if (row > 2) row = 2;
      grid[row][col] = true;
    }
    return grid;
  }

  List<_Blob> _filterBlobs(List<_Blob> blobs) {
    if (blobs.length <= 1) return blobs;
    final List<double> areas =
        blobs.map((b) => b.area.toDouble()).toList()..sort();
    final List<double> heights =
        blobs.map((b) => (b.maxY - b.minY).toDouble()).toList()..sort();
    final double medArea = areas[areas.length ~/ 2];
    final double medHeight = math.max(1.0, heights[heights.length ~/ 2]);
    final List<_Blob> kept = <_Blob>[];
    for (final _Blob b in blobs) {
      final double w = (b.maxX - b.minX).toDouble();
      final double h = (b.maxY - b.minY).toDouble();
      final double shortSide = math.min(w, h);
      final double longSide = math.max(w, h);
      if (b.area < 2 || b.area < 0.15 * medArea) continue;
      if (b.area > 6.0 * medArea) continue;
      if (shortSide < 0.3 * longSide) continue;
      if (longSide > 3.0 * medHeight) continue;
      kept.add(b);
    }
    return kept.isEmpty ? blobs : kept;
  }

  double _median(List<double> values) {
    if (values.isEmpty) return 0.0;
    final List<double> sorted = List<double>.from(values)..sort();
    final int mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  List<_Blob> _detectBlobs(img.Image imageInput) {
    final img.Image gray = img.grayscale(imageInput);
    final img.Image grayW = _workingScale(gray);
    final img.Image blackHat = _blackHatMorphology(grayW);
    final img.Image binaryHat = _binarizeOtsu(img.invert(blackHat));
    List<_Blob> blobs = _connectedBlackComponents(binaryHat);
    if (blobs.isEmpty) {
      blobs = _connectedBlackComponents(_binarizeOtsu(grayW));
    }
    return _filterBlobs(blobs);
  }

  List<List<_Blob>> _clusterCells(List<_Blob> blobs) {
    if (blobs.isEmpty) return <List<_Blob>>[];

    final List<_Blob> byX = List<_Blob>.from(blobs)
      ..sort((a, b) => a.cx.compareTo(b.cx));
    final double dotWidth = _median(
      byX.map((b) => (b.maxX - b.minX).toDouble()).toList(),
    );
    final double colTol = math.max(3.0, dotWidth * 0.6);
    final List<List<_Blob>> columns = <List<_Blob>>[];
    List<_Blob> current = <_Blob>[byX.first];
    for (int i = 1; i < byX.length; i++) {
      final _Blob b = byX[i];
      final double colCx =
          current.fold<double>(0, (s, e) => s + e.cx) / current.length;
      if ((b.cx - colCx).abs() <= colTol) {
        current.add(b);
      } else {
        columns.add(current);
        current = <_Blob>[b];
      }
    }
    columns.add(current);

    final List<double> rowGaps = <double>[];
    for (final List<_Blob> col in columns) {
      final List<double> ys = col.map((b) => b.cy).toList()..sort();
      for (int i = 1; i < ys.length; i++) {
        final double gap = ys[i] - ys[i - 1];
        if (gap > 1.0) rowGaps.add(gap);
      }
    }
    final double pitch = rowGaps.isEmpty
        ? math.max(1.0, dotWidth * 1.6)
        : _median(rowGaps);

    final double cellWidthLimit = math.max(1.0, pitch * 1.2);
    double columnCenter(List<_Blob> col) =>
        col.fold<double>(0, (s, e) => s + e.cx) / col.length;

    final List<List<_Blob>> cells = <List<_Blob>>[];
    List<_Blob> cellBlobs = <_Blob>[...columns.first];
    int colsInCell = 1;
    double prevCx = columnCenter(columns.first);
    for (int i = 1; i < columns.length; i++) {
      final double cx = columnCenter(columns[i]);
      final double gapX = cx - prevCx;
      if (colsInCell < 2 && gapX <= cellWidthLimit) {
        cellBlobs.addAll(columns[i]);
        colsInCell++;
      } else {
        cells.add(cellBlobs);
        cellBlobs = <_Blob>[...columns[i]];
        colsInCell = 1;
      }
      prevCx = cx;
    }
    cells.add(cellBlobs);

    double minXOf(List<_Blob> cell) =>
        cell.map((b) => b.minX.toDouble()).reduce(math.min);
    cells.sort((a, b) => minXOf(a).compareTo(minXOf(b)));
    return cells;
  }

  img.Image _gridToCanvas(List<List<bool>> grid) {
    const int cw = 140;
    const int ch = 210;
    const int r = 10;
    const List<int> colX = <int>[44, 96];
    const List<int> rowY = <int>[53, 105, 158];
    final img.Image canvas = img.Image(width: cw, height: ch);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    for (int rIdx = 0; rIdx < 3; rIdx++) {
      for (int cIdx = 0; cIdx < 2; cIdx++) {
        if (grid[rIdx][cIdx]) {
          _fillDisc(canvas, colX[cIdx], rowY[rIdx], r);
        }
      }
    }
    return canvas;
  }

  void _fillDisc(img.Image canvas, int cx, int cy, int r) {
    for (int dy = -r; dy <= r; dy++) {
      for (int dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy <= r * r) {
          final int x = cx + dx;
          final int y = cy + dy;
          if (x >= 0 && y >= 0 && x < canvas.width && y < canvas.height) {
            canvas.setPixelRgb(x, y, 0, 0, 0);
          }
        }
      }
    }
  }

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
      final int value = luminance <= threshold ? 0 : 255;
      output.setPixelRgb(pixel.x, pixel.y, value, value, value);
    }
    return output;
  }

  List<double> _softmax(List<double> logits) {
    if (logits.isEmpty) return <double>[];
    final double maxLogit =
        logits.reduce((double a, double b) => a > b ? a : b);
    final List<double> exps = logits
        .map((double v) => math.exp(v - maxLogit))
        .toList(growable: false);
    final double sum = exps.reduce((double a, double b) => a + b);
    if (sum <= 0 || !sum.isFinite) {
      return List<double>.filled(logits.length, 1.0 / logits.length);
    }
    return exps.map((double e) => e / sum).toList(growable: false);
  }

  Future<Map<String, dynamic>> predict(
    img.Image croppedImage, {
    bool invert = false,
    bool cleanPattern = false,
    String fileSuffix = '',
  }) async {
    if (!isLoaded) {
      throw Exception('Model belum siap dipakai.');
    }
    final img.Image resized = cleanPattern
        ? img.copyResize(
            croppedImage,
            width: inputSize,
            height: inputSize,
            interpolation: img.Interpolation.average,
          )
        : preprocessed(croppedImage, invert: invert);

    final img.Image oriented = applyOrientationCompensation(resized);

    final Directory tempDir = await getTemporaryDirectory();
    final String suffix = fileSuffix.isNotEmpty ? '_$fileSuffix' : '';
    final File debugFile = File('${tempDir.path}/debug_input_28x28$suffix.png');
    await debugFile.writeAsBytes(img.encodePng(oriented), flush: true);

    final img.Image pluginView = img.copyRotate(oriented, angle: 90);
    final File pluginFile =
        File('${tempDir.path}/debug_plugin_view_28x28$suffix.png');
    await pluginFile.writeAsBytes(img.encodePng(pluginView), flush: true);

    final Uint8List imageBytes = await debugFile.readAsBytes();
    final stopwatch = Stopwatch()..start();
    String prediction;
    List<double?>? probabilities;
    try {
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
      throw Exception('Gagal menjalankan inferensi PyTorch Lite: $e');
    }
    stopwatch.stop();
    final int latencyMs = stopwatch.elapsedMilliseconds;
    final List<double> predictionList =
        probabilities?.whereType<double>().toList() ?? <double>[];

    final List<double> probs = _softmax(predictionList);
    final int maxIndex = argmax(probs);
    final double maxScore = probs.isEmpty ? 0.0 : probs[maxIndex];
    final String detectedChar =
        (predictionList.isNotEmpty && maxIndex < _labels.length)
            ? _labels[maxIndex].toUpperCase()
            : prediction.toUpperCase();

    return {
      'label': detectedChar,
      'confidence': maxScore,
      'latency_ms': latencyMs,
      'processed_image_path': pluginFile.path,
    };
  }

  /// Memindai baris/kalimat Braille, mengelompokkan per sel, 
  /// mendeteksi spasi antar kata, dan menghitung koordinat Bounding Box presisi.
  Future<Map<String, dynamic>> predictDocument(img.Image lineImage) async {
    if (!isLoaded) {
      throw Exception('Model belum siap dipakai.');
    }

    final img.Image gray = img.grayscale(lineImage);
    final img.Image grayW = _workingScale(gray);
    final img.Image blackHat = _blackHatMorphology(grayW);
    final img.Image binaryHat = _binarizeOtsu(img.invert(blackHat));
    List<_Blob> blobs = _connectedBlackComponents(binaryHat);
    if (blobs.isEmpty) {
      blobs = _connectedBlackComponents(_binarizeOtsu(grayW));
    }
    blobs = _filterBlobs(blobs);

    print('--> [LINE] Titik terdeteksi: ${blobs.length}');
    if (blobs.isEmpty) {
      return {
        'text': '',
        'cells': <BrailleCellInfo>[],
        'latency_ms': 0,
      };
    }

    final double scaleX = lineImage.width / grayW.width;
    final double scaleY = lineImage.height / grayW.height;

    final List<List<_Blob>> cells = _clusterCells(blobs);
    print('--> [LINE] Sel Braille terdeteksi: ${cells.length}');

    final List<BrailleCellInfo> allCellInfos = [];
    final StringBuffer sentenceBuffer = StringBuffer();
    final stopwatch = Stopwatch()..start();

    // Estimasi batas spasi antar kata
    final List<double> cellSpans = cells.map((cell) {
      final double minX = cell.map((b) => b.minX.toDouble()).reduce(math.min);
      final double maxX = cell.map((b) => b.maxX.toDouble()).reduce(math.max);
      return maxX - minX;
    }).toList()..sort();
    final double avgCellWidth =
        cellSpans.isNotEmpty ? cellSpans[cellSpans.length ~/ 2] : 20.0;
    final double spaceThreshold = math.max(25.0, avgCellWidth * 1.8);

    double lastCellMaxX = -1.0;

    for (int i = 0; i < cells.length; i++) {
      final List<_Blob> cellBlobs = cells[i];

      final double cellMinX =
          cellBlobs.map((b) => b.minX.toDouble()).reduce(math.min);
      final double cellMaxX =
          cellBlobs.map((b) => b.maxX.toDouble()).reduce(math.max);
      final double cellMinY =
          cellBlobs.map((b) => b.minY.toDouble()).reduce(math.min);
      final double cellMaxY =
          cellBlobs.map((b) => b.maxY.toDouble()).reduce(math.max);

      // Sisipkan SPASI bila jeda horizontal antar sel lebar
      if (lastCellMaxX > 0 && (cellMinX - lastCellMaxX) > spaceThreshold) {
        sentenceBuffer.write(' ');
      }
      lastCellMaxX = cellMaxX;

      final img.Image cellCanvas = _gridToCanvas(_blobsToGrid(cellBlobs));
      final Map<String, dynamic> result = await predict(
        cellCanvas,
        cleanPattern: true,
        fileSuffix: 'line_c$i',
      );

      final String label = (result['label'] ?? '?').toString();
      sentenceBuffer.write(label);

      // Konversi ke koordinat resolusi asli
      final double origMinX = cellMinX * scaleX;
      final double origMaxX = cellMaxX * scaleX;
      final double origMinY = cellMinY * scaleY;
      final double origMaxY = cellMaxY * scaleY;

      final double boxW =
          math.max(origMaxX - origMinX + 16, (origMaxY - origMinY) * 0.7);
      final double boxH = origMaxY - origMinY + 20;
      final double boxCx = (origMinX + origMaxX) / 2.0;
      final double boxCy = (origMinY + origMaxY) / 2.0;

      allCellInfos.add(
        BrailleCellInfo(
          label: label,
          confidence: (result['confidence'] as num?)?.toDouble() ?? 0.0,
          boundingBox: Rect.fromCenter(
            center: Offset(boxCx, boxCy),
            width: boxW,
            height: boxH,
          ),
          imagePath: (result['processed_image_path'] as String?) ?? '',
        ),
      );
    }

    stopwatch.stop();
    final String finalSentence = sentenceBuffer.toString();
    print('--> [LINE] Kalimat Terbentuk: "$finalSentence"');

    return {
      'text': finalSentence,
      'cells': allCellInfos,
      'latency_ms': stopwatch.elapsedMilliseconds,
    };
  }

  @visibleForTesting
  static int argmax(List<double> values) {
    if (values.isEmpty) return 0;
    return values.indexOf(values.reduce((a, b) => a > b ? a : b));
  }

  void dispose() {
    _pytorchModel = null;
    _labels = [];
    _isModelLoaded = false;
  }
}

class _Blob {
  final int area;
  final double cx;
  final double cy;
  final int minX;
  final int maxX;
  final int minY;
  final int maxY;
  const _Blob({
    required this.area,
    required this.cx,
    required this.cy,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });
}
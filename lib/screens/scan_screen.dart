// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../services/braille_classifier.dart';

class ScanScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const ScanScreen({super.key, required this.cameras});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _cameraController;
  final BrailleClassifier _classifier = BrailleClassifier();
  bool _isCameraReady = false;
  bool _isProcessing = false;
  bool _isModelLoaded = false;
  bool _invert = BrailleClassifier.invertColor;
  String _errorMessage = '';
  Offset? _tapFocusPoint;
  Timer? _focusTimer;

  // Ukuran kotak viewfinder (harus sama dengan Container viewfinder di build).
  static const double _viewfinderSize = 220.0;
  // Key untuk mengukur area preview yang dirender (untuk memetakan crop).
  final GlobalKey _previewAreaKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _setupCameraAndModel();
  }

  Future<void> _setupCameraAndModel() async {
    await _setupCamera();
    await _setupModel();
  }

  Future<void> _setupCamera() async {
    if (widget.cameras.isEmpty) {
      if (mounted) {
        setState(
          () => _errorMessage = 'Tidak ada sensor kamera yang terdeteksi.',
        );
      }
      return;
    }

    _cameraController = CameraController(
      widget.cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _cameraController!.initialize();
      final controller = _cameraController!;
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (e) {
        print("--> [WARN] Gagal set exposure auto: $e");
      }
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (e) {
        print("--> [WARN] Gagal set focus auto: $e");
      }
      print("--> [DEBUG] Kamera berhasil diinisialisasi");
      if (mounted) {
        setState(() => _isCameraReady = true);
      }
    } catch (e) {
      print("--> [ERROR] Gagal mengakses kamera: $e");
      if (mounted) {
        setState(() => _errorMessage = 'Gagal mengakses kamera: $e');
      }
    }
  }

  Future<void> _setupModel() async {
    try {
      await _classifier.loadModel();
      print("--> [DEBUG] Model PyTorch Lite berhasil dimuat");
    } catch (e) {
      print("--> [ERROR] Model PyTorch Lite gagal dimuat: $e");
    } finally {
      if (mounted) {
        setState(() => _isModelLoaded = _classifier.isLoaded);
      }
    }
  }

  void _toggleInvert() {
    BrailleClassifier.invertColor = !BrailleClassifier.invertColor;
    setState(() => _invert = BrailleClassifier.invertColor);
    print('--> Invert B/W: ${BrailleClassifier.invertColor}');
  }

  void _handlePreviewTap(TapDownDetails details) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    final screenSize = MediaQuery.sizeOf(context);
    final focusPoint = Offset(
      details.localPosition.dx / screenSize.width,
      details.localPosition.dy / screenSize.height,
    );
    controller.setFocusMode(FocusMode.auto);
    controller.setFocusPoint(focusPoint);

    _focusTimer?.cancel();
    setState(() => _tapFocusPoint = details.localPosition);
    _focusTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() => _tapFocusPoint = null);
      }
    });
  }

  Future<void> _captureAndScan() async {
    if (!_isCameraReady || _cameraController == null || _isProcessing) {
      return;
    }

    if (!_classifier.isLoaded) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Model AI belum siap. Memuat ulang..."),
            backgroundColor: Colors.orange,
          ),
        );
      }
      await _classifier.loadModel();
      if (mounted) {
        setState(() => _isModelLoaded = _classifier.isLoaded);
      }
      return;
    }

    setState(() => _isProcessing = true);

    final Size previewAreaSize = _previewAreaSize();

    try {
      await _cameraController!.setFocusMode(FocusMode.auto);
      await Future.delayed(const Duration(milliseconds: 500));
      final XFile photo = await _cameraController!.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      final img.Image? originalImage = img.decodeImage(bytes);

      if (originalImage == null) {
        throw Exception('Gagal decode gambar');
      }

      final img.Image croppedImage = _cropToViewfinder(
        originalImage,
        previewAreaSize,
      );
      print(
        "--> Crop viewfinder: ${croppedImage.width}x${croppedImage.height}, "
        "original: ${originalImage.width}x${originalImage.height}",
      );

      await _saveImageToTemp(croppedImage, 'braille_crop');
      final result = await _classifier.predict(croppedImage, invert: _invert);

      _showResultDialog(result, _fileFromResult(result));
    } catch (e, stackTrace) {
      print('--> [ERROR INFERENCE SCAN]: $e');
      print('--> [STACK TRACE]: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scan gagal: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Size _previewAreaSize() {
    final RenderBox? box =
        _previewAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0) {
      return box.size;
    }
    return MediaQuery.sizeOf(context);
  }

  /// Potong citra tepat pada area kotak viewfinder (bukan 1/3 tengah).
  /// Preview memakai BoxFit.cover, sehingga skala = max(area/img). Sisi crop
  /// dalam piksel citra asli = ukuran viewfinder / skala, diambil dari tengah.
  img.Image _cropToViewfinder(img.Image original, Size areaSize) {
    final double scale = math.max(
      areaSize.width / original.width,
      areaSize.height / original.height,
    );
    final int maxSide = math.min(original.width, original.height);
    final int cropSize = (_viewfinderSize / scale).round().clamp(
      BrailleClassifier.inputSize,
      maxSide,
    );
    final int startX = (original.width - cropSize) ~/ 2;
    final int startY = (original.height - cropSize) ~/ 2;

    return img.copyCrop(
      original,
      x: startX,
      y: startY,
      width: cropSize,
      height: cropSize,
    );
  }

  File? _fileFromResult(Map<String, dynamic> result) {
    final Object? path = result['processed_image_path'];
    if (path is String && path.isNotEmpty) {
      final File file = File(path);
      if (file.existsSync()) return file;
    }
    return null;
  }

  Future<File> _saveImageToTemp(img.Image image, String prefix) async {
    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    final jpgBytes = img.encodeJpg(image);
    await file.writeAsBytes(jpgBytes, flush: true);
    print('--> $prefix tersimpan di: ${file.path}');
    return file;
  }

  void _showResultDialog(
    Map<String, dynamic> result,
    File? modelImageFile, {
    String? groundTruth,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Hasil Prediksi AI',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (groundTruth != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Ground truth: $groundTruth',
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (modelImageFile != null) ...[
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.deepPurple,
                                width: 2,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                modelImageFile,
                                width: 120,
                                height: 120,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Input model 28x28',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                      const SizedBox(width: 20),
                    ],
                    Text(
                      (result['label'] ?? '-').toString().toUpperCase(),
                      style: const TextStyle(
                        fontSize: 72,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Akurasi: ${((result['confidence'] ?? 0.0) * 100).toStringAsFixed(2)}%',
                  style: const TextStyle(fontSize: 16),
                ),
                Text(
                  'Latensi Inferensi: ${result['latency_ms'] ?? 0} ms',
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check),
                  label: const Text('Tutup'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _classifier.dispose();
    super.dispose();
  }

  Future<void> _testWithSample() async {
    try {
      if (!_classifier.isLoaded) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Model belum siap. Tunggu hingga status "AI Siap".',
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      const samplePath = 'assets/samples/sample_f.png';
      final byteData = await rootBundle.load(samplePath);
      final bytes = byteData.buffer.asUint8List();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Gagal decode sample_f.png');

      final result = await _classifier.predict(decoded, invert: _invert);
      _showResultDialog(result, _fileFromResult(result), groundTruth: 'f');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Test sample gagal: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Text(
              _errorMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red, fontSize: 16),
            ),
          ),
        ),
      );
    }

    if (!_isCameraReady || _cameraController == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Menyiapkan kamera & model AI...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('BrailleScan AI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.science),
            tooltip: 'Test dengan Sample',
            onPressed: _testWithSample,
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            key: _previewAreaKey,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: _handlePreviewTap,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cameraController!.value.previewSize?.height ?? 1080,
                  height: _cameraController!.value.previewSize?.width ?? 1920,
                  child: CameraPreview(_cameraController!),
                ),
              ),
            ),
          ),
          if (_tapFocusPoint != null)
            Positioned(
              left: _tapFocusPoint!.dx - 28,
              top: _tapFocusPoint!.dy - 28,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          Container(
            width: _viewfinderSize,
            height: _viewfinderSize,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.yellowAccent, width: 3),
              borderRadius: BorderRadius.circular(16),
              color: Colors.black.withValues(alpha: 0.15),
            ),
          ),
          Positioned(
            top: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Arahkan cahaya miring agar titik berbayang',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
          Positioned(
            top: 68,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: _isModelLoaded
                    ? Colors.green.withValues(alpha: 0.85)
                    : Colors.orange.shade800,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isModelLoaded ? Icons.check_circle : Icons.hourglass_top,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isModelLoaded ? 'AI Siap' : 'Memuat Model AI...',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            top: 100,
            child: Material(
              color: _invert ? Colors.blueGrey.shade800 : Colors.black87,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _toggleInvert,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.invert_colors,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _invert ? 'Invert: ON' : 'Invert B/W',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 36,
            child: FloatingActionButton.large(
              onPressed: _isProcessing ? null : _captureAndScan,
              child: _isProcessing
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Icon(Icons.camera_alt, size: 36),
            ),
          ),
        ],
      ),
    );
  }
}

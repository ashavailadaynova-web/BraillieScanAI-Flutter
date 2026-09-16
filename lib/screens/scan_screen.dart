// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

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
  String _errorMessage = '';
  Offset? _tapFocusPoint;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _setupCameraAndModel();
  }

  Future<void> _setupCameraAndModel() async {
    _setupCamera();
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
      print("--> [DEBUG] Model TFLite berhasil dimuat");
    } catch (e) {
      print("--> [ERROR] Model TFLite gagal dimuat: $e");
    } finally {
      if (mounted) {
        setState(() => _isModelLoaded = _classifier.isLoaded);
      }
    }
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
    if (!_isCameraReady ||
        _cameraController == null ||
        !_isModelLoaded ||
        _isProcessing) {
      return;
    }

    setState(() => _isProcessing = true);

    try {
      await _cameraController!.setFocusMode(FocusMode.auto);
      await Future.delayed(const Duration(milliseconds: 500));
      final XFile photo = await _cameraController!.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      final img.Image? originalImage = img.decodeImage(bytes);

      if (originalImage == null) {
        throw Exception('Gagal decode gambar');
      }

      final int cropSize =
          (originalImage.width < originalImage.height
              ? originalImage.width
              : originalImage.height) ~/
          3;
      final int startX = (originalImage.width - cropSize) ~/ 2;
      final int startY = (originalImage.height - cropSize) ~/ 2;

      final img.Image croppedImage = img.copyCrop(
        originalImage,
        x: startX,
        y: startY,
        width: cropSize,
        height: cropSize,
      );
      print(
        "--> Crop size: ${croppedImage.width}x${croppedImage.height}, "
        "original: ${originalImage.width}x${originalImage.height}",
      );

      final img.Image modelImage = img.copyResize(
        croppedImage,
        width: 224,
        height: 224,
      );
      print("--> Setelah resize ke model: 224x224");

      final modelImageFile = await _saveImageToTemp(
        modelImage,
        'braille_model_input',
      );
      await _saveImageToTemp(croppedImage, 'braille_crop');
      final result = _classifier.predict(modelImage);

      _showResultDialog(result, modelImageFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Proses pemindaian gagal: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
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
                if (modelImageFile != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      modelImageFile,
                      width: 180,
                      height: 180,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  (result['label'] ?? '-').toString().toUpperCase(),
                  style: const TextStyle(
                    fontSize: 72,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple,
                  ),
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
      const samplePath = 'assets/samples/sample_f.png';
      final byteData = await rootBundle.load(samplePath);
      final bytes = byteData.buffer.asUint8List();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Gagal decode sample_f.png');

      final tempDir = await getTemporaryDirectory();
      final sampleFile = File('${tempDir.path}/sample_f.png');
      await sampleFile.writeAsBytes(bytes, flush: true);

      final result = _classifier.predict(decoded);
      _showResultDialog(result, sampleFile, groundTruth: 'f');
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
            width: 220,
            height: 220,
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
            bottom: 36,
            child: FloatingActionButton.large(
              onPressed: _isProcessing || !_isModelLoaded
                  ? null
                  : _captureAndScan,
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

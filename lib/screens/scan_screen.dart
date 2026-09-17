// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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
  int _orientation = BrailleClassifier.orientationCompensationDegrees;
  String _errorMessage = '';
  String scannedSentence = '';
  Offset? _tapFocusPoint;
  Timer? _focusTimer;

  // Viewfinder persegi panjang horizontal khusus memindai baris Braille
  static const double _viewfinderWidth = 340.0;
  static const double _viewfinderHeight = 120.0;

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
  }

  void _cycleOrientation() {
    const List<int> options = <int>[-90, 0, 90, 180];
    final int next =
        options[(options.indexOf(_orientation) + 1) % options.length];
    BrailleClassifier.orientationCompensationDegrees = next;
    setState(() => _orientation = next);
  }

  void _appendScan(String chars) {
    if (!mounted) return;
    setState(() => scannedSentence += chars);
  }

  void _backspaceScan() {
    if (scannedSentence.isEmpty || !mounted) return;
    setState(
      () => scannedSentence = scannedSentence.substring(
        0,
        scannedSentence.length - 1,
      ),
    );
  }

  void _clearScan() {
    if (!mounted) return;
    setState(() => scannedSentence = '');
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
      await Future.delayed(const Duration(milliseconds: 300));
      final XFile photo = await _cameraController!.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      final img.Image? originalImage = img.decodeImage(bytes);
      if (originalImage == null) {
        throw Exception('Gagal decode gambar');
      }

      // Potong tepat pada kotak panjang viewfinder
      final img.Image scanImage = _cropToViewfinder(
        originalImage,
        previewAreaSize,
      );

      final tempDir = await getTemporaryDirectory();
      final File savedCroppedFile = File(
        '${tempDir.path}/crop_line_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await savedCroppedFile.writeAsBytes(img.encodeJpg(scanImage), flush: true);

      // Jalankan deteksi baris & Bounding Box
      final result = await _classifier.predictDocument(scanImage);
      _showDocumentResultDialog(result, savedCroppedFile, scanImage);
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

  img.Image _cropToViewfinder(img.Image original, Size previewAreaSize) {
    final double scale = math.max(
      original.width / previewAreaSize.width,
      original.height / previewAreaSize.height,
    );

    final double left = (previewAreaSize.width - _viewfinderWidth) / 2.0;
    final double top = (previewAreaSize.height - _viewfinderHeight) / 2.0;

    final int cropX = (left * scale).round().clamp(0, original.width - 1);
    final int cropY = (top * scale).round().clamp(0, original.height - 1);
    final int cropW =
        (_viewfinderWidth * scale).round().clamp(1, original.width - cropX);
    final int cropH =
        (_viewfinderHeight * scale).round().clamp(1, original.height - cropY);

    return img.copyCrop(
      original,
      x: cropX,
      y: cropY,
      width: cropW,
      height: cropH,
    );
  }

  void _showDocumentResultDialog(
    Map<String, dynamic> result,
    File croppedImageFile,
    img.Image croppedImage,
  ) {
    imageCache.clear();
    imageCache.clearLiveImages();
    final String fullText = (result['text'] ?? '').toString();
    final List<BrailleCellInfo> cells =
        (result['cells'] as List<BrailleCellInfo>?) ?? [];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: ListView(
                controller: scrollController,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Hasil Pemindaian Baris',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),

                  // Foto Kotak Hasil Scan dengan Bounding Box Hijau & Bulatan Sudut
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      color: Colors.black,
                      child: AspectRatio(
                        aspectRatio: croppedImage.width / croppedImage.height,
                        child: CustomPaint(
                          foregroundPainter: BoundingBoxPainter(
                            cells: cells,
                            originalImageSize: Size(
                              croppedImage.width.toDouble(),
                              croppedImage.height.toDouble(),
                            ),
                          ),
                          child: Image.file(
                            croppedImageFile,
                            key: UniqueKey(),
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Teks Terbaca
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Teks Braille Terbaca:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          fullText.isEmpty ? '(Tidak ada huruf terdeteksi)' : fullText,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepPurple,
                            letterSpacing: 2.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Galeri Tiap Sel
                  if (cells.isNotEmpty) ...[
                    const Text(
                      'Inspeksi Sel:',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 95,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: cells.length,
                        itemBuilder: (context, index) {
                          final cell = cells[index];
                          final file = File(cell.imagePath);
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.greenAccent.shade700,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: file.existsSync()
                                      ? Image.file(
                                          file,
                                          key: UniqueKey(),
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.contain,
                                        )
                                      : const SizedBox(
                                          width: 50,
                                          height: 50,
                                          child: Icon(Icons.broken_image, size: 20),
                                        ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  cell.label,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.deepPurple,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () {
                      if (fullText.isNotEmpty) {
                        _appendScan(
                          scannedSentence.isEmpty ? fullText : ' $fullText',
                        );
                      }
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Tambahkan ke Kalimat Utama'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Tutup'),
                  ),
                ],
              ),
            );
          },
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

          // Viewfinder Persegi Panjang untuk Baris Braille
          Container(
            width: _viewfinderWidth,
            height: _viewfinderHeight,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.yellowAccent, width: 2.5),
              borderRadius: BorderRadius.circular(12),
              color: Colors.black.withValues(alpha: 0.1),
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
                'Arahkan baris teks Braille ke dalam kotak kuning',
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
            left: 16,
            top: 140,
            child: Material(
              color: _orientation == -90
                  ? Colors.blueGrey.shade800
                  : Colors.black87,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _cycleOrientation,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.rotate_90_degrees_ccw,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Rotasi: $_orientation°',
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
          Positioned(
            left: 12,
            right: 12,
            bottom: 150,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(16),
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Kalimat:',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: scannedSentence.isEmpty
                              ? null
                              : _backspaceScan,
                          icon: const Icon(Icons.backspace_outlined),
                          color: Colors.white,
                          iconSize: 20,
                          tooltip: 'Hapus huruf terakhir',
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(6),
                        ),
                        IconButton(
                          onPressed: scannedSentence.isEmpty
                              ? null
                              : _clearScan,
                          icon: const Icon(Icons.clear_all),
                          color: Colors.white,
                          iconSize: 20,
                          tooltip: 'Bersihkan kalimat',
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(6),
                        ),
                      ],
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 96),
                      child: SingleChildScrollView(
                        child: Text(
                          scannedSentence.isEmpty
                              ? '(kosong - arahkan baris kata ke kotak kuning)'
                              : scannedSentence,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<BrailleCellInfo> cells;
  final Size originalImageSize;

  BoundingBoxPainter({
    required this.cells,
    required this.originalImageSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (originalImageSize.width == 0 || originalImageSize.height == 0) return;

    final double scaleX = size.width / originalImageSize.width;
    final double scaleY = size.height / originalImageSize.height;

    final Paint boxPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final Paint cornerDotPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..style = PaintingStyle.fill;

    const double cornerRadius = 2.5;

    final textStyle = const TextStyle(
      color: Color(0xFF00E676),
      fontSize: 11,
      fontWeight: FontWeight.bold,
    );

    for (final cell in cells) {
      final rect = Rect.fromLTRB(
        cell.boundingBox.left * scaleX,
        cell.boundingBox.top * scaleY,
        cell.boundingBox.right * scaleX,
        cell.boundingBox.bottom * scaleY,
      );

      // 1. Gambar Garis Kotak Sel
      canvas.drawRect(rect, boxPaint);

      // 2. Gambar 4 Bulatan Titik di Sudut Kotak
      canvas.drawCircle(rect.topLeft, cornerRadius, cornerDotPaint);
      canvas.drawCircle(rect.topRight, cornerRadius, cornerDotPaint);
      canvas.drawCircle(rect.bottomLeft, cornerRadius, cornerDotPaint);
      canvas.drawCircle(rect.bottomRight, cornerRadius, cornerDotPaint);

      // 3. Tampilkan Karakter Huruf Kecil Tepat di Atas Kotak Sel
      if (cell.label.isNotEmpty && cell.label != '?' && cell.label != ' ') {
        final textSpan = TextSpan(
          text: cell.label.toLowerCase(),
          style: textStyle,
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        )..layout();

        final double textX = rect.left + (rect.width - textPainter.width) / 2.0;
        final double textY = rect.top - textPainter.height - 1;

        textPainter.paint(canvas, Offset(textX, math.max(0, textY)));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../services/braille_classifier.dart';

class ScanScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const ScanScreen({super.key, required this.cameras});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _controller;
  final BrailleClassifier _classifier = BrailleClassifier();
  final ImagePicker _picker = ImagePicker();
  bool _isProcessing = false;
  bool _isTorchOn = false;

  @override
  void initState() {
    super.initState();
    _initCameraAndModel();
  }

  Future<void> _initCameraAndModel() async {
    await _classifier.loadModel();

    if (widget.cameras.isEmpty) return;

    _controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.max,
      enableAudio: false,
    );

    try {
      await _controller!.initialize();

      // Kompensasi pencahayaan negatif (-0.5 EV) agar kontur bayangan bintik tidak overexposure
      final minExp = await _controller!.getMinExposureOffset();
      final maxExp = await _controller!.getMaxExposureOffset();
      final targetExp = (-0.5).clamp(minExp, maxExp);
      await _controller!.setExposureOffset(targetExp);

      if (mounted) setState(() {});
    } catch (e) {
      print('Gagal inisialisasi kamera: $e');
    }
  }

  Future<void> _toggleTorch() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      _isTorchOn = !_isTorchOn;
      await _controller!.setFlashMode(
        _isTorchOn ? FlashMode.torch : FlashMode.off,
      );
      setState(() {});
    } catch (e) {
      print('Gagal menyalakan torch: $e');
    }
  }

  // 1. Alur Jepret dari Kamera Langsung
  Future<void> _captureAndCrop() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isProcessing) {
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final XFile rawPhoto = await _controller!.takePicture();
      await _openCropperAndProcess(rawPhoto.path);
    } catch (e) {
      print('Terjadi kesalahan saat memotret: $e');
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // 2. Alur Ambil Foto dari Galeri
  Future<void> _pickAndCropFromGallery() async {
    if (_isProcessing) return;

    try {
      final XFile? pickedFile =
          await _picker.pickImage(source: ImageSource.gallery);
      if (pickedFile == null) return;

      setState(() => _isProcessing = true);
      await _openCropperAndProcess(pickedFile.path);
    } catch (e) {
      print('Terjadi kesalahan saat memilih galeri: $e');
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // 3. Modul Pemotong Interaktif (Crop) & Eksekusi TFLite
  Future<void> _openCropperAndProcess(String sourcePath) async {
    try {
      final CroppedFile? croppedFile = await ImageCropper().cropImage(
        sourcePath: sourcePath,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Pilih Baris Teks Braille',
            toolbarColor: const Color(0xFF6750A4),
            toolbarWidgetColor: Colors.white,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
          IOSUiSettings(
            title: 'Pilih Baris Teks Braille',
          ),
        ],
      );

      if (croppedFile == null) {
        if (mounted) setState(() => _isProcessing = false);
        return;
      }

      final bytes = await File(croppedFile.path).readAsBytes();
      final img.Image? croppedImage = img.decodeImage(bytes);

      if (croppedImage == null) throw Exception('Gagal mendekode gambar crop.');

      final result = await _classifier.predictDocument(croppedImage);

      if (mounted) {
        _showResultModal(result, croppedImage);
      }
    } catch (e) {
      print('Terjadi kesalahan saat pemrosesan crop: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Widget _buildAnnotatedImagePreview(
      img.Image croppedImage, List<BrailleCellInfo> cells) {
    final Uint8List jpgBytes = Uint8List.fromList(img.encodeJpg(croppedImage));

    return Container(
      width: double.infinity,
      height: 160,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: croppedImage.width.toDouble(),
            height: croppedImage.height.toDouble(),
            child: Stack(
              children: [
                Image.memory(jpgBytes),
                CustomPaint(
                  size: Size(
                    croppedImage.width.toDouble(),
                    croppedImage.height.toDouble(),
                  ),
                  painter: _BrailleBoxesPainter(cells),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showResultModal(Map<String, dynamic> result, img.Image croppedImage) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final String recognizedText = (result['text'] ?? '').toString();
        final List<BrailleCellInfo> cells =
            (result['cells'] as List<BrailleCellInfo>?) ?? [];

        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (_, scrollController) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: ListView(
                controller: scrollController,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Center(
                    child: Text(
                      'Hasil Pemindaian Baris',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 14),

                  _buildAnnotatedImagePreview(croppedImage, cells),
                  const SizedBox(height: 14),

                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Teks Braille Terbaca:',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          recognizedText.isEmpty
                              ? '(Tidak terdeteksi)'
                              : recognizedText,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF5B458E),
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (cells.isNotEmpty) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Inspeksi Sel (${cells.length} sel):',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 90,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: cells.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, idx) {
                          final cell = cells[idx];
                          return Container(
                            width: 65,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.green,
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (cell.imagePath.isNotEmpty &&
                                    File(cell.imagePath).existsSync())
                                  Image.file(
                                    File(cell.imagePath),
                                    width: 36,
                                    height: 36,
                                    fit: BoxFit.contain,
                                  )
                                else
                                  const Icon(Icons.crop_square, size: 30),
                                const SizedBox(height: 4),
                                Text(
                                  cell.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: Color(0xFF5B458E),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),

                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6750A4),
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      '+ Tambahkan ke Kalimat Utama',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Tutup', style: TextStyle(color: Colors.grey)),
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
    _controller?.dispose();
    _classifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: CameraPreview(_controller!)),

          Positioned(
            top: 45,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                const Text(
                  'BrailleScan AI',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _isTorchOn ? Icons.flash_on : Icons.flash_off,
                    color: _isTorchOn ? Colors.amberAccent : Colors.white,
                  ),
                  tooltip: 'Pencahayaan Senter',
                  onPressed: _toggleTorch,
                ),
              ],
            ),
          ),

          Positioned(
            bottom: 140,
            left: 20,
            right: 20,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Jepret atau pilih gambar, lalu potong 1-2 baris',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),

          // Kontrol Bar Bawah (Galeri di kiri, Shutter Kamera di tengah)
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Tombol Import Galeri
                  IconButton(
                    icon: const Icon(Icons.photo_library,
                        color: Colors.white, size: 36),
                    tooltip: 'Pilih dari Galeri',
                    onPressed: _isProcessing ? null : _pickAndCropFromGallery,
                  ),

                  // Tombol Shutter Kamera
                  _isProcessing
                      ? const CircularProgressIndicator(color: Colors.white)
                      : GestureDetector(
                          onTap: _captureAndCrop,
                          child: Container(
                            width: 78,
                            height: 78,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                            ),
                            child: Container(
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),

                  // Penyeimbang layout
                  const SizedBox(width: 48),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrailleBoxesPainter extends CustomPainter {
  final List<BrailleCellInfo> cells;

  _BrailleBoxesPainter(this.cells);

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = const Color(0xFF00FF66)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    for (final cell in cells) {
      canvas.drawRect(cell.boundingBox, boxPaint);

      final textSpan = TextSpan(
        text: cell.label,
        style: const TextStyle(
          color: Color(0xFF00FF66),
          fontSize: 16,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black87,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final double posX = cell.boundingBox.left +
          (cell.boundingBox.width - textPainter.width) / 2;
      final double posY = (cell.boundingBox.top - textPainter.height - 2) < 0
          ? cell.boundingBox.top + 2
          : cell.boundingBox.top - textPainter.height - 2;

      textPainter.paint(canvas, Offset(posX, posY));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
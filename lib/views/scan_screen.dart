import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart' as perm;
import 'package:sensors_plus/sensors_plus.dart';

import '../services/braille_scanner_backend.dart';
import 'result_screen.dart';

/// Layar Scan: kamera live fullscreen dengan flash aktif, panduan
/// kemiringan (Shadow-Depth Guidance 30-45 derajat via accelerometer),
/// tombol shutter, dan import dari galeri.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final BrailleScannerBackend _backend = BrailleScannerBackend();
  final ImagePicker _imagePicker = ImagePicker();

  CameraController? _camera;
  bool _cameraReady = false;
  bool _flashOn = true;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  double _tiltAngleDeg = 0.0;
  bool _isProcessing = false;

  /// Menghitung sudut kemiringan ponsel dari sumbu horizontal (0 = datar,
  /// 90 = tegak) berdasarkan vektor gravitasi accelerometer.
  static double _angleFromHorizontal(double x, double y, double z) {
    final double g = math.sqrt(x * x + y * y + z * z);
    if (g == 0) return 0;
    final double cosTheta = (z.abs() / g).clamp(0.0, 1.0);
    return math.acos(cosTheta) * 180.0 / math.pi;
  }

  @override
  void initState() {
    super.initState();
    _backend.initialize();
    _listenAccelerometer();
    _initCamera();
  }

  /// Meminta permission kamera lalu menginisialisasi kamera belakang
  /// dengan mode flash (torch) aktif.
  Future<void> _initCamera() async {
    try {
      final bool granted = await _requestCameraPermission();
      if (!granted) {
        if (mounted) {
          _showMessage(
            'Izin kamera ditolak. Izinkan akses kamera untuk memindai.',
          );
        }
        return;
      }

      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          _showMessage('Tidak ditemukan kamera pada perangkat ini.');
        }
        return;
      }

      final CameraDescription backCamera = cameras.firstWhere(
        (CameraDescription c) =>
            c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final CameraController controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _camera = controller;

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      if (_flashOn) {
        try {
          await controller.setFlashMode(FlashMode.torch);
        } catch (_) {
          // Beberapa perangkat tidak mendukung mode torch terus-menerus.
        }
      }

      setState(() => _cameraReady = true);
    } catch (e) {
      if (mounted) {
        _showMessage('Gagal menyalakan kamera: $e');
      }
    }
  }

  Future<bool> _requestCameraPermission() async {
    final perm.PermissionStatus status = await perm.Permission.camera.request();
    return status.isGranted;
  }

  void _listenAccelerometer() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (!mounted) return;
      final double angle = _angleFromHorizontal(event.x, event.y, event.z);
      setState(() => _tiltAngleDeg = angle);
    }, onError: (Object _) {
      // Sensor tidak tersedia -- panduan kemiringan dilewati, tidak fatal.
    });
  }

  Future<void> _toggleFlash() async {
    final CameraController? controller = _camera;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      if (_flashOn) {
        await controller.setFlashMode(FlashMode.off);
      } else {
        await controller.setFlashMode(FlashMode.torch);
      }
      if (mounted) setState(() => _flashOn = !_flashOn);
    } catch (_) {
      // Mode flash tidak didukung perangkat.
    }
  }

  Future<void> _capture() async {
    if (_isProcessing) return;
    final CameraController? controller = _camera;
    if (controller == null || !_cameraReady || !controller.value.isInitialized) {
      _showMessage('Kamera belum siap.');
      return;
    }

    setState(() => _isProcessing = true);
    try {
      final XFile shot = await controller.takePicture();
      final Uint8List bytes = await shot.readAsBytes();
      await _processAndOpenResult(bytes);
    } catch (e) {
      if (mounted) _showMessage('Gagal mengambil gambar: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    if (_isProcessing) return;
    try {
      final XFile? picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2240,
        maxHeight: 2240,
        imageQuality: 92,
      );
      if (picked == null) return;

      setState(() => _isProcessing = true);
      final Uint8List bytes = await picked.readAsBytes();
      await _processAndOpenResult(bytes);
    } catch (e) {
      if (mounted) _showMessage('Gagal membaca gambar: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processAndOpenResult(Uint8List bytes) async {
    try {
      await _backend.initialize();
      final BrailleScanResult result = await _backend.scanDocument(bytes);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ResultScreen(result: result),
        ),
      );
    } catch (e) {
      if (mounted) _showMessage('Scan gagal: ${e.toString()}');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _backend.dispose();
    _camera?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  bool get _isGoodAngle => _tiltAngleDeg >= 30.0 && _tiltAngleDeg <= 45.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _buildCameraPreview(),
          _buildGuidanceFrame(),
          _buildTopBar(),
          _buildBottomControls(),
          if (_isProcessing) _buildLoadingOverlay(),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final CameraController? controller = _camera;
    if (controller == null || !_cameraReady || !controller.value.isInitialized) {
      return const Center(
        child: Text(
          'Menyalakan kamera...',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
      );
    }

    final Size? previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return const Center(
        child: Text(
          'Menyalakan kamera...',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
      );
    }

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: previewSize.height,
          height: previewSize.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  /// Frame viewfinder yang menjadi HIJAU ketika sudut kemiringan ponsel
  /// berada di rentang ideal 30-45 derajat, dan kuning/merah di luar itu.
  Widget _buildGuidanceFrame() {
    final bool good = _isGoodAngle;
    final Color color = good ? Colors.greenAccent : Colors.amber;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 28, vertical: 140),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color, width: 4),
          color: Colors.black.withValues(alpha: 0.25),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(good ? Icons.check_circle : Icons.screen_rotation,
                color: color, size: 32),
            const SizedBox(height: 8),
            Text(
              'Kemiringan: ${_tiltAngleDeg.toStringAsFixed(0)}°',
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              good
                  ? 'Sudut ideal! Arahkan ke dokumen lalu tekan shutter.'
                  : 'Miringkan ponsel 30°-45° agar bayangan bintik Braille '
                      'tampak jelas.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const Expanded(
              child: Text(
                'Scan Braille',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            IconButton(
              icon: Icon(
                _flashOn ? Icons.flash_on : Icons.flash_off,
                color: _flashOn ? Colors.yellowAccent : Colors.white,
              ),
              tooltip: 'Flash',
              onPressed: _toggleFlash,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Positioned(
                left: 20,
                child: TextButton.icon(
                  onPressed: _isProcessing ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined,
                      color: Colors.white),
                  label: const Text(
                    'Import Galeri',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
              _buildShutterButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShutterButton() {
    return GestureDetector(
      onTap: _isProcessing ? null : _capture,
      child: Container(
        width: 76,
        height: 76,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isProcessing ? Colors.grey : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Memproses dokumen Braille...',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
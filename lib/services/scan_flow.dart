import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../views/result_screen.dart';
import 'braille_scanner_backend.dart';

/// Membungkus alur pemindaian Braille yang bisa dipicu dari mana saja
/// (Home "Upload Gambar" maupun layar Scan "Import Galeri").
///
/// Bertanggung jawab untuk: memilih gambar dari galeri (jika [pickFromGallery]),
/// menjalankan pipeline AI, lalu menampilkan [ResultScreen].
class ScanFlow {
  final BrailleScannerBackend _backend = BrailleScannerBackend();
  final ImagePicker _imagePicker = ImagePicker();

  bool _initialized = false;

  /// Memilih gambar dari galeri lalu memproses dan menampilkan hasil.
  ///
  /// Mengembalikan `true` bila ada gambar yang dipilih & diproses,
  /// `false` bila pengguna membatalkan pilihan.
  Future<bool> pickAndProcessFromGallery(BuildContext context) async {
    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2240,
      maxHeight: 2240,
      imageQuality: 92,
    );
    if (picked == null) return false;

    final Uint8List bytes = await picked.readAsBytes();
    if (!context.mounted) return false;
    await processBytes(context, bytes);
    return true;
  }

  /// Menjalankan pipeline AI pada [bytes] lalu menampilkan [ResultScreen].
  Future<void> processBytes(BuildContext context, Uint8List bytes) async {
    await _ensureInitialized();
    try {
      final BrailleScanResult result = await _backend.scanDocument(bytes);
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ResultScreen(result: result),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan gagal: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _backend.initialize();
    _initialized = true;
  }

  void dispose() {
    _backend.dispose();
  }
}

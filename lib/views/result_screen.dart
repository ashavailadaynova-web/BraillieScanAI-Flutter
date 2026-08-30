import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/braille_scanner_backend.dart';
import '../services/database_service.dart';
import '../services/pdf_service.dart';

/// Layar Hasil: menampilkan gambar sumber Braille dengan kotak-kotak hasil
/// terjemahan di atasnya (ala Google Lens), plus teks lengkap yang dapat
/// diedit, disalin, diekspor ke PDF, atau disimpan ke riwayat.
class ResultScreen extends StatefulWidget {
  final BrailleScanResult result;

  const ResultScreen({super.key, required this.result});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  late final TextEditingController _controller;
  final DatabaseService _database = DatabaseService.instance;
  final PdfExportService _pdfService = PdfExportService();

  bool _exportingPdf = false;

  BrailleScanResult get _result => widget.result;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _result.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copyText() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    _showMessage('Teks disalin ke clipboard.');
  }

  Future<void> _saveToHistory() async {
    try {
      final int id = await _database.addRecord(text: _controller.text);
      if (id == -1) {
        _showMessage('Teks kosong, tidak disimpan.');
        return;
      }
      _showMessage('Tersimpan ke riwayat scan.');
    } catch (e) {
      _showMessage('Gagal menyimpan ke riwayat: $e');
    }
  }

  Future<void> _exportPdf() async {
    if (_exportingPdf) return;
    setState(() => _exportingPdf = true);
    try {
      final String stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final String path = await _pdfService.exportPdf(
        title: 'Hasil Scan Braille',
        content: _controller.text,
        fileName: 'braille_scan_$stamp.pdf',
      );
      if (mounted) {
        _showMessage('PDF berhasil dibuat: $path');
      }
    } catch (e) {
      if (mounted) _showMessage('Gagal ekspor PDF: $e');
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hasil Terjemahan')),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 5,
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: _result.imageBytes == null
                  ? const Center(
                      child: Text(
                        'Tidak ada gambar untuk ditampilkan',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : _buildOverlayViewer(),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 16, height: 1.4),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Hasil terjemahan Braille...',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _copyText,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Salin'),
                ),
                OutlinedButton.icon(
                  onPressed: _exportingPdf ? null : _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(_exportingPdf ? 'Memproses...' : 'Ekspor PDF'),
                ),
                OutlinedButton.icon(
                  onPressed: _saveToHistory,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Simpan ke Riwayat'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Viewer gambar sumber dengan overlay kotak-kotak hasil terjemahan,
  /// mendukung pinch-zoom & geser.
  Widget _buildOverlayViewer() {
    final Uint8List bytes = _result.imageBytes!;
    final double imgW = _result.imageWidth.toDouble();
    final double imgH = _result.imageHeight.toDouble();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double scale =
            math.min(constraints.maxWidth / imgW, constraints.maxHeight / imgH);
        final double dispW = imgW * scale;
        final double dispH = imgH * scale;

        return Stack(
          children: <Widget>[
            // Petunjuk geser/zoom.
            const Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Text(
                  'Geser & pinch-zoom untuk melihat hasil pada gambar',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
            Center(
              child: InteractiveViewer(
                minScale: 0.4,
                maxScale: 8,
                clipBehavior: Clip.none,
                child: SizedBox(
                  width: dispW,
                  height: dispH,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      Positioned.fill(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.fill,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                        ),
                      ),
                      for (final BrailleOverlayLine line
                          in _result.overlayLines) ...[
                        _buildLineBox(line, scale),
                        for (final BrailleOverlayCell cell in line.cells)
                          _buildCellLabel(cell, scale),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Kotak baris (biru samar) menandai posisi satu baris Braille.
  Widget _buildLineBox(BrailleOverlayLine line, double scale) {
    final double top = line.y * scale;
    final double left = line.x * scale;
    final double width = line.width * scale;
    final double height = line.height * scale;
    if (height <= 1) return const SizedBox.shrink();

    final double labelTop = math.max(0, top - 22);
    // Bar teks hasil baris tepat DI ATAS garis braille.
    final Widget labelBar = Positioned(
      left: left,
      top: labelTop,
      child: Container(
        constraints: BoxConstraints(maxWidth: width),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.indigo.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          line.text.trim().isEmpty ? '(baris kosong)' : line.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    final Widget lineBox = Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.blueAccent, width: 1.5),
            borderRadius: BorderRadius.circular(4),
            color: Colors.blue.withValues(alpha: 0.10),
          ),
        ),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[lineBox, labelBar],
    );
  }

  /// Label huruf per sel: kotak kecil berwarna + huruf hasil.
  Widget _buildCellLabel(BrailleOverlayCell cell, double scale) {
    final Color color = cell.isLowConfidence || cell.label == '?'
        ? Colors.amber
        : Colors.greenAccent;

    return Positioned(
      left: cell.x * scale,
      top: cell.y * scale,
      width: cell.width * scale,
      height: cell.height * scale,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 1.2),
            borderRadius: BorderRadius.circular(3),
            color: Colors.black.withValues(alpha: 0.12),
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              margin: const EdgeInsets.all(2),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                cell.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
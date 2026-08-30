import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Service untuk mengekspor hasil terjemahan teks Braille ke format PDF
/// formal yang siap dipakai sebagai dokumen tugas evaluasi siswa.
class PdfExportService {
  /// Membangun byte PDF berisi [title] dan [content] kalimat hasil scan.
  Future<Uint8List> buildPdfBytes({
    required String title,
    required String content,
  }) async {
    final pw.Document doc = pw.Document(title: title);
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(48),
        build: (pw.Context context) => <pw.Widget>[
          pw.Text(
            title,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 24),
          pw.Text(
            content,
            textAlign: pw.TextAlign.justify,
            style: const pw.TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
    return doc.save();
  }

  /// Menyimpan PDF ke folder dokumen aplikasi. Mengembalikan path file.
  Future<String> savePdfToFile({
    required String title,
    required String content,
    required String fileName,
  }) async {
    final Uint8List bytes = await buildPdfBytes(title: title, content: content);
    final Directory dir = await getApplicationDocumentsDirectory();
    final String filePath = p.join(dir.path, fileName);
    final File file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    return filePath;
  }

  /// Ekspor PDF: membuat file di folder dokumen aplikasi, lalu membuka
  /// dialog cetak/bagikan (print/share) milik platform.
  Future<String> exportPdf({
    required String title,
    required String content,
    String? fileName,
  }) async {
    final String resolvedFileName = fileName ??
        'braille_scan_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final String path = await savePdfToFile(
      title: title,
      content: content,
      fileName: resolvedFileName,
    );
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => File(path).readAsBytes(),
      name: resolvedFileName,
    );
    return path;
  }
}
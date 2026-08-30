/// Parser berbasis aturan yang menyusun deretan token karakter hasil
/// klasifikasi AI menjadi teks Bahasa Indonesia yang rapi, termasuk
/// penanganan prefix tanda angka dan tanda kapital ala Braille standar.
///
/// CATATAN: `braille_model.tflite` yang dipakai saat ini hanya punya 26
/// kelas keluaran (huruf a-z) -- belum ada kelas khusus untuk simbol
/// "tanda angka" atau "tanda kapital" Braille. Artinya token '#' dan '^'
/// di bawah ini TIDAK akan pernah muncul dari `TFLiteService` selama Anda
/// memakai model 26-kelas ini. Logika di kelas ini tetap disediakan agar
/// parser langsung siap pakai begitu Anda retrain model dengan kelas
/// tambahan tsb (atau menambah mekanisme deteksi terpisah).
class BrailleParser {
  /// Token yang menandakan simbol "tanda angka" Braille -- huruf a-j
  /// berikutnya harus dibaca sebagai digit 1-0.
  static const String numberPrefixToken = '#';

  /// Token yang menandakan simbol "tanda kapital" Braille -- huruf
  /// berikutnya harus dijadikan huruf besar.
  static const String capitalPrefixToken = '^';

  static const Map<String, String> _numberMap = {
    'a': '1',
    'b': '2',
    'c': '3',
    'd': '4',
    'e': '5',
    'f': '6',
    'g': '7',
    'h': '8',
    'i': '9',
    'j': '0',
  };

  /// Menyusun seluruh dokumen dari daftar baris token mentah menjadi satu
  /// String kalimat penuh, dengan tiap baris dipisahkan newline (`\n`).
  ///
  /// [rawLinesTokens] adalah List per baris, tiap baris berisi List token
  /// mentah (huruf 'a'-'z', ' ' untuk spasi, '#' prefix angka, '^' prefix
  /// kapital, atau '?' untuk sel dengan confidence rendah).
  String parseDocument(List<List<String>> rawLinesTokens) {
    final List<String> lines = rawLinesTokens.map(parseLine).toList();
    return lines.join('\n');
  }

  /// Mem-parsing satu baris token mentah menjadi satu baris teks bersih,
  /// menerapkan aturan prefix angka & kapital, lalu merapikan spasi.
  String parseLine(List<String> tokens) {
    final StringBuffer buffer = StringBuffer();

    bool numberModeActive = false;
    bool capitalModeActive = false;

    for (final String token in tokens) {
      if (token == numberPrefixToken) {
        numberModeActive = true;
        continue;
      }

      if (token == capitalPrefixToken) {
        capitalModeActive = true;
        continue;
      }

      if (token == ' ' || token.isEmpty) {
        buffer.write(' ');
        // Mode angka Braille standar berakhir begitu bertemu spasi.
        numberModeActive = false;
        capitalModeActive = false;
        continue;
      }

      // Sel dengan confidence rendah ('?') tetap diloloskan apa adanya
      // agar pengguna tahu di mana perlu koreksi manual, tanpa memaksa
      // jadi huruf acak.
      String outputChar = token;

      if (numberModeActive) {
        outputChar = _numberMap[token.toLowerCase()] ?? token;
        // Mode angka tetap aktif untuk digit berikutnya sampai spasi.
      } else if (capitalModeActive) {
        outputChar = token.toUpperCase();
        // Tanda kapital standar hanya berlaku untuk satu huruf berikutnya.
        capitalModeActive = false;
      }

      buffer.write(outputChar);
    }

    return _cleanupSpacing(buffer.toString());
  }

  /// Menghapus spasi ganda/berlebih (`regex: \s+` -> 1 spasi) dan
  /// merapikan whitespace di awal/akhir baris.
  String _cleanupSpacing(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

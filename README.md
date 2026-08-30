# BrailleScan AI — Core Backend & Image Processing Pipeline

Implementasi backend murni (tanpa UI kompleks) untuk pipeline:

```
gambar dokumen Braille
    -> preprocessing (shadow enhancement + grayscale)
    -> document grid slicing (baris -> sel)
    -> deteksi sel kosong (spasi)
    -> inferensi AI (TFLite)
    -> rekonstruksi kalimat (rule-based parser)
    -> String kalimat akhir
```

## Struktur

```
lib/
  main.dart                        # test runner sederhana (tanpa desain UI)
  services/
    braille_scanner_backend.dart   # orkestrator utama pipeline
    image_processing_service.dart  # shadow enhancement, empty-cell, grid slicing
    tflite_service.dart            # load model + inferensi per sel
    braille_parser.dart            # rule-based Indonesian Braille parser
assets/
  models/braille_model.tflite      # model Anda
test_assets/                       # taruh gambar uji di sini
```

## PENTING — kontrak model yang sebenarnya dipakai

Saya inspeksi langsung file `braille_model.tflite` yang Anda upload (bukan
asumsi dari spek awal), dan kontraknya ternyata:

| | |
|---|---|
| Input  | `float32`, shape `[1, 224, 224, 3]` (RGB, dinormalisasi 0.0–1.0) |
| Output | `float32`, shape `[1, 26]` (26 huruf a–z saja) |

Kode sudah disesuaikan ke kontrak ini (bukan `[1,28,28,1]` grayscale seperti
di spek awal). Konsekuensinya:

- **Tidak ada token angka (`#`) atau kapital (`^`)** dari model saat ini —
  hanya 26 huruf. Logika penanganannya tetap ada di `braille_parser.dart`
  supaya siap pakai kalau Anda retrain model dengan kelas tambahan nanti.
- Jika model Anda di-training dengan preprocessing berbeda (misalnya skala
  `[-1, 1]` ala `preprocess_input` MobileNetV2, bukan `[0, 1]`), sesuaikan
  fungsi `_cellToInputTensor()` di `tflite_service.dart`.
- Segmentasi grid (`image_processing_service.dart`) memotong sel di ukuran
  kerja internal 128×128 untuk deteksi sel kosong; `tflite_service.dart`
  yang melakukan resize final ke 224×224×3 sebelum inferensi. Jadi kedua
  service ini tetap independen satu sama lain.

## Cara menjalankan (WAJIB dibaca)

Sandbox tempat saya menulis kode ini **tidak punya Flutter SDK** dan **tidak
bisa akses pub.dev**, jadi saya tidak bisa menjalankan `flutter create`,
`flutter pub get`, atau build APK di sini. Yang saya berikan adalah source
code lengkap (services + main.dart + pubspec + model). Langkah di komputer
Anda:

1. **Buat skeleton proyek Flutter baru** (supaya folder `android/`, `ios/`,
   dll ter-generate dengan versi Gradle/toolchain yang cocok dengan mesin
   Anda):
   ```bash
   flutter create braille_scan_ai_new
   ```

2. **Salin isi folder ini** (`lib/`, `assets/`, `test_assets/`) ke dalam
   proyek yang baru dibuat, timpa `lib/main.dart` dan `pubspec.yaml` yang
   sudah ada di sana dengan yang dari sini (atau merge dependencies-nya).

3. **Install dependencies:**
   ```bash
   cd braille_scan_ai_new
   flutter pub get
   ```

4. **Taruh gambar uji** di `test_assets/sample_braille_document.jpg`
   (lihat `test_assets/README.txt` untuk tips foto yang bagus).

5. **Jalankan:**
   ```bash
   flutter run -d <device_id>
   ```
   Tekan tombol "Jalankan Test Pipeline" di layar — hasil kalimat akan
   muncul di layar sekaligus di console (`print`), termasuk detail
   confidence tiap sel untuk debugging.

   > Catatan: `File()` (dart:io) dipakai untuk baca gambar uji dari disk,
   > jadi test runner ini jalan di Android/iOS/Desktop, **bukan** di Web.
   > `TFLiteService` sendiri sudah otomatis fallback ke mode mock kalau
   > dijalankan di Web.

## Kalau hasil terjemahan meleset

- Cek `print` di console untuk melihat confidence tiap sel — sel dengan
  tanda `?` berarti confidence < 0.40 dan sengaja tidak dipaksa jadi huruf.
- Kalau semua sel jadi `?`, kemungkinan besar preprocessing normalisasi
  (`[0,1]` vs `[-1,1]`) tidak cocok dengan yang dipakai saat training —
  sesuaikan `_cellToInputTensor()`.
- Kalau segmentasi baris/kolom kurang akurat pada foto Anda, coba atur
  `varianceThreshold` di `isCellEmpty()` atau ambang proyeksi di
  `image_processing_service.dart` (`_projectionGapThreshold`,
  `_minRowBandSize`, `_minColBandSize`) sesuai karakteristik foto Anda.

Taruh gambar dokumen Braille untuk pengujian di sini dengan nama:

  sample_braille_document.jpg

(atau ubah path-nya di lib/main.dart, konstanta `_testImagePath`).

Tips foto yang bagus untuk pipeline ini:
- Foto dari sudut sedikit menyamping (bukan tegak lurus) agar bintik
  timbul menghasilkan bayangan yang jelas -- ini penting karena
  `enhanceShadowDepth()` mengandalkan bayangan untuk membedakan titik
  Braille dari kertas.
- Pastikan pencahayaan cukup terang dan merata, tidak blur.
- Dokumen difoto lurus (tidak miring) agar deteksi baris/kolom berbasis
  proyeksi piksel bekerja optimal.

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:braillescan_ai/services/braille_classifier.dart';

/// Gambar uji 3x3 tak simetris: sudut kiri-atas gelap, sisanya terang.
img.Image _asymmetricPattern() {
  final img.Image image = img.Image(width: 3, height: 3);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  image.setPixelRgb(0, 0, 0, 0, 0);
  return image;
}

/// Gambar uji NON-PERSEGI 3x2 dengan empat sudut bernilai abu berbeda.
/// Dipakai untuk membedakan ROTASI murni dari FLIP horizontal:
///   (0,0)=10 (kiri-atas)   (2,0)=60 (kanan-atas)
///   (0,1)=120 (kiri-bawah) (2,1)=200 (kanan-bawah)
img.Image _cornerPattern() {
  final img.Image image = img.Image(width: 3, height: 2);
  image.setPixelRgb(0, 0, 10, 10, 10);
  image.setPixelRgb(2, 0, 60, 60, 60);
  image.setPixelRgb(0, 1, 120, 120, 120);
  image.setPixelRgb(2, 1, 200, 200, 200);
  return image;
}

int _lum(img.Image image, int x, int y) =>
    img.getLuminance(image.getPixel(x, y)).round();

void main() {
  group('argmax - pemilihan murni probabilitas tertinggi dari model', () {
    test('mengambil indeks dengan probabilitas tertinggi', () {
      expect(BrailleClassifier.argmax(const [0.1, 0.7, 0.2]), 1);
      expect(BrailleClassifier.argmax(const [0.05, 0.15, 0.8, 0.0]), 2);
    });

    test('daftar kosong -> indeks 0 (aman, tanpa crash)', () {
      expect(BrailleClassifier.argmax(const []), 0);
    });

    test('nilai seri -> memilih indeks pertama yang ditemukan', () {
      expect(BrailleClassifier.argmax(const [0.5, 0.5, 0.5]), 0);
    });

    test(
      'label akhir = labels[argmax] dalam huruf kapital (pola bersih)',
      () {
        const List<String> labels = <String>['a', 'b', 'c'];
        final List<double> probs = const <double>[0.1, 0.2, 0.7];
        final int maxIndex = BrailleClassifier.argmax(probs);
        final String detectedChar = labels[maxIndex].toUpperCase();

        expect(maxIndex, 2);
        expect(detectedChar, 'C');
      },
    );
  });

  group('kompensasi orientasi plugin native (+90° CW)', () {
    test('default -90° membatalkan rotasi +90° plugin', () {
      final BrailleClassifier classifier = BrailleClassifier();
      final img.Image original = _asymmetricPattern();

      // Kita pra-putar -90°, plugin memutar +90° -> kembali ke aslinya.
      final img.Image sent = classifier.applyOrientationCompensation(original);
      final img.Image pluginView = img.copyRotate(sent, angle: 90);

      for (int y = 0; y < original.height; y++) {
        for (int x = 0; x < original.width; x++) {
          expect(
            img.getLuminance(pluginView.getPixel(x, y)).round(),
            img.getLuminance(original.getPixel(x, y)).round(),
            reason: 'piksel ($x,$y) harus sama dengan citra asli',
          );
        }
      }
    });

    test('-90° = berlawanan arah jarum jam (sudut kiri-atas pindah ke kiri-bawah)', () {
      final BrailleClassifier classifier = BrailleClassifier();
      final img.Image out =
          classifier.applyOrientationCompensation(_asymmetricPattern());

      // Piksel gelap (0,0) pada masukan; rotate CW 270 (=-90) menaruhnya di
      // koordinat (0, height-1).
      expect(img.getLuminance(out.getPixel(0, 2)).round(), 0);
      expect(img.getLuminance(out.getPixel(0, 0)).round(), 255);
    });

    test('0° mematikan kompensasi (citra tidak berubah)', () {
      final BrailleClassifier classifier = BrailleClassifier();
      final int saved = BrailleClassifier.orientationCompensationDegrees;
      BrailleClassifier.orientationCompensationDegrees = 0;
      addTearDown(
        () => BrailleClassifier.orientationCompensationDegrees = saved,
      );

      final img.Image out =
          classifier.applyOrientationCompensation(_asymmetricPattern());
      expect(img.getLuminance(out.getPixel(0, 0)).round(), 0);
      expect(img.getLuminance(out.getPixel(2, 2)).round(), 255);
    });

    test(
      '-90° murni ROTASI, bukan flip horizontal (citra 3x2 non-persegi)',
      () {
        final BrailleClassifier classifier = BrailleClassifier();
        final img.Image out =
            classifier.applyOrientationCompensation(_cornerPattern());

        // Rotasi CCW 90°: 3x2 -> 2x3.
        expect(out.width, 2);
        expect(out.height, 3);

        // Pemetaan rotasi murni: kiri-atas -> kiri-bawah, dst.
        expect(_lum(out, 0, 2), 10); // (0,0) -> (0,2)
        expect(_lum(out, 0, 0), 60); // (2,0) -> (0,0)
        expect(_lum(out, 1, 2), 120); // (0,1) -> (1,2)
        expect(_lum(out, 1, 0), 200); // (2,1) -> (1,0)

        // Jika ada FLIP HORIZONTAL, (0,2) akan berisi 120 (kiri-bawah), bukan
        // 10. Assertion di atas sudah menolak kemungkinan itu.
        expect(_lum(out, 0, 2), isNot(120));
        expect(_lum(out, 1, 2), isNot(10));
      },
    );
  });
}
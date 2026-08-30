import 'package:flutter_test/flutter_test.dart';

import 'package:braille_scan_ai/main.dart';
import 'package:braille_scan_ai/services/braille_parser.dart';

void main() {
  test('BrailleParser merapikan spasi & menerapkan atas-kapital', () {
    final BrailleParser parser = BrailleParser();

    expect(parser.parseLine(['^', 'h', 'a', 'l', 'o']), 'Halo');
    expect(
      parser.parseLine(['h', 'a', 'l', 'o', ' ', 'd', 'u', 'n', 'i', 'a']),
      'halo dunia',
    );
    expect(parser.parseLine(['a', ' ', ' ', 'b']), 'a b');
  });

  testWidgets('HomeScreen menampilkan tombol "Mulai Scan"', (WidgetTester tester) async {
    await tester.pumpWidget(const BrailleScanApp());
    await tester.pump();

    expect(find.text('Mulai Scan (Kamera)'), findsOneWidget);
    expect(find.text('Upload Gambar dari Galeri'), findsOneWidget);
    expect(find.text('BrailleScan AI'), findsOneWidget);
  });
}
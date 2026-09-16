import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'screens/scan_screen.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Gagal mendeteksi kamera: $e');
  }
  runApp(const BrailleScanApp());
}

class BrailleScanApp extends StatelessWidget {
  const BrailleScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BrailleScan AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: ScanScreen(cameras: cameras),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'screens/home_screen.dart';
import 'services/stt_test_service.dart';

void main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Request permissions needed for WebRTC and audio recording
  await [
    Permission.microphone,
    Permission.camera, // Needed for some WebRTC implementations
    Permission.storage,
  ].request();

  // Initialize WebRTC globally
  await WebRTC.initialize();

  // Initialize STT service
  STTTestService.initialize();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter STT Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

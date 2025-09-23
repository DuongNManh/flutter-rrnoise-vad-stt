import 'package:flutter/material.dart';
import 'package:flutter_google_stt/screens/recording_screen.dart';
import 'package:flutter_google_stt/screens/stt_test_screen.dart';
import 'package:flutter_google_stt/screens/synchronized_vad_screen.dart';
import 'package:flutter_google_stt/screens/voice_recording_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Speech Recognition'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App logo or image
            Icon(
              Icons.record_voice_over,
              size: 80,
              color: Theme.of(context).primaryColor,
            ),
            const SizedBox(height: 20),

            // App title
            const Text(
              'Speech Recognition Demo',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            // App description
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Test voice activity detection and speech recognition features',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 60),

            // Navigation buttons
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RecordingScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.mic),
              label: const Text('Recording Demo'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 12,
                ),
                minimumSize: const Size(250, 50),
              ),
            ),
            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const VoiceRecordingScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.play_circle),
              label: const Text('Voice Recording Test'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 12,
                ),
                minimumSize: const Size(250, 50),
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const STTTestScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.settings),
              label: const Text('Google STT Setup'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 12,
                ),
                minimumSize: const Size(250, 50),
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SynchronizedVADScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.play_circle),
              label: const Text('Voice Recording Test v2'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 12,
                ),
                minimumSize: const Size(250, 50),
                backgroundColor: const Color.fromARGB(255, 76, 122, 175),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

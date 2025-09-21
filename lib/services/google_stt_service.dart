import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class GoogleSTTService {
  final String _apiKey;
  static const String _baseUrl =
      'https://speech.googleapis.com/v1/speech:recognize';

  GoogleSTTService(this._apiKey);

  /// Transcribe audio file to text using Google Speech-to-Text API
  /// Returns transcript or null if failed
  Future<STTResult?> transcribeAudioSegment(String audioFilePath) async {
    try {
      final audioFile = File(audioFilePath);
      if (!await audioFile.exists()) {
        print('STT Error: Audio file does not exist: $audioFilePath');
        return null;
      }

      // Read audio file and convert to base64
      final audioBytes = await audioFile.readAsBytes();
      final audioBase64 = base64Encode(audioBytes);

      // Determine audio format based on file extension
      final audioFormat = _getAudioFormat(audioFilePath);

      final requestBody = {
        'config': {
          'encoding': audioFormat,
          'sampleRateHertz': 16000,
          'languageCode': 'vi-VN', // Vietnamese, change to 'en-US' if needed
          'enableAutomaticPunctuation': true,
          'model': 'latest_short', // Optimized for short audio segments
          'useEnhanced': true, // Use enhanced model for better accuracy
          'maxAlternatives': 1,
          'profanityFilter': false,
        },
        'audio': {'content': audioBase64},
      };

      final response = await http.post(
        Uri.parse('$_baseUrl?key=$_apiKey'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);

        if (result['results'] != null && result['results'].isNotEmpty) {
          final firstResult = result['results'][0];
          final alternative = firstResult['alternatives'][0];

          return STTResult(
            transcript: alternative['transcript'] ?? '',
            confidence: (alternative['confidence'] ?? 0.0).toDouble(),
            audioLength: _calculateAudioLength(audioBytes),
          );
        } else {
          print('STT: No speech detected in audio segment');
          return STTResult(
            transcript: '',
            confidence: 0.0,
            audioLength: _calculateAudioLength(audioBytes),
          );
        }
      } else {
        print('STT API Error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e, stackTrace) {
      print('STT Exception: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  /// Determine audio encoding format based on file extension
  String _getAudioFormat(String filePath) {
    final extension = filePath.toLowerCase().split('.').last;

    switch (extension) {
      case 'wav':
        return 'LINEAR16';
      case 'webm':
        return 'WEBM_OPUS';
      case 'm4a':
      case 'aac':
        return 'MP3'; // Google STT treats AAC as MP3
      case 'mp3':
        return 'MP3';
      case 'flac':
        return 'FLAC';
      default:
        return 'LINEAR16'; // Default fallback
    }
  }

  /// Calculate approximate audio length in milliseconds
  int _calculateAudioLength(Uint8List audioBytes) {
    // This is an approximation - for exact length, we'd need to parse audio header
    // Assuming 16kHz, 16-bit mono audio: 32000 bytes per second
    const bytesPerSecond = 32000;
    return ((audioBytes.length / bytesPerSecond) * 1000).round();
  }

  /// Test API connection with a simple request
  Future<bool> testConnection() async {
    try {
      // Create a minimal test request
      final requestBody = {
        'config': {
          'encoding': 'LINEAR16',
          'sampleRateHertz': 16000,
          'languageCode': 'vi-VN',
        },
        'audio': {
          'content': '', // Empty content for test
        },
      };

      final response = await http.post(
        Uri.parse('$_baseUrl?key=$_apiKey'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(requestBody),
      );

      // Even with empty content, we should get a response (may be error but connection works)
      return response.statusCode == 400 || response.statusCode == 200;
    } catch (e) {
      print('STT Connection Test Failed: $e');
      return false;
    }
  }

  /// Get supported language codes
  static List<String> getSupportedLanguages() {
    return [
      'vi-VN', // Vietnamese
      'en-US', // English (US)
      'en-GB', // English (UK)
      'ja-JP', // Japanese
      'ko-KR', // Korean
      'zh-CN', // Chinese (Simplified)
      'zh-TW', // Chinese (Traditional)
      'th-TH', // Thai
      'id-ID', // Indonesian
      'ms-MY', // Malay
    ];
  }
}

/// Result class for STT response
class STTResult {
  final String transcript;
  final double confidence;
  final int audioLength; // in milliseconds
  final DateTime timestamp;

  STTResult({
    required this.transcript,
    required this.confidence,
    required this.audioLength,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get hasText => transcript.isNotEmpty;
  bool get isHighConfidence => confidence >= 0.7;
  bool get isMediumConfidence => confidence >= 0.5;

  Map<String, dynamic> toJson() {
    return {
      'transcript': transcript,
      'confidence': confidence,
      'audioLength': audioLength,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'STTResult(transcript: "$transcript", confidence: $confidence, length: ${audioLength}ms)';
  }
}

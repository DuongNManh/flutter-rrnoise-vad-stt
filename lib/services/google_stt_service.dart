import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class GoogleSTTService {
  final String _apiKey;
  static const String _baseUrl =
      'https://speech.googleapis.com/v1/speech:recognize';

  // Connection pool để tái sử dụng connection
  static final http.Client _httpClient = http.Client();

  GoogleSTTService(this._apiKey);

  /// Transcribe audio buffer directly to text using Google Speech-to-Text API
  /// Phương thức này xử lý trực tiếp dữ liệu audio từ buffer thay vì file
  Future<STTResult?> transcribeAudioBuffer(
    Uint8List audioBuffer, {
    String? audioFormat = 'LINEAR16',
    int sampleRate = 16000,
    String debugName = 'buffer',
  }) async {
    // Check if API key is valid
    if (_apiKey.isEmpty || _apiKey == 'YOUR_KEY_HERE') {
      if (kDebugMode) {
        print('STT Error: Invalid API key');
      }
      return null;
    }
    try {
      // Kiểm tra buffer có hợp lệ không
      if (audioBuffer.isEmpty) {
        if (kDebugMode) {
          print('STT Error: Audio buffer is empty');
        }
        return null;
      }

      // Kiểm tra buffer size - nếu quá lớn thì báo lỗi
      if (audioBuffer.length > 10 * 1024 * 1024) {
        // 10MB limit
        if (kDebugMode) {
          print(
            'STT Error: Audio buffer too large: ${audioBuffer.length} bytes',
          );
        }
        return null;
      }

      // Add logging to help diagnose issues
      if (kDebugMode) {
        if (audioBuffer.length < 1000) {
          print(
            '⚠️ Warning: Audio buffer is very small (${audioBuffer.length} bytes), may not contain speech',
          );
        }

        print(
          'Processing audio buffer ($debugName): ${audioBuffer.length} bytes',
        );
      }

      // Chạy STT processing trong compute isolate để không block UI
      final result = await compute(_transcribeBufferInIsolate, {
        'audioBytes': audioBuffer,
        'apiKey': _apiKey,
        'audioFormat': audioFormat,
        'sampleRate': sampleRate,
      });

      return result;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('STT Buffer Exception: $e');
        print('Stack trace: $stackTrace');
      }
      return null;
    }
  }

  /// Transcribe audio file to text using Google Speech-to-Text API
  /// Sử dụng isolate để không block UI thread
  Future<STTResult?> transcribeAudioSegment(String audioFilePath) async {
    try {
      // Kiểm tra file tồn tại trước
      final audioFile = File(audioFilePath);
      if (!await audioFile.exists()) {
        if (kDebugMode) {
          print('STT Error: Audio file does not exist: $audioFilePath');
        }
        return null;
      }

      // Đọc file với buffer size tối ưu
      final audioBytes = await audioFile.readAsBytes();

      // Kiểm tra file size - nếu quá lớn thì báo lỗi
      if (audioBytes.length > 10 * 1024 * 1024) {
        // 10MB limit
        if (kDebugMode) {
          print('STT Error: Audio file too large: ${audioBytes.length} bytes');
        }
        return null;
      }

      // Add logging to help diagnose issues
      if (kDebugMode) {
        if (audioBytes.length < 1000) {
          print(
            '⚠️ Warning: Audio file is very small (${audioBytes.length} bytes), may not contain speech',
          );
        }
      }

      // Chạy STT processing trong compute isolate để không block UI
      final result = await compute(_transcribeInIsolate, {
        'audioBytes': audioBytes,
        'audioFilePath': audioFilePath,
        'apiKey': _apiKey,
      });

      return result;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('STT Exception: $e');
        print('Stack trace: $stackTrace');
      }
      return null;
    }
  }

  /// Static method để xử lý buffer âm thanh trong isolate
  static Future<STTResult?> _transcribeBufferInIsolate(
    Map<String, dynamic> params,
  ) async {
    try {
      final Uint8List audioBytes = params['audioBytes'];
      final String apiKey = params['apiKey'];
      final String audioFormat = params['audioFormat'] ?? 'LINEAR16';
      final int sampleRate = params['sampleRate'] ?? 16000;

      // Convert to base64 trong isolate
      final audioBase64 = base64Encode(audioBytes);

      final requestBody = {
        'config': {
          'encoding': audioFormat,
          'sampleRateHertz': sampleRate,
          'languageCode': 'en-US',
          'alternativeLanguageCodes': ['vi-VN'],
          'enableAutomaticPunctuation': true,
          'model': 'latest_short',
          'useEnhanced': true,
          'maxAlternatives': 1,
          'profanityFilter': false,
          // Thêm timeout để tránh request bị treo
          'speechContexts': [],
        },
        'audio': {'content': audioBase64},
      };

      // Log request details in debug mode
      if (kDebugMode) {
        print(
          'STT Buffer Request: Audio format: $audioFormat, size: ${audioBytes.length} bytes',
        );
      }

      // Sử dụng timeout cho HTTP request
      final response = await http
          .post(
            Uri.parse('$_baseUrl?key=$apiKey'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'Flutter-STT-Client/1.0',
            },
            body: jsonEncode(requestBody),
          )
          .timeout(
            const Duration(seconds: 30), // Timeout sau 30 giây
            onTimeout: () {
              throw TimeoutException(
                'STT API request timed out',
                const Duration(seconds: 30),
              );
            },
          );

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);

        if (result['results'] != null && result['results'].isNotEmpty) {
          final firstResult = result['results'][0];
          final alternative = firstResult['alternatives'][0];

          return STTResult(
            transcript: alternative['transcript'] ?? '',
            confidence: (alternative['confidence'] ?? 0.0).toDouble(),
            audioLength: _calculateAudioLengthStatic(audioBytes),
          );
        } else {
          if (kDebugMode) {
            print('STT: No speech detected in audio buffer');
            // Calculate approximate speech level in dB
            double sumOfSquares = 0.0;
            final sampleStep = audioBytes.length > 1000
                ? audioBytes.length ~/ 1000
                : 1;
            int samplesCount = 0;

            // For WAV, skip header - in general buffer case, check first few bytes to see if it's a WAV header
            bool isWav =
                audioBytes.length > 44 &&
                String.fromCharCodes(audioBytes.sublist(0, 4)) == 'RIFF' &&
                String.fromCharCodes(audioBytes.sublist(8, 12)) == 'WAVE';
            int startOffset = isWav ? 44 : 0;

            for (
              int i = startOffset;
              i < audioBytes.length;
              i += sampleStep * 2
            ) {
              if (i + 1 < audioBytes.length) {
                final sample = audioBytes[i] | (audioBytes[i + 1] << 8);
                final normalizedSample = (sample < 32768)
                    ? sample
                    : sample - 65536;
                sumOfSquares += normalizedSample * normalizedSample;
                samplesCount++;
              }
            }

            if (samplesCount > 0) {
              final rms = math.sqrt(sumOfSquares / samplesCount);
              final db = 20 * math.log(rms > 0 ? rms : 1) / math.ln10;
              print(
                'Audio buffer level: ${db.toStringAsFixed(2)} dB, Size: ${audioBytes.length} bytes',
              );
            }
          }

          return STTResult(
            transcript: '',
            confidence: 0.0,
            audioLength: _calculateAudioLengthStatic(audioBytes),
          );
        }
      } else {
        // Log lỗi API một cách có control
        if (kDebugMode) {
          print('STT API Error: ${response.statusCode}');
          // Chỉ log response body nếu không quá dài
          if (response.body.length < 500) {
            print('Response: ${response.body}');
          }
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('STT Buffer Isolate Exception: $e');
      }
      return null;
    }
  }

  /// Static method để chạy trong isolate
  static Future<STTResult?> _transcribeInIsolate(
    Map<String, dynamic> params,
  ) async {
    try {
      final Uint8List audioBytes = params['audioBytes'];
      final String audioFilePath = params['audioFilePath'];
      final String apiKey = params['apiKey'];

      // Convert to base64 trong isolate
      final audioBase64 = base64Encode(audioBytes);
      final audioFormat = _getAudioFormatStatic(audioFilePath);

      final requestBody = {
        'config': {
          'encoding': audioFormat,
          'sampleRateHertz': 16000,
          'languageCode': 'en-US',
          'alternativeLanguageCodes': ['vi-VN'],
          'enableAutomaticPunctuation': true,
          'model': 'latest_short',
          'useEnhanced': true,
          'maxAlternatives': 1,
          'profanityFilter': false,
          // Thêm timeout để tránh request bị treo
          'speechContexts': [],
        },
        'audio': {'content': audioBase64},
      };

      // Log request details in debug mode
      if (kDebugMode) {
        print(
          'STT Request: Audio format: $audioFormat, size: ${audioBytes.length} bytes',
        );
      }

      // Sử dụng timeout cho HTTP request
      final response = await http
          .post(
            Uri.parse('$_baseUrl?key=$apiKey'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'Flutter-STT-Client/1.0',
            },
            body: jsonEncode(requestBody),
          )
          .timeout(
            const Duration(seconds: 30), // Timeout sau 30 giây
            onTimeout: () {
              throw TimeoutException(
                'STT API request timed out',
                const Duration(seconds: 30),
              );
            },
          );

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);

        if (result['results'] != null && result['results'].isNotEmpty) {
          final firstResult = result['results'][0];
          final alternative = firstResult['alternatives'][0];

          return STTResult(
            transcript: alternative['transcript'] ?? '',
            confidence: (alternative['confidence'] ?? 0.0).toDouble(),
            audioLength: _calculateAudioLengthStatic(audioBytes),
          );
        } else {
          if (kDebugMode) {
            print('STT: No speech detected in audio segment');
          }
          if (kDebugMode) {
            print('STT API Response: No speech detected in audio segment');
            // Calculate approximate speech level in dB
            double sumOfSquares = 0.0;
            final sampleStep = audioBytes.length > 1000
                ? audioBytes.length ~/ 1000
                : 1;
            int samplesCount = 0;

            for (int i = 44; i < audioBytes.length; i += sampleStep * 2) {
              // Skip WAV header (44 bytes)
              if (i + 1 < audioBytes.length) {
                final sample = audioBytes[i] | (audioBytes[i + 1] << 8);
                final normalizedSample = (sample < 32768)
                    ? sample
                    : sample - 65536;
                sumOfSquares += normalizedSample * normalizedSample;
                samplesCount++;
              }
            }

            if (samplesCount > 0) {
              final rms = math.sqrt(sumOfSquares / samplesCount);
              final db = 20 * math.log(rms > 0 ? rms : 1) / math.ln10;
              print(
                'Audio level: ${db.toStringAsFixed(2)} dB, File size: ${audioBytes.length} bytes',
              );
            }
          }

          return STTResult(
            transcript: '',
            confidence: 0.0,
            audioLength: _calculateAudioLengthStatic(audioBytes),
          );
        }
      } else {
        // Log lỗi API một cách có control
        if (kDebugMode) {
          print('STT API Error: ${response.statusCode}');
          // Chỉ log response body nếu không quá dài
          if (response.body.length < 500) {
            print('Response: ${response.body}');
          }
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('STT Isolate Exception: $e');
      }
      return null;
    }
  }

  /// Static version của _getAudioFormat cho isolate
  static String _getAudioFormatStatic(String filePath) {
    final extension = filePath.toLowerCase().split('.').last;

    switch (extension) {
      case 'wav':
        return 'LINEAR16';
      case 'webm':
        return 'WEBM_OPUS';
      case 'm4a':
      case 'aac':
        return 'MP3';
      case 'mp3':
        return 'MP3';
      case 'flac':
        return 'FLAC';
      default:
        return 'LINEAR16';
    }
  }

  /// Static version của _calculateAudioLength cho isolate
  static int _calculateAudioLengthStatic(Uint8List audioBytes) {
    // Tính toán chính xác hơn cho WAV file
    if (audioBytes.length >= 44) {
      try {
        // Đọc WAV header để lấy thông tin chính xác
        // Bytes 24-27: Sample Rate
        // Bytes 28-31: Byte Rate
        // Bytes 40-43: Data size

        final byteRate =
            audioBytes[28] |
            (audioBytes[29] << 8) |
            (audioBytes[30] << 16) |
            (audioBytes[31] << 24);

        if (byteRate > 0) {
          final dataSize = audioBytes.length - 44; // Subtract header size
          return ((dataSize / byteRate) * 1000).round();
        }
      } catch (e) {
        // Fallback to approximation
      }
    }

    // Fallback approximation
    const bytesPerSecond = 32000; // 16kHz, 16-bit mono
    return ((audioBytes.length / bytesPerSecond) * 1000).round();
  }

  /// Determine audio encoding format based on file extension
  String _getAudioFormat(String filePath) {
    return _getAudioFormatStatic(filePath);
  }

  /// Calculate approximate audio length in milliseconds
  int _calculateAudioLength(Uint8List audioBytes) {
    return _calculateAudioLengthStatic(audioBytes);
  }

  /// Test API connection với optimization
  Future<bool> testConnection() async {
    try {
      // Test với request nhỏ và timeout ngắn
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

      final response = await _httpClient
          .post(
            Uri.parse('$_baseUrl?key=$_apiKey'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 10));

      // Connection successful if we get any response
      return response.statusCode == 400 || response.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        print('STT Connection Test Failed: $e');
      }
      return false;
    }
  }

  /// Transcribe with retry logic để tăng reliability
  Future<STTResult?> transcribeWithRetry(
    String audioFilePath, {
    int maxRetries = 2,
  }) async {
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final result = await transcribeAudioSegment(audioFilePath);
        if (result != null) {
          return result;
        }
      } catch (e) {
        if (kDebugMode) {
          print('STT attempt ${attempt + 1} failed: $e');
        }
        if (attempt == maxRetries - 1) rethrow;

        // Exponential backoff
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    return null;
  }

  /// Batch transcription cho multiple segments
  Future<List<STTResult?>> transcribeBatch(
    List<String> audioFilePaths, {
    int concurrency = 2,
  }) async {
    final results = <STTResult?>[];

    // Process in batches để không overwhelm API
    for (int i = 0; i < audioFilePaths.length; i += concurrency) {
      final batch = audioFilePaths.skip(i).take(concurrency);
      final futures = batch
          .map((path) => transcribeAudioSegment(path))
          .toList();
      final batchResults = await Future.wait(futures);
      results.addAll(batchResults);

      // Small delay between batches
      if (i + concurrency < audioFilePaths.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    return results;
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

  /// Dispose resources
  void dispose() {
    // Đóng HTTP client khi không dùng nữa
    // Chú ý: chỉ gọi khi chắc chắn không có STT service nào khác đang dùng
  }

  /// Static method để đóng shared HTTP client
  static void closeSharedClient() {
    _httpClient.close();
  }
}

/// Result class for STT response với optimizations
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

  bool get hasText => transcript.trim().isNotEmpty;
  bool get isHighConfidence => confidence >= 0.7;
  bool get isMediumConfidence => confidence >= 0.5;
  bool get isLowConfidence => confidence < 0.5;

  /// Get confidence level as string
  String get confidenceLevel {
    if (isHighConfidence) return 'High';
    if (isMediumConfidence) return 'Medium';
    return 'Low';
  }

  /// Get formatted audio duration
  String get formattedDuration {
    final seconds = audioLength / 1000;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(1)}s';
    } else {
      final minutes = seconds ~/ 60;
      final remainingSeconds = seconds % 60;
      return '${minutes}m ${remainingSeconds.toStringAsFixed(1)}s';
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'transcript': transcript,
      'confidence': confidence,
      'audioLength': audioLength,
      'timestamp': timestamp.toIso8601String(),
      'hasText': hasText,
      'confidenceLevel': confidenceLevel,
    };
  }

  /// Create from JSON
  factory STTResult.fromJson(Map<String, dynamic> json) {
    return STTResult(
      transcript: json['transcript'] ?? '',
      confidence: (json['confidence'] ?? 0.0).toDouble(),
      audioLength: json['audioLength'] ?? 0,
      timestamp: DateTime.parse(
        json['timestamp'] ?? DateTime.now().toIso8601String(),
      ),
    );
  }

  @override
  String toString() {
    return 'STTResult(transcript: "$transcript", confidence: ${confidence.toStringAsFixed(2)}, length: $formattedDuration)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is STTResult &&
          runtimeType == other.runtimeType &&
          transcript == other.transcript &&
          confidence == other.confidence &&
          audioLength == other.audioLength;

  @override
  int get hashCode =>
      transcript.hashCode ^ confidence.hashCode ^ audioLength.hashCode;
}

import 'api_keys.dart';

class AppConfig {
  // Google Speech-to-Text API Configuration
  static String get googleSTTApiKey => ApiKeys.googleSpeechApiKey;

  // Language configuration
  static const String defaultLanguage = 'vi-VN'; // Vietnamese
  static const List<String> supportedLanguages = [
    'vi-VN', // Vietnamese
    'en-US', // English (US)
    'en-GB', // English (UK)
    'ja-JP', // Japanese
    'ko-KR', // Korean
    'zh-CN', // Chinese (Simplified)
    'th-TH', // Thai
  ];

  // STT Model configuration
  static const String preferredModel =
      'latest_short'; // For short audio segments
  static const bool useEnhancedModel = true; // Better accuracy but higher cost
  static const bool enableAutomaticPunctuation = true;
  static const int sampleRateHertz = 16000; // Audio sample rate

  // VAD Configuration
  static const double speechThreshold = 0.5;
  static const double silenceThreshold = 0.3;
  static const int minSegmentDurationMs = 500; // Minimum 0.5 seconds
  static const int maxSegmentDurationMs = 15000; // Maximum 15 seconds

  // Performance settings
  static const int maxConcurrentSTTRequests = 3;
  static const int sttTimeoutMs = 10000; // 10 seconds timeout

  // Debug settings
  static const bool enableDebugLogs = true;
  static const bool enablePerformanceMetrics = true;
}

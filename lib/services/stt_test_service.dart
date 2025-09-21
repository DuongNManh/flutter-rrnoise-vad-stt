import 'package:flutter/material.dart';
import '../services/google_stt_service.dart';
import '../config/app_config.dart';

class STTTestService {
  static GoogleSTTService? _sttService;

  /// Initialize STT service with API key
  static void initialize() {
    if (AppConfig.googleSTTApiKey != 'YOUR_API_KEY_HERE') {
      _sttService = GoogleSTTService(AppConfig.googleSTTApiKey);
    }
  }

  /// Check if STT service is available
  static bool get isAvailable => _sttService != null;

  /// Get STT service instance (null if not configured)
  static GoogleSTTService? get instance => _sttService;

  /// Test API connection
  static Future<bool> testConnection() async {
    if (!isAvailable) {
      debugPrint('STT Service not available - API key not configured');
      return false;
    }

    try {
      final result = await _sttService!.testConnection();
      debugPrint('STT Connection Test: ${result ? "SUCCESS" : "FAILED"}');
      return result;
    } catch (e) {
      debugPrint('STT Connection Test Error: $e');
      return false;
    }
  }

  /// Show configuration status
  static String getConfigStatus() {
    if (AppConfig.googleSTTApiKey == 'YOUR_API_KEY_HERE') {
      return '❌ API Key not configured';
    } else if (!isAvailable) {
      return '⚠️ STT Service initialization failed';
    } else {
      return '✅ STT Service ready';
    }
  }

  /// Show instructions for setup
  static String getSetupInstructions() {
    return '''
📝 Setup Instructions:

1. Go to Google Cloud Console
2. Enable "Cloud Speech-to-Text API"
3. Create API Key in Credentials
4. Copy your API key
5. Replace 'YOUR_API_KEY_HERE' in app_config.dart
6. Restart the app

Current status: ${getConfigStatus()}
''';
  }
}

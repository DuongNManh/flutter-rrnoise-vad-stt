/// API Keys Configuration
/// IMPORTANT: Never commit real API keys to version control!
class ApiKeys {
  // Replace with your actual Google Cloud Speech-to-Text API key
  static const String googleSpeechApiKey = 'YOUR_GOOGLE_SPEECH_API_KEY_HERE';

  // Check if API key is configured
  static bool get isConfigured =>
      googleSpeechApiKey != 'YOUR_GOOGLE_SPEECH_API_KEY_HERE';

  // Get API key with validation
  static String? get speechApiKey {
    if (!isConfigured) {
      print('WARNING: Google Speech API key not configured!');
      return null;
    }
    return googleSpeechApiKey;
  }
}

/// Instructions for getting Google Speech-to-Text API key:
/// 
/// 1. Go to Google Cloud Console: https://console.cloud.google.com
/// 2. Select your project or create a new one
/// 3. Enable Speech-to-Text API:
///    - Go to APIs & Services → Library
///    - Search for "Speech-to-Text API"
///    - Click Enable
/// 4. Create API Key:
///    - Go to APIs & Services → Credentials
///    - Click "+ CREATE CREDENTIALS" → "API Key"
///    - Copy the generated key
/// 5. Restrict API Key (Recommended):
///    - Click on the API key
///    - Under "API restrictions" → "Restrict key"
///    - Select only "Cloud Speech-to-Text API"
///    - Save
/// 6. Replace 'YOUR_GOOGLE_SPEECH_API_KEY_HERE' above with your actual key
/// 
/// Cost Information:
/// - First 60 minutes per month: FREE
/// - After that: $0.006 per 15 seconds ($0.024 per minute)
/// - Enhanced models: $0.009 per 15 seconds ($0.036 per minute)
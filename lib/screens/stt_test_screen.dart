import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_google_stt/services/google_stt_service.dart';
import '../services/stt_test_service.dart';
import '../config/app_config.dart';

class STTTestScreen extends StatefulWidget {
  const STTTestScreen({super.key});

  @override
  State<STTTestScreen> createState() => _STTTestScreenState();
}

class _STTTestScreenState extends State<STTTestScreen> {
  GoogleSTTService? _sttService;
  bool _isApiConfigured = false;
  bool _isTestingConnection = false;
  String _connectionStatus = 'Not tested';

  @override
  void initState() {
    super.initState();
    _initSTTService();
  }

  void _initSTTService() {
    if (ApiKeys.isConfigured && ApiKeys.speechApiKey != null) {
      _sttService = GoogleSTTService(ApiKeys.speechApiKey!);
      setState(() {
        _isApiConfigured = true;
        _connectionStatus = 'API key configured - ready to test';
      });
    } else {
      setState(() {
        _isApiConfigured = false;
        _connectionStatus = 'API key not configured';
      });
    }
  }

  Future<void> _testConnection() async {
    if (_sttService == null) return;

    setState(() {
      _isTestingConnection = true;
      _connectionStatus = 'Testing connection...';
    });

    try {
      final result = await _sttService!.testConnection();
      setState(() {
        _connectionStatus = result
            ? '✅ Connection successful!'
            : '❌ Connection failed - check API key';
      });
    } catch (e) {
      setState(() {
        _connectionStatus = '❌ Error: $e';
      });
    } finally {
      setState(() {
        _isTestingConnection = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google STT Setup'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // API Configuration Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'API Configuration Status',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          _isApiConfigured ? Icons.check_circle : Icons.error,
                          color: _isApiConfigured ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _isApiConfigured
                                ? 'Google Speech API key is configured'
                                : 'Google Speech API key not configured',
                            style: TextStyle(
                              color: _isApiConfigured
                                  ? Colors.green
                                  : Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Connection Test
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connection Test',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(_connectionStatus),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _isApiConfigured && !_isTestingConnection
                          ? _testConnection
                          : null,
                      child: _isTestingConnection
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text('Testing...'),
                              ],
                            )
                          : const Text('Test Connection'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Setup Instructions
            if (!_isApiConfigured) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Setup Instructions',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '1. Go to Google Cloud Console\n'
                        '2. Enable Speech-to-Text API\n'
                        '3. Create an API Key\n'
                        '4. Copy the API key\n'
                        '5. Update lib/config/api_keys.dart\n'
                        '6. Replace YOUR_GOOGLE_SPEECH_API_KEY_HERE with your key',
                        style: TextStyle(height: 1.5),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () {
                          // Show detailed instructions
                          showDialog(
                            context: context,
                            builder: (context) =>
                                const _SetupInstructionsDialog(),
                          );
                        },
                        child: const Text('View Detailed Instructions'),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Supported Languages
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Supported Languages',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: GoogleSTTService.getSupportedLanguages()
                          .map((lang) => Chip(label: Text(lang)))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupInstructionsDialog extends StatelessWidget {
  const _SetupInstructionsDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Google Cloud Speech-to-Text Setup'),
      content: const SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Step 1: Access Google Cloud Console',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '• Go to https://console.cloud.google.com\n• Select your project\n',
            ),

            Text(
              'Step 2: Enable Speech-to-Text API',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '• Go to APIs & Services → Library\n• Search "Speech-to-Text API"\n• Click Enable\n',
            ),

            Text(
              'Step 3: Create API Key',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '• Go to APIs & Services → Credentials\n• Click "+ CREATE CREDENTIALS" → "API Key"\n• Copy the generated key\n',
            ),

            Text(
              'Step 4: Secure API Key (Recommended)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '• Click on the API key\n• Under "API restrictions" → "Restrict key"\n• Select only "Cloud Speech-to-Text API"\n• Save\n',
            ),

            Text(
              'Step 5: Update Flutter App',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '• Open lib/config/api_keys.dart\n• Replace YOUR_GOOGLE_SPEECH_API_KEY_HERE\n• with your actual API key',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

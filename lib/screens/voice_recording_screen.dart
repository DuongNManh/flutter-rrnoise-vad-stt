import 'package:flutter/material.dart';
import '../services/clean_vad_service.dart';
import '../services/audio_buffer_manager.dart';
import '../services/google_stt_service.dart';
import '../services/stt_test_service.dart';

/// Example implementation showing how to use the clean VAD service
class VoiceRecordingScreen extends StatefulWidget {
  const VoiceRecordingScreen({Key? key}) : super(key: key);

  @override
  State<VoiceRecordingScreen> createState() => _VoiceRecordingScreenState();
}

class _VoiceRecordingScreenState extends State<VoiceRecordingScreen> {
  late CleanVADService _vadService;
  double _currentConfidence = 0.0;
  bool _isSpeechActive = false;
  double _audioLevel = 0.0;
  List<SpeechSegment> _segments = [];
  String _fullTranscript = '';

  @override
  void initState() {
    super.initState();
    _initializeVADService();
  }

  void _initializeVADService() {
    // Get STT service from the initialized instance
    final sttService = STTTestService.instance;

    // Configure speech detection
    const config = SpeechDetectionConfig(
      positiveSpeechThreshold: 0.4,
      negativeSpeechThreshold: 0.2,
      preBufferDuration: Duration(milliseconds: 200),
      postBufferDuration: Duration(milliseconds: 300),
    );

    // Create VAD service with STT if available
    _vadService = CleanVADService(sttService: sttService, config: config);

    // Show warning if STT is not available
    if (sttService == null && mounted) {
      Future.microtask(() {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Google STT service not available. Please configure API key in settings.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      });
    }

    // Listen to streams
    _vadService.confidenceStream.listen((confidence) {
      setState(() {
        _currentConfidence = confidence;
      });
    });

    _vadService.speechStateStream.listen((isActive) {
      setState(() {
        _isSpeechActive = isActive;
      });
    });

    _vadService.audioLevelStream.listen((level) {
      setState(() {
        _audioLevel = level;
      });
    });

    _vadService.transcriptStream.listen((segment) {
      setState(() {
        _segments = List.from(_vadService.speechSegments);
        _fullTranscript = _vadService.getFullTranscript();
      });

      // Show notification for new transcript
      if (segment.hasTranscript) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('New transcript: "${segment.transcript}"'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });

    // Listen for UI updates
    _vadService.addListener(() {
      setState(() {
        _segments = List.from(_vadService.speechSegments);
        _fullTranscript = _vadService.getFullTranscript();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Recording with VAD'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: _vadService.isRecording
                ? null
                : () {
                    _vadService.clearAll();
                    setState(() {
                      _segments.clear();
                      _fullTranscript = '';
                      _currentConfidence = 0.0;
                      _audioLevel = 0.0;
                    });
                  },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Recording controls
            _buildRecordingControls(),
            const SizedBox(height: 20),

            // Status indicators
            _buildStatusIndicators(),
            const SizedBox(height: 20),

            // Audio level indicator
            _buildAudioLevelIndicator(),
            const SizedBox(height: 20),

            // Full transcript
            _buildFullTranscript(),
            const SizedBox(height: 20),

            // Segments list
            Expanded(child: _buildSegmentsList()),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ElevatedButton(
          onPressed: _vadService.isRecording ? null : _startRecording,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
          child: const Text('Start Recording'),
        ),
        const SizedBox(width: 20),
        ElevatedButton(
          onPressed: _vadService.isRecording ? _stopRecording : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
          child: const Text('Stop Recording'),
        ),
      ],
    );
  }

  Widget _buildStatusIndicators() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatusItem(
                  'Recording',
                  _vadService.isRecording ? 'Active' : 'Inactive',
                  _vadService.isRecording ? Colors.green : Colors.grey,
                ),
                _buildStatusItem(
                  'Speech',
                  _isSpeechActive ? 'Detected' : 'Silent',
                  _isSpeechActive ? Colors.blue : Colors.grey,
                ),
                _buildStatusItem(
                  'Confidence',
                  '${(_currentConfidence * 100).toInt()}%',
                  _getConfidenceColor(_currentConfidence),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatusItem(
                  'Segments',
                  '${_segments.length}',
                  Colors.purple,
                ),
                _buildStatusItem(
                  'Duration',
                  '${_vadService.recordingDuration.toStringAsFixed(1)}s',
                  Colors.orange,
                ),
                _buildStatusItem(
                  'Processing',
                  '${_segments.where((s) => s.isProcessing).length}',
                  Colors.amber,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Color _getConfidenceColor(double confidence) {
    if (confidence > 0.7) return Colors.green;
    if (confidence > 0.4) return Colors.orange;
    return Colors.red;
  }

  Widget _buildAudioLevelIndicator() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              'Audio Level',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _audioLevel / 100,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(
                _audioLevel > 50 ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(height: 4),
            Text('${_audioLevel.toInt()}%'),
          ],
        ),
      ),
    );
  }

  Widget _buildFullTranscript() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Full Transcript',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (_fullTranscript.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () => _copyToClipboard(_fullTranscript),
                    tooltip: 'Copy transcript',
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              height: 100,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                child: Text(
                  _fullTranscript.isEmpty
                      ? 'No transcript yet...'
                      : _fullTranscript,
                  style: TextStyle(
                    color: _fullTranscript.isEmpty ? Colors.grey : Colors.black,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentsList() {
    return Card(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'Speech Segments',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: _segments.isEmpty
                ? const Center(child: Text('No segments yet...'))
                : ListView.builder(
                    itemCount: _segments.length,
                    itemBuilder: (context, index) {
                      final segment = _segments[index];
                      return _buildSegmentItem(segment, index + 1);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentItem(SpeechSegment segment, int index) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: segment.hasTranscript
            ? Colors.green
            : (segment.isProcessing ? Colors.orange : Colors.grey),
        child: Text('$index'),
      ),
      title: Text(
        segment.hasTranscript
            ? segment.transcript!
            : (segment.isProcessing ? 'Processing...' : 'No transcript'),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Duration: ${segment.duration.inMilliseconds}ms'),
          Text('Confidence: ${(segment.confidence * 100).toInt()}%'),
          if (segment.sttConfidence != null)
            Text('STT Confidence: ${(segment.sttConfidence! * 100).toInt()}%'),
        ],
      ),
      trailing: segment.hasTranscript
          ? IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => _copyToClipboard(segment.transcript!),
            )
          : null,
      isThreeLine: true,
    );
  }

  Future<void> _startRecording() async {
    final success = await _vadService.startRecording();
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Failed to start recording. Check microphone permissions.',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _stopRecording() async {
    await _vadService.stopRecording();

    // Show summary
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Recording stopped. ${_segments.length} segments captured.',
        ),
        backgroundColor: Colors.blue,
      ),
    );
  }

  void _copyToClipboard(String text) {
    // Implement clipboard functionality
    // Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard!')));
  }

  @override
  void dispose() {
    _vadService.dispose();
    super.dispose();
  }
}

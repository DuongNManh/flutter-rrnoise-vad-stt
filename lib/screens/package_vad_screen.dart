import 'package:flutter/material.dart';
import 'package:flutter_google_stt/services/package_vad_service.dart';
import 'package:flutter_google_stt/widgets/enhanced_waveform.dart';
import 'package:flutter_google_stt/screens/transcript_screen.dart';
import 'dart:async';

class PackageVADScreen extends StatefulWidget {
  const PackageVADScreen({super.key});

  @override
  State<PackageVADScreen> createState() => _PackageVADScreenState();
}

class _PackageVADScreenState extends State<PackageVADScreen> {
  // VAD service instance
  final _vadService = PackageVadService();

  // State variables
  bool _isRecording = false;
  List<double> _audioLevels = [];
  List<VADEvent> _vadEvents = [];
  List<AudioSegment> _audioSegments = [];
  bool _isSpeechDetected = false;
  double _currentConfidence = 0.0;
  final ScrollController _logScrollController = ScrollController();

  // Stream subscriptions
  late final StreamSubscription _audioLevelSubscription;
  late final StreamSubscription _waveformSubscription;
  late final StreamSubscription _speechSubscription;

  // Performance optimization
  DateTime? _lastUIUpdate;
  final int _uiUpdateThrottleMs = 50; // Match service throttling
  bool _shouldUpdateWaveform = true;

  @override
  void initState() {
    super.initState();
    _setupSubscriptions();
  }

  void _setupSubscriptions() {
    // Listen to audio level changes with throttling
    _audioLevelSubscription = _vadService.audioLevelStream.listen((level) {
      final now = DateTime.now();

      // Throttle UI updates to match service throttling
      if (_lastUIUpdate == null ||
          now.difference(_lastUIUpdate!).inMilliseconds >=
              _uiUpdateThrottleMs) {
        _lastUIUpdate = now;

        if (mounted && _shouldUpdateWaveform) {
          setState(() {
            _audioLevels = List.from(_vadService.audioLevels);
          });
        }
      }
    });

    // Listen to waveform updates - now using the audio level subscription
    _waveformSubscription = _vadService.waveformStream.listen((waveform) {
      // Redundant with audio level subscription, kept for compatibility
    });

    // Listen to speech detection state
    _speechSubscription = _vadService.speechDetectedStream.listen((isSpeech) {
      if (mounted) {
        setState(() {
          _isSpeechDetected = isSpeech;
          _vadEvents = List.from(_vadService.events);
          _audioSegments = List.from(_vadService.segments);
          _currentConfidence = _vadService.currentConfidence;
        });

        // Auto-scroll logs
        if (_logScrollController.hasClients) {
          Future.delayed(const Duration(milliseconds: 50), () {
            _logScrollController.animateTo(
              _logScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          });
        }
      }
    });
  }

  @override
  void dispose() {
    // Cancel subscriptions
    _audioLevelSubscription.cancel();
    _waveformSubscription.cancel();
    _speechSubscription.cancel();

    // Dispose controllers
    _logScrollController.dispose();

    // Dispose VAD service
    _vadService.dispose();

    super.dispose();
  }

  // Toggle recording state
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _vadService.stopRecording();
    } else {
      await _vadService.startRecording();
    }

    setState(() {
      _isRecording = _vadService.isRecording;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Package-based VAD'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.transcribe),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      TranscriptScreen(vadService: _vadService),
                ),
              );
            },
            tooltip: 'View Transcripts',
          ),
        ],
      ),
      body: Column(
        children: [
          // Current status indicator
          _buildStatusIndicator(),

          // Audio waveform
          _buildWaveform(),

          // Log viewer
          Expanded(child: _buildLogViewer()),

          // Audio segments list
          _buildAudioSegments(),

          // Bottom control panel
          _buildControlPanel(),
        ],
      ),
    );
  }

  // Status indicator showing if speech is being detected
  Widget _buildStatusIndicator() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _isSpeechDetected
          ? Colors.green.withOpacity(0.2)
          : Colors.grey.withOpacity(0.1),
      child: Row(
        children: [
          // Recording/VAD status icon
          Icon(
            _isSpeechDetected ? Icons.mic : Icons.mic_off,
            color: _isSpeechDetected ? Colors.green : Colors.grey,
            size: 24,
          ),
          const SizedBox(width: 8),

          // Status text
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isRecording
                      ? (_isSpeechDetected
                            ? 'Speech detected'
                            : 'Silence detected')
                      : 'Not recording',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _isRecording
                        ? (_isSpeechDetected ? Colors.green : Colors.grey)
                        : Colors.red,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Confidence: ${(_currentConfidence * 100).toStringAsFixed(1)}%',
                ),
              ],
            ),
          ),

          // Confidence meter
          SizedBox(
            width: 100,
            child: LinearProgressIndicator(
              value: _currentConfidence,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(
                _isSpeechDetected ? Colors.green : Colors.blue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Audio waveform visualization
  Widget _buildWaveform() {
    // Get performance configuration
    final config = WaveformConfig.getPerformanceConfig();

    return Container(
      height: 100,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: !_shouldUpdateWaveform
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.waves, size: 32, color: Colors.grey),
                  SizedBox(height: 8),
                  Text(
                    'Waveform disabled',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : _audioLevels.isEmpty
          ? const Center(child: Text('No audio data'))
          : EnhancedWaveform(
              samples: WaveformConfig.optimizeSamples(_normalizeWaveformData()),
              height: 80,
              width: MediaQuery.of(context).size.width - 32,
              activeColor: Colors.greenAccent,
              inactiveColor: Colors.blueAccent,
              isSpeechDetected: _isSpeechDetected,
              confidenceLevel: _currentConfidence,
              enableAnimation: config.enableAnimation,
              showGradient: config.enableGradient,
              showSmoothing: config.enableSmoothing,
            ),
    );
  }

  // Normalize audio levels for waveform visualization
  List<double> _normalizeWaveformData() {
    if (_audioLevels.isEmpty) return [];

    // Scale to 0.0-1.0 range for the waveform widget
    return _audioLevels.map((level) => level / 100.0).toList();
  }

  // Log viewer for VAD events
  Widget _buildLogViewer() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      margin: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'VAD Events Log',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _vadEvents.isEmpty
                ? const Center(child: Text('No VAD events yet'))
                : ListView.builder(
                    controller: _logScrollController,
                    itemCount: _vadEvents.length,
                    itemBuilder: (context, index) {
                      final event = _vadEvents[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${event.formattedTime} ${event.description}',
                          style: TextStyle(
                            color: event.isSpeech ? Colors.green : Colors.red,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // Audio segments list
  Widget _buildAudioSegments() {
    return Container(
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Detected Speech Segments (${_audioSegments.length})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 50,
            child: _audioSegments.isEmpty
                ? const Center(child: Text('No speech segments detected yet'))
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _audioSegments.length,
                    itemBuilder: (context, index) {
                      final segment = _audioSegments[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Chip(
                          label: Text(
                            'Segment ${index + 1} (${segment.formattedStartTime})',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // Bottom control panel
  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Performance controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Waveform toggle
              Column(
                children: [
                  Switch(
                    value: _shouldUpdateWaveform,
                    onChanged: (value) {
                      setState(() {
                        _shouldUpdateWaveform = value;
                      });
                    },
                  ),
                  const Text('Waveform', style: TextStyle(fontSize: 12)),
                ],
              ),

              // Performance info
              Column(
                children: [
                  Text(
                    'Confidence: ${_currentConfidence.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    'Frames: ${_vadService.totalFramesProcessed}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),

              // Speech ratio
              Column(
                children: [
                  Text(
                    'Speech: ${(_vadService.speechActivityRatio * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    'Avg Conf: ${_vadService.averageConfidence.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Recording control
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _toggleRecording,
                icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                label: Text(_isRecording ? 'Stop' : 'Start Recording'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRecording
                      ? Colors.red
                      : Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vad/vad.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

/// Model class to represent an audio segment detected by VAD
class AudioSegment {
  final String id;
  final String path;
  final DateTime startTime;
  final DateTime endTime;
  final double confidenceScore;
  final Duration duration;

  AudioSegment({
    required this.id,
    required this.path,
    required this.startTime,
    required this.endTime,
    required this.confidenceScore,
    required this.duration,
  });

  // Get formatted start time (seconds from recording start)
  String get formattedStartTime => '${duration.inMilliseconds / 1000}s';
}

/// Model class to represent a VAD event for logging
class VADEvent {
  final DateTime timestamp;
  final bool isSpeech;
  final double confidenceScore;
  final double timeFromStart;

  VADEvent({
    required this.timestamp,
    required this.isSpeech,
    required this.confidenceScore,
    required this.timeFromStart,
  });

  // Get formatted event description
  String get description => isSpeech
      ? 'Speech start (conf: ${confidenceScore.toStringAsFixed(2)})'
      : 'Speech end';

  // Get formatted timestamp
  String get formattedTime => '[${timeFromStart.toStringAsFixed(2)}s]';
}

/// Service class for Voice Activity Detection using the vad package
class PackageVadService extends ChangeNotifier {
  // VAD handler
  late final dynamic _vadHandler;

  // Record instance for recording to file (separate from VAD recording)
  final _record = AudioRecorder();

  // Lists to track audio data and events
  final List<double> _audioLevels = [];
  final List<VADEvent> _events = [];
  final List<AudioSegment> _segments = [];

  // Stream controllers
  final _audioLevelController = StreamController<double>.broadcast();
  final _waveformController = StreamController<List<double>>.broadcast();
  final _speechDetectedController = StreamController<bool>.broadcast();

  // Current state
  bool _isRecording = false;
  bool _isSpeechDetected = false;
  double _currentConfidence = 0.0;
  DateTime? _recordingStartTime;
  DateTime? _speechStartTime;
  String? _currentRecordingPath;
  Timer? _audioLevelTimer;

  // Getters
  bool get isRecording => _isRecording;
  bool get isSpeechDetected => _isSpeechDetected;
  double get currentConfidence => _currentConfidence;
  List<double> get audioLevels => List.unmodifiable(_audioLevels);
  List<VADEvent> get events => List.unmodifiable(_events);
  List<AudioSegment> get segments => List.unmodifiable(_segments);

  // Stream getters
  Stream<double> get audioLevelStream => _audioLevelController.stream;
  Stream<List<double>> get waveformStream => _waveformController.stream;
  Stream<bool> get speechDetectedStream => _speechDetectedController.stream;

  // Constructor
  PackageVadService() {
    _vadHandler = VadHandler.create(isDebug: true);
    _setupVADHandler();
  }

  // Setup VAD handler
  void _setupVADHandler() {
    try {
      // Set up VAD event listeners
      _vadHandler.onSpeechStart?.listen((_) {
        debugPrint('Speech detected.');

        // Calculate time from recording start
        double timeFromStart = 0.0;
        if (_recordingStartTime != null) {
          timeFromStart =
              DateTime.now().difference(_recordingStartTime!).inMilliseconds /
              1000;
        }

        // Start a new speech segment
        _startSpeechSegment(0.9, timeFromStart);

        // Update state
        _isSpeechDetected = true;
        _currentConfidence = 0.9; // VAD is confident enough to detect speech

        // Notify UI
        _speechDetectedController.add(true);
        notifyListeners();
      });

      _vadHandler.onRealSpeechStart?.listen((_) {
        debugPrint('Real speech start detected (not a misfire).');

        // Update confidence to maximum
        _currentConfidence = 1.0;
        notifyListeners();
      });

      _vadHandler.onSpeechEnd?.listen((samples) {
        debugPrint('Speech ended');

        // Calculate time from recording start
        double timeFromStart = 0.0;
        if (_recordingStartTime != null) {
          timeFromStart =
              DateTime.now().difference(_recordingStartTime!).inMilliseconds /
              1000;
        }

        // End speech segment
        _endSpeechSegment(timeFromStart: timeFromStart);

        // Update state
        _isSpeechDetected = false;
        _currentConfidence = 0.1; // Reset confidence when speech ends

        // Notify UI
        _speechDetectedController.add(false);
        notifyListeners();
      });

      _vadHandler.onFrameProcessed?.listen((frameData) {
        // Update confidence based on speech probability
        _currentConfidence = frameData.isSpeech;

        // Update audio levels for visualization
        final avgLevel = _calculateAudioLevel(frameData.frame);
        _updateAudioLevel(avgLevel);

        // Notify listeners of state changes
        notifyListeners();
      });

      _vadHandler.onVADMisfire?.listen((_) {
        debugPrint('VAD misfire detected.');

        // Add to events but don't change speech detection state
        _events.add(
          VADEvent(
            timestamp: DateTime.now(),
            isSpeech: false,
            confidenceScore: 0.3,
            timeFromStart:
                DateTime.now()
                    .difference(_recordingStartTime ?? DateTime.now())
                    .inMilliseconds /
                1000,
          ),
        );

        notifyListeners();
      });

      _vadHandler.onError?.listen((String message) {
        debugPrint('VAD Error: $message');
      });
    } catch (e) {
      debugPrint('Error setting up VAD handler: $e');
    }
  }

  // Calculate audio level from audio frame
  double _calculateAudioLevel(List<double> audioFrame) {
    if (audioFrame.isEmpty) return 0.0;

    // Calculate average amplitude
    double sum = 0.0;
    for (var sample in audioFrame) {
      sum += sample.abs();
    }

    // Normalize to 0-100 range for consistency with UI
    return (sum / audioFrame.length) * 100;
  }

  // Update audio level for visualization
  void _updateAudioLevel(double level) {
    // Add to audio levels list (keep last 100 values)
    _audioLevels.add(level);
    if (_audioLevels.length > 100) {
      _audioLevels.removeAt(0);
    }

    // Send to streams
    _audioLevelController.add(level);
    _waveformController.add(List.from(_audioLevels));
  }

  // Request necessary permissions
  Future<bool> requestPermissions() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  // Start recording with VAD detection
  Future<void> startRecording() async {
    if (_isRecording) return;

    // Check permissions first
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      debugPrint('No permission to record audio');
      return;
    }

    try {
      // Reset state
      _audioLevels.clear();
      _events.clear();
      _isSpeechDetected = false;
      _currentConfidence = 0.0;
      _recordingStartTime = DateTime.now();

      // Create a temporary recording file
      final tempDir = await getTemporaryDirectory();
      _currentRecordingPath =
          '${tempDir.path}/vad_recording_${_getCurrentFormattedDateTime()}.wav';

      final config = RecordConfig(
        encoder: AudioEncoder.wav,
        bitRate: 16000,
        sampleRate: 16000,
        numChannels: 1,
      );

      // Start recording to file
      await _record.start(config, path: _currentRecordingPath!);

      // Start VAD listening
      await _vadHandler.startListening(
        // Using latest V5 model for better accuracy
        model: 'v5',
        // For V5 model, frame samples should be 512 (32ms at 16kHz)
        frameSamples: 512,
        // Speech probability thresholds
        positiveSpeechThreshold: 0.5,
        negativeSpeechThreshold: 0.3,
        // More aggressive settings for better detection
        minSpeechFrames: 2,
      );

      // Update state
      _isRecording = true;
      notifyListeners();

      // Start audio level timer for backup if onFrameProcessed doesn't fire often enough
      _startAudioLevelTimer();

      debugPrint('Recording started with VAD');
    } catch (e) {
      debugPrint('Error starting recording with VAD: $e');
    }
  }

  // Start a timer to monitor audio levels in case frame processing is too slow
  void _startAudioLevelTimer() {
    _audioLevelTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (_audioLevels.isEmpty) {
        // If no levels yet, add a default low level
        _updateAudioLevel(10.0);
      }
    });
  }

  // Stop recording
  Future<void> stopRecording() async {
    if (!_isRecording) return;

    try {
      // Stop any active speech segment
      if (_isSpeechDetected) {
        _endSpeechSegment();
      }

      // Stop VAD listening
      await _vadHandler.stopListening();

      // Stop recording to file
      await _record.stop();

      // Stop audio level timer
      _audioLevelTimer?.cancel();

      // Update state
      _isRecording = false;
      notifyListeners();

      debugPrint(
        'Recording stopped, ${_segments.length} speech segments detected',
      );
    } catch (e) {
      debugPrint('Error stopping recording with VAD: $e');
    }
  }

  // Start a new speech segment
  void _startSpeechSegment(double confidence, double timeFromStart) {
    // Record start time
    _speechStartTime = DateTime.now();

    // Add event
    _events.add(
      VADEvent(
        timestamp: _speechStartTime!,
        isSpeech: true,
        confidenceScore: confidence,
        timeFromStart: timeFromStart,
      ),
    );

    debugPrint(
      'Speech segment started at ${timeFromStart.toStringAsFixed(2)}s with confidence ${confidence.toStringAsFixed(2)}',
    );
  }

  // End current speech segment and save it
  Future<void> _endSpeechSegment({double? timeFromStart}) async {
    if (_speechStartTime == null || _currentRecordingPath == null) return;

    final endTime = DateTime.now();
    final timeFrom =
        timeFromStart ??
        ((endTime.difference(_recordingStartTime!).inMilliseconds) / 1000);

    // Add end event
    _events.add(
      VADEvent(
        timestamp: endTime,
        isSpeech: false,
        confidenceScore: _currentConfidence,
        timeFromStart: timeFrom,
      ),
    );

    // Save segment (this would extract the audio segment in a real implementation)
    // For now, we'll simulate saving segments
    final segmentId = 'segment_${_segments.length + 1}';
    final segmentPath = '$_currentRecordingPath.$segmentId.wav';

    // Create a segment file from the recording
    try {
      final sourceFile = File(_currentRecordingPath!);
      if (await sourceFile.exists()) {
        // In a real implementation, we would extract the specific time segment
        // For now, just copy the whole file
        await sourceFile.copy(segmentPath);

        // Add to segments list
        _segments.add(
          AudioSegment(
            id: segmentId,
            path: segmentPath,
            startTime: _speechStartTime!,
            endTime: endTime,
            confidenceScore: _currentConfidence,
            duration: Duration(
              milliseconds: endTime
                  .difference(_recordingStartTime!)
                  .inMilliseconds,
            ),
          ),
        );

        debugPrint(
          'Speech segment ended at ${timeFrom.toStringAsFixed(2)}s and saved to $segmentPath',
        );
      }
    } catch (e) {
      debugPrint('Error saving speech segment: $e');
    }

    // Reset speech start time
    _speechStartTime = null;

    // Notify listeners
    notifyListeners();
  }

  // Get current date and time formatted
  String _getCurrentFormattedDateTime() {
    final now = DateTime.now();
    final formatter = DateFormat('yyyy-MM-dd_HH-mm-ss');
    return formatter.format(now);
  }

  // Clean up resources
  @override
  void dispose() {
    // Stop recording if active
    if (_isRecording) {
      stopRecording();
    }

    // Clean up
    _record.dispose();
    _audioLevelTimer?.cancel();
    _audioLevelController.close();
    _waveformController.close();
    _speechDetectedController.close();

    // Dispose of VAD handler
    _vadHandler.dispose();

    super.dispose();
  }
}

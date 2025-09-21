import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vad/vad.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'google_stt_service.dart';

/// Model class to represent an audio segment detected by VAD
class AudioSegment {
  final String id;
  final String path;
  final DateTime startTime;
  final DateTime endTime;
  final double confidenceScore;
  final Duration duration;

  // STT-related fields
  String? transcript;
  double? sttConfidence;
  DateTime? transcriptTime;
  bool? isProcessingSTT;

  AudioSegment({
    required this.id,
    required this.path,
    required this.startTime,
    required this.endTime,
    required this.confidenceScore,
    required this.duration,
    this.transcript,
    this.sttConfidence,
    this.transcriptTime,
    this.isProcessingSTT = false,
  });

  // Get formatted start time (seconds from recording start)
  String get formattedStartTime => '${duration.inMilliseconds / 1000}s';

  // STT helper methods
  bool get hasTranscript => transcript != null && transcript!.isNotEmpty;
  bool get isSTTProcessed => transcript != null;
  String get displayText => transcript ?? 'Processing...';

  // Update transcript info
  void updateTranscript(String newTranscript, double confidence) {
    transcript = newTranscript;
    sttConfidence = confidence;
    transcriptTime = DateTime.now();
    isProcessingSTT = false;
  }

  // Mark as processing STT
  void markProcessingSTT() {
    isProcessingSTT = true;
  }
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

  // Google STT service (optional)
  GoogleSTTService? _sttService;

  // Lists to track audio data and events
  final List<double> _audioLevels = [];
  final List<VADEvent> _events = [];
  final List<AudioSegment> _segments = [];

  // Stream controllers
  final _audioLevelController = StreamController<double>.broadcast();
  final _waveformController = StreamController<List<double>>.broadcast();
  final _speechDetectedController = StreamController<bool>.broadcast();
  final _transcriptionController = StreamController<String>.broadcast();

  // Current state
  bool _isRecording = false;
  bool _isSpeechDetected = false;
  double _currentConfidence = 0.0;
  DateTime? _recordingStartTime;
  DateTime? _speechStartTime;
  String? _currentRecordingPath;
  Timer? _audioLevelTimer;

  // Speech continuation tracking
  DateTime? _lastSpeechActivityTime;
  double _confidenceHistory = 0.0;
  int _consecutiveLowConfidenceFrames = 0;
  final int _maxLowConfidenceFrames =
      10; // Allow 10 low confidence frames before ending speech

  // Performance monitoring
  int _totalFramesProcessed = 0;
  int _speechFramesDetected = 0;
  DateTime? _lastPerformanceLog;

  // UI update throttling
  DateTime? _lastUIUpdate;
  final int _uiUpdateThrottleMs = 50; // Update UI max every 50ms
  double _lastReportedConfidence = 0.0;
  final double _confidenceChangeThreshold =
      0.05; // Only update if confidence changes by 5%

  // Getters
  bool get isRecording => _isRecording;
  bool get isSpeechDetected => _isSpeechDetected;
  double get currentConfidence => _currentConfidence;
  List<double> get audioLevels => List.unmodifiable(_audioLevels);
  List<VADEvent> get events => List.unmodifiable(_events);
  List<AudioSegment> get segments => List.unmodifiable(_segments);

  // Performance metrics getters
  double get averageConfidence => _confidenceHistory;
  double get speechActivityRatio => _totalFramesProcessed > 0
      ? _speechFramesDetected / _totalFramesProcessed
      : 0.0;
  int get totalFramesProcessed => _totalFramesProcessed;

  // Stream getters
  Stream<double> get audioLevelStream => _audioLevelController.stream;
  Stream<List<double>> get waveformStream => _waveformController.stream;
  Stream<bool> get speechDetectedStream => _speechDetectedController.stream;
  Stream<String> get transcriptionStream => _transcriptionController.stream;

  // Constructor
  PackageVadService({GoogleSTTService? sttService}) {
    _sttService = sttService;
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

        // Use actual confidence from VAD model instead of hardcoded value
        double confidence = _currentConfidence > 0.0 ? _currentConfidence : 0.8;

        // Start a new speech segment
        _startSpeechSegment(confidence, timeFromStart);

        // Update state
        _isSpeechDetected = true;

        // Don't override confidence if we already have a good value from frameData
        if (_currentConfidence < 0.5) {
          _currentConfidence = confidence;
        }

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
        // Update confidence based on actual speech probability from VAD model
        _currentConfidence = frameData.speechProbability ?? frameData.isSpeech;

        // Track speech activity for adaptive detection
        _updateSpeechTracking(_currentConfidence);

        // Update audio levels for visualization
        final avgLevel = _calculateAudioLevel(frameData.frame);
        _updateAudioLevel(avgLevel);

        // Throttle UI updates to avoid excessive notifyListeners calls
        final now = DateTime.now();
        final confidenceChanged =
            (_currentConfidence - _lastReportedConfidence).abs() >=
            _confidenceChangeThreshold;

        if (_lastUIUpdate == null ||
            now.difference(_lastUIUpdate!).inMilliseconds >=
                _uiUpdateThrottleMs ||
            confidenceChanged) {
          _lastUIUpdate = now;
          _lastReportedConfidence = _currentConfidence;
          notifyListeners();
        }
      });

      _vadHandler.onVADMisfire?.listen((_) {
        debugPrint('VAD misfire detected.');
        // Note: Not adding to events list to avoid double logging
        // VAD misfires are handled internally and don't need to be tracked as events
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

    // Calculate RMS (Root Mean Square) for better level representation
    double sumOfSquares = 0.0;
    for (var sample in audioFrame) {
      sumOfSquares += sample * sample;
    }

    double rms = math.sqrt(sumOfSquares / audioFrame.length);

    // Apply logarithmic scaling for better visualization
    double dbLevel = 20 * math.log(rms + 1e-10) / math.ln10;

    // Normalize to 0-100 range, assuming -60dB to 0dB range
    double normalizedLevel = ((dbLevel + 60) / 60 * 100).clamp(0.0, 100.0);

    return normalizedLevel;
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

  // Track speech activity for adaptive detection
  void _updateSpeechTracking(double confidence) {
    // Performance monitoring
    _totalFramesProcessed++;
    if (confidence > 0.5) {
      _speechFramesDetected++;
    }

    // Log performance every 5 seconds
    final now = DateTime.now();
    if (_lastPerformanceLog == null ||
        now.difference(_lastPerformanceLog!).inSeconds >= 5) {
      _lastPerformanceLog = now;
      final speechRatio = _totalFramesProcessed > 0
          ? (_speechFramesDetected / _totalFramesProcessed * 100)
                .toStringAsFixed(1)
          : '0.0';

      // Only log if we have significant activity (avoid spam during silence)
      if (_totalFramesProcessed > 50) {
        // At least ~1.6 seconds of processing
        debugPrint(
          'VAD Performance: ${_totalFramesProcessed} frames, ${speechRatio}% speech, avg confidence: ${_confidenceHistory.toStringAsFixed(2)}',
        );
      }
    }

    // Update confidence history with smoothing
    _confidenceHistory = (_confidenceHistory * 0.8) + (confidence * 0.2);

    // Track speech activity timing
    if (confidence > 0.3) {
      // Consider as speech activity
      _lastSpeechActivityTime = DateTime.now();
      _consecutiveLowConfidenceFrames = 0;
    } else {
      _consecutiveLowConfidenceFrames++;
    }

    // Check if we should extend speech detection
    if (_isSpeechDetected && confidence < 0.2) {
      // If we're in speech but confidence is very low
      if (_consecutiveLowConfidenceFrames > _maxLowConfidenceFrames) {
        // Too many low confidence frames, but check recent activity
        final timeSinceLastActivity = _lastSpeechActivityTime != null
            ? DateTime.now().difference(_lastSpeechActivityTime!).inMilliseconds
            : 1000;

        // If recent activity (within 500ms), keep speech active
        if (timeSinceLastActivity < 500) {
          debugPrint('Extending speech detection due to recent activity');
          _consecutiveLowConfidenceFrames = 0; // Reset counter
        }
      }
    }
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

      // Reset performance monitoring
      _totalFramesProcessed = 0;
      _speechFramesDetected = 0;
      _lastPerformanceLog = null;
      _confidenceHistory = 0.0;
      _consecutiveLowConfidenceFrames = 0;

      // Reset UI throttling
      _lastUIUpdate = null;
      _lastReportedConfidence = 0.0;

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
        // Speech probability thresholds - made more sensitive for longer segments
        positiveSpeechThreshold: 0.4, // Lowered from 0.5 for better sensitivity
        negativeSpeechThreshold: 0.2, // Lowered from 0.3 for longer detection
        // More conservative settings for longer speech detection
        minSpeechFrames: 1, // Reduced from 2 for faster detection
        // Add padding and redemption frames for longer segments
        preSpeechPadFrames: 2, // Add frames before speech start
        redemptionFrames:
            8, // Increased from default (3) to avoid cutting off speech
        // Don't submit on pause to handle longer segments
        submitUserSpeechOnPause: false,
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
        final audioSegment = AudioSegment(
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
        );

        _segments.add(audioSegment);

        debugPrint(
          'Speech segment ended at ${timeFrom.toStringAsFixed(2)}s and saved to $segmentPath',
        );

        // Process with STT if service is available
        if (_sttService != null) {
          _processSegmentWithSTT(audioSegment);
        }
      }
    } catch (e) {
      debugPrint('Error saving speech segment: $e');
    }

    // Reset speech start time
    _speechStartTime = null;

    // Notify listeners
    notifyListeners();
  }

  // Process audio segment with Google STT
  Future<void> _processSegmentWithSTT(AudioSegment segment) async {
    if (_sttService == null) return;

    try {
      // Mark segment as processing
      segment.markProcessingSTT();

      debugPrint('Processing segment ${segment.id} with Google STT...');

      // Send to Google STT API
      final sttResult = await _sttService!.transcribeAudioSegment(segment.path);

      if (sttResult != null) {
        // Update segment with transcript
        segment.updateTranscript(sttResult.transcript, sttResult.confidence);

        debugPrint(
          'STT Result for ${segment.id}: "${sttResult.transcript}" (confidence: ${sttResult.confidence})',
        );

        // Emit transcript to stream if not empty
        if (sttResult.hasText) {
          _transcriptionController.add(sttResult.transcript);
        }

        // Notify UI of segment update
        notifyListeners();
      } else {
        // Mark as processed with empty result
        segment.updateTranscript('', 0.0);
        debugPrint('STT failed for segment ${segment.id}');
      }
    } catch (e) {
      debugPrint('Error processing segment ${segment.id} with STT: $e');
      segment.updateTranscript('Error', 0.0);
    }
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
    _transcriptionController.close();

    // Dispose of VAD handler
    _vadHandler.dispose();

    super.dispose();
  }
}

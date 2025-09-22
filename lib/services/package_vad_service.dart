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

  // Update transcript info - made safe for UI updates
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

  // Google STT service (optional) - với queue để tránh blocking
  GoogleSTTService? _sttService;
  final List<AudioSegment> _sttQueue = [];
  bool _isProcessingSTT = false;

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
  final int _maxLowConfidenceFrames = 10;

  // Performance monitoring
  int _totalFramesProcessed = 0;
  int _speechFramesDetected = 0;
  DateTime? _lastPerformanceLog;

  // UI update throttling - Tối ưu hóa để tránh UI blocking
  DateTime? _lastUIUpdate;
  final int _uiUpdateThrottleMs = 100; // Tăng lên 100ms để giảm tải UI
  double _lastReportedConfidence = 0.0;
  final double _confidenceChangeThreshold =
      0.1; // Tăng threshold để giảm cập nhật

  // Batch update để tránh quá nhiều notifyListeners
  Timer? _batchUpdateTimer;
  bool _hasPendingUpdate = false;

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
    _vadHandler = VadHandler.create(isDebug: false); // Tắt debug để giảm tải
    _setupVADHandler();
    _startBatchUpdateTimer();
  }

  // Batch update timer để giảm số lần gọi notifyListeners
  void _startBatchUpdateTimer() {
    _batchUpdateTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_hasPendingUpdate) {
        _hasPendingUpdate = false;
        notifyListeners();
      }
    });
  }

  // Schedule a batched UI update
  void _scheduleUIUpdate() {
    _hasPendingUpdate = true;
  }

  // Setup VAD handler với tối ưu hóa
  void _setupVADHandler() {
    try {
      // Set up VAD event listeners
      _vadHandler.onSpeechStart?.listen((_) {
        if (kDebugMode) {
          debugPrint('Speech detected.');
        }

        // Calculate time from recording start
        double timeFromStart = 0.0;
        if (_recordingStartTime != null) {
          timeFromStart =
              DateTime.now().difference(_recordingStartTime!).inMilliseconds /
              1000;
        }

        double confidence = _currentConfidence > 0.0 ? _currentConfidence : 0.8;
        _startSpeechSegment(confidence, timeFromStart);

        _isSpeechDetected = true;
        if (_currentConfidence < 0.5) {
          _currentConfidence = confidence;
        }

        // Async stream updates để không block UI
        _speechDetectedController.add(true);
        _scheduleUIUpdate();
      });

      _vadHandler.onRealSpeechStart?.listen((_) {
        if (kDebugMode) {
          debugPrint('Real speech start detected.');
        }
        _scheduleUIUpdate();
      });

      _vadHandler.onSpeechEnd?.listen((samples) async {
        if (kDebugMode) {
          debugPrint('Speech ended');
        }

        double timeFromStart = 0.0;
        if (_recordingStartTime != null) {
          timeFromStart =
              DateTime.now().difference(_recordingStartTime!).inMilliseconds /
              1000;
        }

        // End speech segment - chạy async để không block UI
        unawaited(_endSpeechSegment(timeFromStart: timeFromStart));

        _isSpeechDetected = false;
        _speechDetectedController.add(false);
        _scheduleUIUpdate();
      });

      _vadHandler.onFrameProcessed?.listen((frameData) {
        _currentConfidence = frameData.isSpeech;
        _updateSpeechTracking(_currentConfidence);

        final avgLevel = _calculateAudioLevel(frameData.frame);
        _updateAudioLevel(avgLevel);

        // Throttled UI updates với cải tiến
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
          _scheduleUIUpdate();
        }
      });

      _vadHandler.onVADMisfire?.listen((_) {
        if (kDebugMode) {
          debugPrint('VAD misfire detected.');
        }
      });

      _vadHandler.onError?.listen((String message) {
        if (kDebugMode) {
          debugPrint('VAD Error: $message');
        }
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error setting up VAD handler: $e');
      }
    }
  }

  // Calculate audio level from audio frame - Tối ưu hóa
  double _calculateAudioLevel(List<double> audioFrame) {
    if (audioFrame.isEmpty) return 0.0;

    // Sử dụng sample để tính toán nhanh hơn với audio frame lớn
    final sampleSize = audioFrame.length > 100 ? 100 : audioFrame.length;
    final step = audioFrame.length ~/ sampleSize;

    double sumOfSquares = 0.0;
    for (int i = 0; i < audioFrame.length; i += step) {
      final sample = audioFrame[i];
      sumOfSquares += sample * sample;
    }

    final samplesUsed = (audioFrame.length / step).ceil();
    double rms = math.sqrt(sumOfSquares / samplesUsed);
    double dbLevel = 20 * math.log(rms + 1e-10) / math.ln10;
    double normalizedLevel = ((dbLevel + 60) / 60 * 100).clamp(0.0, 100.0);

    return normalizedLevel;
  }

  // Update audio level for visualization - Tối ưu hóa
  void _updateAudioLevel(double level) {
    _audioLevels.add(level);
    if (_audioLevels.length > 50) {
      // Giảm buffer size từ 100 xuống 50
      _audioLevels.removeAt(0);
    }

    // Async stream updates
    _audioLevelController.add(level);
    _waveformController.add(List.from(_audioLevels));
  }

  // Track speech activity for adaptive detection
  void _updateSpeechTracking(double confidence) {
    _totalFramesProcessed++;
    if (confidence > 0.5) {
      _speechFramesDetected++;
    }

    // Giảm tần suất log performance
    final now = DateTime.now();
    if (_lastPerformanceLog == null ||
        now.difference(_lastPerformanceLog!).inSeconds >= 10) {
      // Tăng từ 5s lên 10s
      _lastPerformanceLog = now;
      if (_totalFramesProcessed > 100 && kDebugMode) {
        final speechRatio =
            (_speechFramesDetected / _totalFramesProcessed * 100)
                .toStringAsFixed(1);
        debugPrint(
          'VAD Performance: ${_totalFramesProcessed} frames, ${speechRatio}% speech',
        );
      }
    }

    _confidenceHistory = (_confidenceHistory * 0.8) + (confidence * 0.2);

    if (confidence > 0.3) {
      _lastSpeechActivityTime = DateTime.now();
      _consecutiveLowConfidenceFrames = 0;
    } else {
      _consecutiveLowConfidenceFrames++;
    }

    if (_isSpeechDetected && confidence < 0.2) {
      if (_consecutiveLowConfidenceFrames > _maxLowConfidenceFrames) {
        final timeSinceLastActivity = _lastSpeechActivityTime != null
            ? DateTime.now().difference(_lastSpeechActivityTime!).inMilliseconds
            : 1000;

        if (timeSinceLastActivity < 500) {
          if (kDebugMode) {
            debugPrint('Extending speech detection due to recent activity');
          }
          _consecutiveLowConfidenceFrames = 0;
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

    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      if (kDebugMode) {
        debugPrint('No permission to record audio');
      }
      return;
    }

    try {
      // Reset state
      _audioLevels.clear();
      _events.clear();
      _segments.clear(); // Clear previous segments
      _sttQueue.clear(); // Clear STT queue
      _isSpeechDetected = false;
      _currentConfidence = 0.0;
      _recordingStartTime = DateTime.now();

      // Reset performance monitoring
      _totalFramesProcessed = 0;
      _speechFramesDetected = 0;
      _lastPerformanceLog = null;
      _confidenceHistory = 0.0;
      _consecutiveLowConfidenceFrames = 0;
      _lastUIUpdate = null;
      _lastReportedConfidence = 0.0;

      final tempDir = await getTemporaryDirectory();
      _currentRecordingPath =
          '${tempDir.path}/vad_recording_${_getCurrentFormattedDateTime()}.wav';

      final config = RecordConfig(
        encoder: AudioEncoder.wav,
        bitRate: 16000,
        sampleRate: 16000,
        numChannels: 1,
      );

      await _record.start(config, path: _currentRecordingPath!);

      // Tối ưu VAD settings
      await _vadHandler.startListening(
        model: 'v5',
        frameSamples: 512,
        positiveSpeechThreshold: 0.4,
        negativeSpeechThreshold: 0.2,
        minSpeechFrames: 1,
        preSpeechPadFrames: 2,
        redemptionFrames: 8,
        submitUserSpeechOnPause: false,
      );

      _isRecording = true;
      _scheduleUIUpdate();
      _startAudioLevelTimer();

      if (kDebugMode) {
        debugPrint('Recording started with VAD');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error starting recording with VAD: $e');
      }
    }
  }

  void _startAudioLevelTimer() {
    _audioLevelTimer = Timer.periodic(const Duration(milliseconds: 200), (
      timer,
    ) {
      if (_audioLevels.isEmpty) {
        _updateAudioLevel(10.0);
      }
    });
  }

  // Stop recording
  Future<void> stopRecording() async {
    if (!_isRecording) return;

    try {
      if (_isSpeechDetected) {
        await _endSpeechSegment();
      }

      await _vadHandler.stopListening();
      await _record.stop();
      _audioLevelTimer?.cancel();

      _isRecording = false;
      _scheduleUIUpdate();

      if (kDebugMode) {
        debugPrint(
          'Recording stopped, ${_segments.length} speech segments detected',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error stopping recording with VAD: $e');
      }
    }
  }

  // Start a new speech segment
  void _startSpeechSegment(double confidence, double timeFromStart) {
    _speechStartTime = DateTime.now();

    _events.add(
      VADEvent(
        timestamp: _speechStartTime!,
        isSpeech: true,
        confidenceScore: confidence,
        timeFromStart: timeFromStart,
      ),
    );

    if (kDebugMode) {
      debugPrint(
        'Speech segment started at ${timeFromStart.toStringAsFixed(2)}s',
      );
    }
  }

  // End current speech segment and save it - ASYNC để không block UI
  Future<void> _endSpeechSegment({double? timeFromStart}) async {
    if (_speechStartTime == null || _currentRecordingPath == null) return;

    final endTime = DateTime.now();
    final timeFrom =
        timeFromStart ??
        ((endTime.difference(_recordingStartTime!).inMilliseconds) / 1000);

    _events.add(
      VADEvent(
        timestamp: endTime,
        isSpeech: false,
        confidenceScore: _currentConfidence,
        timeFromStart: timeFrom,
      ),
    );

    // Chạy segment saving trong background
    unawaited(_saveSegmentAsync(endTime, timeFrom));

    _speechStartTime = null;
    _scheduleUIUpdate();
  }

  // Async segment saving để không block UI
  Future<void> _saveSegmentAsync(DateTime endTime, double timeFrom) async {
    final segmentId = 'segment_${_segments.length + 1}';
    final segmentPath = '$_currentRecordingPath.$segmentId.wav';

    try {
      final sourceFile = File(_currentRecordingPath!);
      if (await sourceFile.exists()) {
        await sourceFile.copy(segmentPath);

        final audioSegment = AudioSegment(
          id: segmentId,
          path: segmentPath,
          startTime: _speechStartTime ?? DateTime.now(),
          endTime: endTime,
          confidenceScore: _currentConfidence,
          duration: Duration(
            milliseconds: endTime
                .difference(_recordingStartTime!)
                .inMilliseconds,
          ),
        );

        _segments.add(audioSegment);

        if (kDebugMode) {
          debugPrint('Speech segment saved: $segmentId');
        }

        // Queue for STT processing - không block UI
        if (_sttService != null) {
          _queueSTTProcessing(audioSegment);
        }

        _scheduleUIUpdate();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error saving speech segment: $e');
      }
    }
  }

  // Queue STT processing để tránh block UI
  void _queueSTTProcessing(AudioSegment segment) {
    _sttQueue.add(segment);
    _processSTTQueue();
  }

  // Process STT queue một cách bất đồng bộ
  Future<void> _processSTTQueue() async {
    if (_isProcessingSTT || _sttQueue.isEmpty || _sttService == null) return;

    _isProcessingSTT = true;

    while (_sttQueue.isNotEmpty) {
      final segment = _sttQueue.removeAt(0);
      await _processSegmentWithSTT(segment);

      // Tạm dừng ngắn để không block UI thread
      await Future.delayed(const Duration(milliseconds: 10));
    }

    _isProcessingSTT = false;
  }

  // Process audio segment with Google STT - Tối ưu hóa
  Future<void> _processSegmentWithSTT(AudioSegment segment) async {
    if (_sttService == null) return;

    try {
      segment.markProcessingSTT();
      _scheduleUIUpdate(); // Update UI ngay khi bắt đầu processing

      if (kDebugMode) {
        debugPrint('Processing segment ${segment.id} with Google STT...');
      }

      // Gọi STT API trong compute isolate để không block UI
      final sttResult = await _sttService!.transcribeAudioSegment(segment.path);

      if (sttResult != null) {
        segment.updateTranscript(sttResult.transcript, sttResult.confidence);

        if (kDebugMode) {
          debugPrint('STT Result for ${segment.id}: "${sttResult.transcript}"');
        }

        if (sttResult.hasText) {
          _transcriptionController.add(sttResult.transcript);
        }
      } else {
        segment.updateTranscript('', 0.0);
        if (kDebugMode) {
          debugPrint('STT failed for segment ${segment.id}');
        }
      }

      _scheduleUIUpdate();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error processing segment ${segment.id} with STT: $e');
      }
      segment.updateTranscript('Error', 0.0);
      _scheduleUIUpdate();
    }
  }

  String _getCurrentFormattedDateTime() {
    final now = DateTime.now();
    final formatter = DateFormat('yyyy-MM-dd_HH-mm-ss');
    return formatter.format(now);
  }

  @override
  void dispose() {
    if (_isRecording) {
      unawaited(stopRecording());
    }

    _batchUpdateTimer?.cancel();
    _record.dispose();
    _audioLevelTimer?.cancel();
    _audioLevelController.close();
    _waveformController.close();
    _speechDetectedController.close();
    _transcriptionController.close();
    _vadHandler.dispose();

    super.dispose();
  }
}

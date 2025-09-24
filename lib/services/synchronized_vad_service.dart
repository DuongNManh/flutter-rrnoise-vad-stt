import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_google_stt/models/audio_frame_buffer.dart';
import 'package:flutter_google_stt/models/speech_segment.dart';
import 'package:vad/vad.dart';
import 'package:permission_handler/permission_handler.dart';
import 'google_stt_service.dart';

class SynchronizedVADService extends ChangeNotifier {
  late final dynamic _vadHandler;
  final AudioFrameBuffer _frameBuffer = AudioFrameBuffer();
  final GoogleSTTService? _sttService;

  // State management
  bool _isRecording = false;
  bool _isSpeechActive = false;
  double _currentConfidence = 0.0;

  // Precise timing tracking
  DateTime? _speechStartTime;
  DateTime? _realSpeechStartTime; // Actual frame timestamp when speech started
  Timer? _speechEndTimer;

  // Speech segments
  final List<SpeechSegment> _speechSegments = [];
  final List<SpeechSegment> _sttQueue = [];
  bool _isProcessingSTT = false;

  // Streams
  final _confidenceController = StreamController<double>.broadcast();
  final _speechStateController = StreamController<bool>.broadcast();
  final _transcriptController = StreamController<SpeechSegment>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();

  // Batch updates
  Timer? _batchUpdateTimer;
  bool _hasPendingUIUpdate = false;

  // Configuration
  static const Duration _speechEndDelay = Duration(milliseconds: 1500);
  static const Duration _preBufferPadding = Duration(milliseconds: 300);
  static const Duration _postBufferPadding = Duration(milliseconds: 500);

  SynchronizedVADService({GoogleSTTService? sttService})
    : _sttService = sttService {
    _vadHandler = VadHandler.create(isDebug: false);
    _setupVADHandler();
    _startBatchUpdateTimer();
  }

  // Protected getters for subclasses
  @protected
  AudioFrameBuffer get frameBuffer => _frameBuffer;
  @protected
  GoogleSTTService? get sttService => _sttService;
  @protected
  List<SpeechSegment> get speechSegmentsList => _speechSegments;
  @protected
  StreamController<SpeechSegment> get transcriptController =>
      _transcriptController;
  @protected
  StreamController<bool> get speechStateController => _speechStateController;
  @protected
  DateTime? get realSpeechStartTime => _realSpeechStartTime;
  @protected
  set realSpeechStartTime(DateTime? value) => _realSpeechStartTime = value;
  @protected
  DateTime? get speechStartTime => _speechStartTime;
  @protected
  set speechStartTime(DateTime? value) => _speechStartTime = value;
  @protected
  Duration get postBufferPadding => _postBufferPadding;

  // Public getters
  bool get isRecording => _isRecording;
  bool get isSpeechActive => _isSpeechActive;
  double get currentConfidence => _currentConfidence;
  List<SpeechSegment> get speechSegments => List.unmodifiable(_speechSegments);
  Duration get availableBufferDuration => _frameBuffer.availableDuration;

  // Streams
  Stream<double> get confidenceStream => _confidenceController.stream;
  Stream<bool> get speechStateStream => _speechStateController.stream;
  Stream<SpeechSegment> get transcriptStream => _transcriptController.stream;
  Stream<double> get audioLevelStream => _audioLevelController.stream;

  void _setupVADHandler() {
    _vadHandler.onSpeechStart?.listen((_) => _onSpeechStart());
    _vadHandler.onSpeechEnd?.listen((_) => _onSpeechEnd());
    _vadHandler.onFrameProcessed?.listen(
      (frameData) => _onFrameProcessed(frameData),
    );
    _vadHandler.onError?.listen((error) => debugPrint('VAD Error: $error'));
  }

  void _onSpeechStart() {
    if (!_isRecording) return;

    // Nếu trước đó có segment end đang chờ finalize thì finalize luôn
    if (_speechStartTime != null && !_isSpeechActive) {
      _finalizeSpeechSegment();
    }

    _speechEndTimer?.cancel();
    _isSpeechActive = true;

    final now = DateTime.now();
    _speechStartTime = now;
    _realSpeechStartTime = now.subtract(_preBufferPadding);

    _speechStateController.add(true);
    _scheduleUIUpdate();
  }

  void _onSpeechEnd() {
    if (!_isRecording || !_isSpeechActive) return;

    _speechEndTimer?.cancel();

    _speechEndTimer = Timer(_speechEndDelay, () {
      _finalizeSpeechSegment();
    });

    _isSpeechActive = false;
    _speechStateController.add(false);
    _scheduleUIUpdate();
  }

  void _onFrameProcessed(frameData) {
    if (!_isRecording) return;

    final now = DateTime.now();
    _currentConfidence = frameData.isSpeech;

    // Store frame with precise timestamp
    _frameBuffer.addFrame(frameData.frame, now);

    // Calculate audio level
    final audioLevel = _calculateAudioLevel(frameData.frame);
    _audioLevelController.add(audioLevel);
    _confidenceController.add(_currentConfidence);

    _scheduleUIUpdate();
  }

  double _calculateAudioLevel(List<double> frame) {
    if (frame.isEmpty) return 0.0;

    double sumOfSquares = 0.0;
    for (final sample in frame) {
      sumOfSquares += sample * sample;
    }

    final rms = (sumOfSquares / frame.length).abs();
    final dbLevel = 20 * (rms > 0 ? rms.sign : -100) / 2.302585; // ln(10)
    return ((dbLevel + 60) / 60 * 100).clamp(0.0, 100.0);
  }

  Future<bool> startRecording() async {
    if (_isRecording) return true;

    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      debugPrint('Microphone permission denied');
      return false;
    }

    try {
      // Clear previous data
      _frameBuffer.clear();
      _speechSegments.clear();
      _sttQueue.clear();
      _isProcessingSTT = false;
      _currentConfidence = 0.0;
      _isSpeechActive = false;
      _speechStartTime = null;
      _realSpeechStartTime = null;

      // Start VAD with optimized settings for short utterances
      await _vadHandler.startListening(
        model: 'v5',
        frameSamples: 512, // ~32ms frames
        positiveSpeechThreshold: 0.5,
        negativeSpeechThreshold: 0.35,
        minSpeechFrames: 3,
        preSpeechPadFrames: 8, // ~256ms pre-speech padding
        redemptionFrames: 20, // ~384ms post-speech padding
        submitUserSpeechOnPause: false,
      );

      _isRecording = true;
      _scheduleUIUpdate();

      if (kDebugMode) {
        debugPrint('Synchronized VAD Service started');
      }

      return true;
    } catch (e) {
      debugPrint('Error starting synchronized VAD service: $e');
      return false;
    }
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;

    try {
      _speechEndTimer?.cancel();

      if (_isSpeechActive) {
        await _finalizeSpeechSegment();
      }

      await _vadHandler.stopListening();
      _isRecording = false;
      _scheduleUIUpdate();

      if (kDebugMode) {
        debugPrint(
          'Synchronized VAD Service stopped. Segments: ${_speechSegments.length}',
        );
      }
    } catch (e) {
      debugPrint('Error stopping VAD service: $e');
    }
  }

  Future<void> _finalizeSpeechSegment() async {
    if (_realSpeechStartTime == null) return;

    final endTime = DateTime.now().add(_postBufferPadding);
    final segmentId = 'segment_${DateTime.now().microsecondsSinceEpoch}';
    final duration = endTime.difference(_realSpeechStartTime!);

    try {
      final audioData = _frameBuffer.extractAudioBetween(
        _realSpeechStartTime!,
        endTime,
      );

      // Luôn tạo segment, kể cả khi audioData null/nhỏ
      final segment = SpeechSegment(
        id: segmentId,
        startTime: _realSpeechStartTime!,
        endTime: endTime,
        confidence: _currentConfidence,
        audioData: audioData,
      );

      _speechSegments.add(segment);

      if (audioData == null || audioData.length <= 44) {
        // Segment không đủ dữ liệu
        segment.updateTranscript('', 0.0);
        debugPrint(
          '⚠️ Created EMPTY segment: ${duration.inMilliseconds}ms (no audio data)',
        );
      } else {
        debugPrint(
          '✅ Created speech segment: ${audioData.length} bytes, ${duration.inMilliseconds}ms',
        );

        // Queue STT processing nếu có audio
        if (_sttService != null) {
          _queueSTTProcessing(segment);
        }
      }

      _scheduleUIUpdate();
    } catch (e) {
      debugPrint('Error finalizing speech segment: $e');
    } finally {
      _speechStartTime = null;
      _realSpeechStartTime = null;
    }
  }

  void _queueSTTProcessing(SpeechSegment segment) {
    _sttQueue.add(segment);
    _processSTTQueue();
  }

  Future<void> _processSTTQueue() async {
    if (_isProcessingSTT || _sttQueue.isEmpty || _sttService == null) return;

    _isProcessingSTT = true;

    while (_sttQueue.isNotEmpty) {
      final segment = _sttQueue.removeAt(0);
      await _processSegmentWithSTT(segment);
      await Future.delayed(const Duration(milliseconds: 10));
    }

    _isProcessingSTT = false;
  }

  Future<void> _processSegmentWithSTT(SpeechSegment segment) async {
    if (_sttService == null || segment.audioData == null) return;

    try {
      segment.markProcessing();
      _scheduleUIUpdate();

      if (kDebugMode) {
        debugPrint(
          'Processing segment ${segment.id} with STT: ${segment.audioData!.length} bytes',
        );
      }

      final sttResult = await _sttService.transcribeAudioBuffer(
        segment.audioData!,
        debugName: segment.id,
      );

      if (sttResult != null && sttResult.hasText) {
        segment.updateTranscript(sttResult.transcript, sttResult.confidence);
        _transcriptController.add(segment);

        if (kDebugMode) {
          debugPrint(
            'STT SUCCESS: "${sttResult.transcript}" (conf: ${sttResult.confidence.toStringAsFixed(2)})',
          );
        }
      } else {
        segment.updateTranscript('', 0.0);
        if (kDebugMode) {
          debugPrint('STT no result for segment ${segment.id}');
        }
      }

      _scheduleUIUpdate();
    } catch (e) {
      debugPrint('Error processing segment ${segment.id}: $e');
      segment.updateTranscript('Error', 0.0);
      _scheduleUIUpdate();
    }
  }

  void _startBatchUpdateTimer() {
    _batchUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_hasPendingUIUpdate) {
        _hasPendingUIUpdate = false;
        notifyListeners();
      }
    });
  }

  void _scheduleUIUpdate() {
    _hasPendingUIUpdate = true;
  }

  // Protected methods for subclasses
  @protected
  void queueSTTProcessing(SpeechSegment segment) {
    _queueSTTProcessing(segment);
  }

  @protected
  void scheduleUIUpdate() {
    _scheduleUIUpdate();
  }

  String getFullTranscript() {
    return _speechSegments
        .where((segment) => segment.hasTranscript)
        .map((segment) => segment.transcript)
        .join(' ')
        .trim();
  }

  void clearAll() {
    _speechSegments.clear();
    _sttQueue.clear();
    _frameBuffer.clear();
    _isProcessingSTT = false;
    _currentConfidence = 0.0;
    _isSpeechActive = false;
    _speechStartTime = null;
    _realSpeechStartTime = null;
    _speechEndTimer?.cancel();

    _scheduleUIUpdate();

    if (kDebugMode) {
      debugPrint('All data cleared');
    }
  }

  // Thêm phương thức để cập nhật ngôn ngữ
  void updateLanguageSettings(
    String mainLanguage,
    List<String> alternativeLanguages,
  ) {
    if (_sttService != null) {
      _sttService.setLanguages(mainLanguage, alternativeLanguages);
      _scheduleUIUpdate();
    }
  }

  @override
  void dispose() {
    if (_isRecording) {
      stopRecording();
    }

    _speechEndTimer?.cancel();
    _batchUpdateTimer?.cancel();
    _confidenceController.close();
    _speechStateController.close();
    _transcriptController.close();
    _audioLevelController.close();
    _vadHandler.dispose();

    super.dispose();
  }
}

import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_google_stt/services/audio_buffer_manager.dart';
import 'package:vad/vad.dart';
import 'package:permission_handler/permission_handler.dart';
import 'google_stt_service.dart';

/// Ring buffer for precise audio frame timing
class AudioFrameBuffer {
  final Queue<AudioFrame> _frames = Queue<AudioFrame>();
  final int _maxFrames = 1000; // ~32 seconds at 512 samples/frame, 16kHz
  static const int _sampleRate = 16000;
  static const int _bytesPerSample = 2;

  void addFrame(List<double> audioData, DateTime timestamp) {
    final frame = AudioFrame(data: List.from(audioData), timestamp: timestamp);

    _frames.addLast(frame);

    // Maintain buffer size
    while (_frames.length > _maxFrames) {
      _frames.removeFirst();
    }
  }

  /// Extract audio data between specific timestamps
  Uint8List? extractAudioBetween(DateTime startTime, DateTime endTime) {
    if (_frames.isEmpty) return null;

    // Find frames within time range with tolerance
    final tolerance = Duration(milliseconds: 50);
    final adjustedStart = startTime.subtract(tolerance);
    final adjustedEnd = endTime.add(tolerance);

    final matchingFrames = _frames.where((frame) {
      return frame.timestamp.isAfter(adjustedStart) &&
          frame.timestamp.isBefore(adjustedEnd);
    }).toList();

    if (matchingFrames.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'No frames found in time range: ${startTime.millisecondsSinceEpoch} - ${endTime.millisecondsSinceEpoch}',
        );
        debugPrint(
          'Available range: ${_frames.first.timestamp.millisecondsSinceEpoch} - ${_frames.last.timestamp.millisecondsSinceEpoch}',
        );
      }
      return null;
    }

    // Convert frames to WAV format
    final allSamples = <double>[];
    for (final frame in matchingFrames) {
      allSamples.addAll(frame.data);
    }

    return _convertToWav(allSamples);
  }

  Uint8List _convertToWav(List<double> samples) {
    if (samples.isEmpty) return Uint8List(44); // Empty WAV with header only

    // WAV header (44 bytes)
    final audioDataSize = samples.length * _bytesPerSample;
    final fileSize = audioDataSize + 36;

    final buffer = ByteData(44 + audioDataSize);

    // RIFF header
    buffer.setUint8(0, 0x52);
    buffer.setUint8(1, 0x49);
    buffer.setUint8(2, 0x46);
    buffer.setUint8(3, 0x46); // "RIFF"
    buffer.setUint32(4, fileSize, Endian.little);
    buffer.setUint8(8, 0x57);
    buffer.setUint8(9, 0x41);
    buffer.setUint8(10, 0x56);
    buffer.setUint8(11, 0x45); // "WAVE"

    // Format chunk
    buffer.setUint8(12, 0x66);
    buffer.setUint8(13, 0x6D);
    buffer.setUint8(14, 0x74);
    buffer.setUint8(15, 0x20); // "fmt "
    buffer.setUint32(16, 16, Endian.little); // Chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM format
    buffer.setUint16(22, 1, Endian.little); // Mono
    buffer.setUint32(24, _sampleRate, Endian.little); // Sample rate
    buffer.setUint32(
      28,
      _sampleRate * _bytesPerSample,
      Endian.little,
    ); // Byte rate
    buffer.setUint16(32, _bytesPerSample, Endian.little); // Block align
    buffer.setUint16(34, 16, Endian.little); // Bits per sample

    // Data chunk
    buffer.setUint8(36, 0x64);
    buffer.setUint8(37, 0x61);
    buffer.setUint8(38, 0x74);
    buffer.setUint8(39, 0x61); // "data"
    buffer.setUint32(40, audioDataSize, Endian.little);

    // Convert samples to 16-bit PCM
    for (int i = 0; i < samples.length; i++) {
      final sample = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
      buffer.setInt16(44 + (i * 2), sample, Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  Duration get availableDuration {
    if (_frames.isEmpty) return Duration.zero;
    return _frames.last.timestamp.difference(_frames.first.timestamp);
  }

  bool get isEmpty => _frames.isEmpty;
  int get frameCount => _frames.length;

  void clear() {
    _frames.clear();
  }
}

class AudioFrame {
  final List<double> data;
  final DateTime timestamp;

  AudioFrame({required this.data, required this.timestamp});
}

/// Synchronized VAD service with precise timing
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
  static const Duration _speechEndDelay = Duration(milliseconds: 800);
  static const Duration _preBufferPadding = Duration(milliseconds: 300);
  static const Duration _postBufferPadding = Duration(milliseconds: 500);

  SynchronizedVADService({GoogleSTTService? sttService})
    : _sttService = sttService {
    _vadHandler = VadHandler.create(isDebug: kDebugMode);
    _setupVADHandler();
    _startBatchUpdateTimer();
  }

  // Getters
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

    _speechEndTimer?.cancel();
    _isSpeechActive = true;

    final now = DateTime.now();
    _speechStartTime = now;

    // Calculate actual speech start with pre-buffer
    _realSpeechStartTime = now.subtract(_preBufferPadding);

    _speechStateController.add(true);
    _scheduleUIUpdate();

    if (kDebugMode) {
      debugPrint('Speech START detected at ${now.millisecondsSinceEpoch}');
      debugPrint(
        'Real speech start (with pre-buffer): ${_realSpeechStartTime!.millisecondsSinceEpoch}',
      );
      debugPrint(
        'Available buffer: ${_frameBuffer.availableDuration.inMilliseconds}ms',
      );
    }
  }

  void _onSpeechEnd() {
    if (!_isRecording || !_isSpeechActive) return;

    // Cancel previous timer if exists
    _speechEndTimer?.cancel();

    // Delay speech end processing to catch trailing audio
    _speechEndTimer = Timer(_speechEndDelay, () {
      _finalizeSpeechSegment();
    });

    _isSpeechActive = false;
    _speechStateController.add(false);
    _scheduleUIUpdate();

    if (kDebugMode) {
      debugPrint(
        'Speech END detected, finalizing in ${_speechEndDelay.inMilliseconds}ms',
      );
    }
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
        positiveSpeechThreshold: 0.3, // More sensitive
        negativeSpeechThreshold: 0.1, // Very sensitive to speech end
        minSpeechFrames: 1,
        preSpeechPadFrames: 8, // ~256ms pre-speech padding
        redemptionFrames: 12, // ~384ms post-speech padding
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
      if (kDebugMode) {
        debugPrint('Finalizing speech segment:');
        debugPrint('  Start: ${_realSpeechStartTime!.millisecondsSinceEpoch}');
        debugPrint('  End: ${endTime.millisecondsSinceEpoch}');
        debugPrint('  Duration: ${duration.inMilliseconds}ms');
        debugPrint(
          '  Available buffer: ${_frameBuffer.availableDuration.inMilliseconds}ms',
        );
      }

      // Extract audio with precise timing
      final audioData = _frameBuffer.extractAudioBetween(
        _realSpeechStartTime!,
        endTime,
      );

      if (audioData == null) {
        if (kDebugMode) {
          debugPrint('Failed to extract audio segment - no matching frames');
        }
        return;
      }

      if (audioData.length <= 44) {
        // Only WAV header
        if (kDebugMode) {
          debugPrint('Audio segment too small: ${audioData.length} bytes');
        }
        return;
      }

      // Create speech segment
      final segment = SpeechSegment(
        id: segmentId,
        startTime: _realSpeechStartTime!,
        endTime: endTime,
        confidence: _currentConfidence,
        audioData: audioData,
      );

      _speechSegments.add(segment);

      if (kDebugMode) {
        debugPrint(
          'Speech segment created: ${audioData.length} bytes, ${duration.inMilliseconds}ms',
        );
      }

      // Queue for STT processing
      if (_sttService != null) {
        _queueSTTProcessing(segment);
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

      final sttResult = await _sttService!.transcribeAudioBuffer(
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

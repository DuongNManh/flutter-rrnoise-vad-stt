import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_google_stt/services/audio_buffer_manager.dart';
import 'package:vad/vad.dart';
import 'package:permission_handler/permission_handler.dart';
import 'google_stt_service.dart';

/// Clean, simplified VAD service using buffer-based approach
class CleanVADService extends ChangeNotifier {
  // Core components
  late final dynamic _vadHandler;
  final AudioBufferManager _audioBuffer = AudioBufferManager();
  final GoogleSTTService? _sttService;
  final SpeechDetectionConfig _config;

  // State management
  bool _isRecording = false;
  bool _isSpeechActive = false;
  double _currentConfidence = 0.0;
  DateTime? _speechStartTime;

  // Speech segments
  final List<SpeechSegment> _speechSegments = [];
  final List<SpeechSegment> _sttQueue = [];
  bool _isProcessingSTT = false;

  // Performance monitoring
  int _totalFramesProcessed = 0;
  DateTime? _lastUIUpdate;
  Timer? _batchUpdateTimer;
  bool _hasPendingUIUpdate = false;

  // Stream controllers
  final _confidenceController = StreamController<double>.broadcast();
  final _speechStateController = StreamController<bool>.broadcast();
  final _transcriptController = StreamController<SpeechSegment>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();

  // Constructor
  CleanVADService({GoogleSTTService? sttService, SpeechDetectionConfig? config})
    : _sttService = sttService,
      _config = config ?? const SpeechDetectionConfig() {
    _vadHandler = VadHandler.create(isDebug: false);
    _setupVADHandler();
    _startBatchUpdateTimer();
  }

  // Getters
  bool get isRecording => _isRecording;
  bool get isSpeechActive => _isSpeechActive;
  double get currentConfidence => _currentConfidence;
  List<SpeechSegment> get speechSegments => List.unmodifiable(_speechSegments);
  double get recordingDuration => _audioBuffer.durationSeconds;

  // Streams
  Stream<double> get confidenceStream => _confidenceController.stream;
  Stream<bool> get speechStateStream => _speechStateController.stream;
  Stream<SpeechSegment> get transcriptStream => _transcriptController.stream;
  Stream<double> get audioLevelStream => _audioLevelController.stream;

  /// Start recording with VAD
  Future<bool> startRecording() async {
    if (_isRecording) return true;

    // Check permissions
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      debugPrint('Microphone permission denied');
      return false;
    }

    try {
      // Initialize audio buffer
      _audioBuffer.initialize();

      // Clear previous data
      _speechSegments.clear();
      _sttQueue.clear();
      _isProcessingSTT = false;
      _totalFramesProcessed = 0;
      _currentConfidence = 0.0;
      _isSpeechActive = false;

      // Start VAD với cấu hình tối ưu cho câu ngắn
      await _vadHandler.startListening(
        model: 'v5',
        frameSamples: 512,
        positiveSpeechThreshold: 0.25, // Giảm ngưỡng để phát hiện nhanh hơn
        negativeSpeechThreshold: 0.1, // Giảm để nhạy hơn với kết thúc câu
        minSpeechFrames: 1, // Phát hiện ngay lập tức khi có giọng nói
        preSpeechPadFrames:
            12, // Tăng đáng kể để bắt đầu từ trước khi nói (~96ms)
        redemptionFrames: 24, // Tăng để có thêm thời gian sau khi nói (~160ms)
        submitUserSpeechOnPause: false,
      );

      _isRecording = true;
      _scheduleUIUpdate();

      if (kDebugMode) {
        debugPrint('Clean VAD Service started');
      }

      return true;
    } catch (e) {
      debugPrint('Error starting VAD service: $e');
      return false;
    }
  }

  /// Stop recording
  Future<void> stopRecording() async {
    if (!_isRecording) return;

    try {
      // Finish current speech if active
      if (_isSpeechActive) {
        await _finalizeSpeechSegment();
      }

      // Stop VAD
      await _vadHandler.stopListening();

      _isRecording = false;
      _scheduleUIUpdate();

      if (kDebugMode) {
        debugPrint(
          'Clean VAD Service stopped. Total segments: ${_speechSegments.length}',
        );
      }
    } catch (e) {
      debugPrint('Error stopping VAD service: $e');
    }
  }

  // Private methods

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

    _isSpeechActive = true;

    // Tính toán prebuffer tối ưu cho câu ngắn
    // Thêm prebuffer lớn hơn (mặc định + 150ms bổ sung)
    final extraPreBuffer = Duration(milliseconds: 150);
    final totalPreBuffer = Duration(
      milliseconds:
          _config.preBufferDuration.inMilliseconds +
          extraPreBuffer.inMilliseconds,
    );

    // Apply pre-buffer padding lớn hơn
    _speechStartTime = DateTime.now().subtract(totalPreBuffer);

    // Ensure start time is not before recording start
    if (_audioBuffer.recordingStartTime != null &&
        _speechStartTime!.isBefore(_audioBuffer.recordingStartTime!)) {
      _speechStartTime = _audioBuffer.recordingStartTime;
    }

    _speechStateController.add(true);
    _scheduleUIUpdate();

    if (kDebugMode) {
      debugPrint(
        'Speech started with ${totalPreBuffer.inMilliseconds}ms enhanced pre-buffer',
      );
    }
  }

  void _onSpeechEnd() {
    if (!_isRecording || !_isSpeechActive) return;

    // Schedule speech finalization with post-buffer delay
    Timer(_config.postBufferDuration, () {
      _finalizeSpeechSegment();
    });

    _isSpeechActive = false;
    _speechStateController.add(false);
    _scheduleUIUpdate();

    if (kDebugMode) {
      debugPrint(
        'Speech ended, will finalize in ${_config.postBufferDuration.inMilliseconds}ms',
      );
    }
  }

  void _onFrameProcessed(frameData) {
    if (!_isRecording) return;

    _totalFramesProcessed++;
    _currentConfidence = frameData.isSpeech;

    // Add audio frame to buffer
    _audioBuffer.addAudioFrame(frameData.frame);

    // Update audio level
    final audioLevel = _audioBuffer.getCurrentAudioLevel();
    _audioLevelController.add(audioLevel);

    // Emit confidence updates
    _confidenceController.add(_currentConfidence);

    // Throttled UI updates
    _scheduleUIUpdate();
  }

  Future<void> _finalizeSpeechSegment() async {
    if (_speechStartTime == null) return;

    var endTime = DateTime.now(); // Sử dụng var thay vì final
    final segmentId = 'segment_${DateTime.now().microsecondsSinceEpoch}';
    final segmentDuration = endTime.difference(_speechStartTime!);

    try {
      // Nếu đây là câu nói ngắn (dưới 1 giây), áp dụng chiến lược đặc biệt
      bool isShortUtterance = segmentDuration.inMilliseconds < 1000;
      if (isShortUtterance) {
        if (kDebugMode) {
          debugPrint(
            'Detected short utterance: ${segmentDuration.inMilliseconds}ms - applying special handling',
          );
        }

        // Mở rộng thời gian kết thúc để đảm bảo bắt được toàn bộ câu nói ngắn
        endTime = endTime.add(Duration(milliseconds: 200));
      }

      // Kiểm tra buffer data ít nghiêm ngặt hơn
      if (_audioBuffer.recordingStartTime != null) {
        final bufferDuration = endTime.difference(
          _audioBuffer.recordingStartTime!,
        );

        // Chỉ kiểm tra nếu khác biệt quá lớn (50% thời lượng buffer)
        if (bufferDuration.inMilliseconds * 0.5 >
            segmentDuration.inMilliseconds) {
          if (kDebugMode) {
            debugPrint(
              'Buffer may be insufficient but proceeding: buffer ${bufferDuration.inMilliseconds}ms, segment ${segmentDuration.inMilliseconds}ms',
            );
          }
          // Tiếp tục xử lý thay vì return
        }
      }

      // Tính toán lại thời điểm bắt đầu cho các câu nói ngắn
      if (isShortUtterance) {
        // Mở rộng thêm thời gian bắt đầu để đảm bảo bắt được từ đầu tiên
        _speechStartTime = _speechStartTime!.subtract(
          Duration(milliseconds: 100),
        );

        // Đảm bảo không vượt quá thời điểm bắt đầu ghi âm
        if (_audioBuffer.recordingStartTime != null &&
            _speechStartTime!.isBefore(_audioBuffer.recordingStartTime!)) {
          _speechStartTime = _audioBuffer.recordingStartTime;
        }
      }

      // Extract audio segment from buffer
      final audioData = _audioBuffer.extractSegment(
        startTime: _speechStartTime!,
        endTime: endTime,
      );

      if (audioData == null) {
        if (kDebugMode) {
          debugPrint(
            'Failed to extract audio segment - completely null buffer, skipping segment',
          );
        }
        return;
      }

      if (audioData.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            'Extracted audio segment is empty, but proceeding with minimum data',
          );
        }
        // Vẫn tiếp tục xử lý với dữ liệu tối thiểu thay vì return
      }

      if (kDebugMode) {
        debugPrint(
          'Audio segment extracted successfully: ${audioData.length} bytes, ${endTime.difference(_speechStartTime!).inMilliseconds}ms',
        );
      }

      // Create speech segment
      final segment = SpeechSegment(
        id: segmentId,
        startTime: _speechStartTime!,
        endTime: endTime,
        confidence: _currentConfidence,
        audioData: audioData,
      );

      _speechSegments.add(segment);

      if (kDebugMode) {
        debugPrint(
          'Speech segment created: ${segment.duration.inMilliseconds}ms, ${audioData.length} bytes',
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

      // Brief pause to prevent UI blocking
      await Future.delayed(const Duration(milliseconds: 10));
    }

    _isProcessingSTT = false;
  }

  Future<void> _processSegmentWithSTT(SpeechSegment segment) async {
    if (_sttService == null || segment.audioData == null) return;

    try {
      segment.markProcessing();
      _scheduleUIUpdate();

      // Xác định đây có phải là đoạn giọng nói ngắn không
      final isShortSegment = segment.duration.inMilliseconds < 1000;
      final priority = isShortSegment
          ? 'high'
          : 'normal'; // Ưu tiên cho câu ngắn

      if (kDebugMode) {
        debugPrint(
          'Processing ${isShortSegment ? "SHORT" : "normal"} segment ${segment.id} with STT (${segment.audioData!.length} bytes, priority: $priority)',
        );
      }

      // Call STT API with audio buffer và xử lý đặc biệt cho đoạn ngắn
      final sttResult = await _sttService.transcribeAudioBuffer(
        segment.audioData!,
        debugName: segment.id,
      );

      if (sttResult != null) {
        var transcript = sttResult.transcript;

        // Đối với câu nói ngắn, thực hiện hậu xử lý
        if (isShortSegment) {
          if (transcript.isNotEmpty) {
            // Nếu câu nói ngắn không có từ bắt đầu thông thường, có thể bị thiếu đầu câu
            final commonStartingWords = [
              'Xin',
              'Vâng',
              'Dạ',
              'Thưa',
              'Ừ',
              'À',
              'Này',
              'Đây',
              'Chào',
              'Đúng',
              'Không',
            ];
            bool hasCommonStart = false;

            for (final word in commonStartingWords) {
              if (transcript.startsWith(word)) {
                hasCommonStart = true;
                break;
              }
            }

            if (!hasCommonStart) {
              if (kDebugMode) {
                debugPrint('⚠️ Có khả năng thiếu đầu câu trong phân đoạn ngắn');
              }
              // Đánh dấu transcript có thể thiếu phần đầu
              transcript = '... ' + transcript;
            }
          }
        }

        segment.updateTranscript(transcript, sttResult.confidence);

        if (sttResult.hasText) {
          _transcriptController.add(segment);

          if (kDebugMode) {
            debugPrint(
              'STT Result: "${transcript}" (conf: ${sttResult.confidence.toStringAsFixed(2)})',
            );
          }
        }
      } else {
        segment.updateTranscript('', 0.0);
        if (kDebugMode) {
          debugPrint('STT failed for segment ${segment.id}');
        }
      }

      _scheduleUIUpdate();
    } catch (e) {
      debugPrint('Error processing segment ${segment.id} with STT: $e');
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

  /// Get full transcript from all segments
  String getFullTranscript() {
    return _speechSegments
        .where((segment) => segment.hasTranscript)
        .map((segment) => segment.transcript)
        .join(' ')
        .trim();
  }

  /// Export audio buffer as WAV file
  Future<Uint8List?> exportFullRecording() async {
    if (_audioBuffer.isEmpty) return null;
    return _audioBuffer.getFullBuffer();
  }

  /// Clear all data
  void clearAll() {
    _speechSegments.clear();
    _sttQueue.clear();
    _audioBuffer.clear();
    _isProcessingSTT = false;
    _totalFramesProcessed = 0;
    _currentConfidence = 0.0;
    _isSpeechActive = false;
    _speechStartTime = null;

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

    _batchUpdateTimer?.cancel();
    _confidenceController.close();
    _speechStateController.close();
    _transcriptController.close();
    _audioLevelController.close();
    _vadHandler.dispose();

    super.dispose();
  }
}

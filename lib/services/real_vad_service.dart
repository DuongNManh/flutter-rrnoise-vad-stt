import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vad/vad.dart';

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
class RealVADService extends ChangeNotifier {
  // VAD handler
  dynamic _vadHandler;

  // AudioRecorder instance for audio recording
  final _record = AudioRecorder();

  // Lists to track audio data and events
  final List<double> _audioLevels = [];
  final List<VADEvent> _events = [];
  final List<AudioSegment> _segments = [];

  // Stream controllers
  StreamController<double> _audioLevelController =
      StreamController<double>.broadcast();
  StreamController<List<double>> _waveformController =
      StreamController<List<double>>.broadcast();
  StreamController<bool> _speechDetectedController =
      StreamController<bool>.broadcast();

  // Current state
  bool _isRecording = false;
  bool _isSpeechDetected = false;
  double _currentConfidence = 0.0;
  DateTime? _recordingStartTime;
  DateTime? _speechStartTime;
  String? _currentRecordingPath;

  // Sample rate for audio recording
  final int _sampleRate = 16000;

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
  RealVADService() {
    _initVAD();
  }

  // Initialize VAD
  Future<void> _initVAD() async {
    try {
      // Initialize the VAD handler with debug mode enabled for verbose logging
      _vadHandler = VadHandler.create(isDebug: true);
      
      // Setup event listeners in startRecording method
      print('VAD handler initialized successfully');
    } catch (e) {
      print('Error initializing VAD: $e');
    }
  }  // Start recording with VAD detection
  Future<void> startRecording() async {
    if (_isRecording || _vadHandler == null) return;

    try {
      // Check for permission
      final hasPermission = await Permission.microphone.request().isGranted;
      if (!hasPermission) {
        print('No permission to record audio');
        return;
      }

      // Reset state
      _audioLevels.clear();
      _events.clear();
      _isSpeechDetected = false;
      _currentConfidence = 0.0;
      _recordingStartTime = DateTime.now();

      // Create a temporary recording file
      final tempDir = await getTemporaryDirectory();
      _currentRecordingPath =
          '${tempDir.path}/vad_recording_${DateTime.now().millisecondsSinceEpoch}.wav';
      
      // Create recording configuration
      final config = RecordConfig(
        encoder: AudioEncoder.wav,
        bitRate: 16000,
        sampleRate: _sampleRate,
        numChannels: 1,
      );

      // Start recording
      await _record.start(
        config,
        path: _currentRecordingPath!,
      );

      _isRecording = true;
      notifyListeners();
      
      // Setup VAD handler listeners
      _setupVADHandlerListeners();
      
      // Sử dụng cách gọi cho phiên bản vad 0.0.6 (hỗ trợ tham số model)
      await _vadHandler.startListening(
        positiveSpeechThreshold: 0.5,
        negativeSpeechThreshold: 0.3,
        frameSamples: 512,  // 512 là giá trị tối ưu cho model v5
        minSpeechFrames: 2,
        preSpeechPadFrames: 1,
        redemptionFrames: 3,
        submitUserSpeechOnPause: false,
        model: 'v5',  // Sử dụng model Silero VAD v5 mới nhất
      );
      print('Started VAD for audio processing');
      
      // Start monitoring audio levels for visualization only
      _startAudioLevelMonitoring();
      print('Recording started with real VAD');
    } catch (e) {
      print('Error starting recording: $e');
    }
  }

  // Setup VAD handler listeners
  void _setupVADHandlerListeners() {
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
            timeFromStart: DateTime.now()
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
    
    return (sum / audioFrame.length) * 100; // Scale to 0-100 range
  }

  // Update audio level list
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

      // Stop recording - API không thay đổi nhưng trả về đường dẫn tệp đã ghi
      final recordedFilePath = await _record.stop();
      
      // Cập nhật đường dẫn nếu có
      if (recordedFilePath != null) {
        _currentRecordingPath = recordedFilePath;
      }

      _isRecording = false;
      _isSpeechDetected = false;
      _currentConfidence = 0.0;
      notifyListeners();

      print('Recording stopped, ${_segments.length} speech segments detected');
    } catch (e) {
      print('Error stopping recording: $e');
    }
  }

  // Start monitoring audio levels (for visualization only)
  void _startAudioLevelMonitoring() {
    // Sử dụng VadHandler để giám sát mức âm thanh thay vì phụ thuộc vào API của AudioRecorder
    // VadHandler sẽ xử lý việc này trong onFrameProcessed
    
    // Nếu bạn muốn giám sát mức âm thanh song song, sử dụng cơ chế khác ở đây
    print('Audio level monitoring is now handled by VAD handler via onFrameProcessed');
  }

  // Phương thức _processVAD đã được loại bỏ, chúng ta sử dụng VAD handler để xử lý thay thế  // Phương thức này không còn cần thiết vì chúng ta sử dụng handler event listeners

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

    print(
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

    // Create a dummy segment file
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

        print(
          'Speech segment ended at ${timeFrom.toStringAsFixed(2)}s and saved to $segmentPath',
        );
      }
    } catch (e) {
      print('Error saving speech segment: $e');
    }

    // Reset speech start time
    _speechStartTime = null;

    // Notify listeners
    notifyListeners();
  }

  // Clean up resources
  @override
  void dispose() {
    // Stop recording if active
    if (_isRecording) {
      try {
        _vadHandler.stopListening();
        _record.stop();
      } catch (e) {
        print('Error stopping recording during dispose: $e');
      }
    }

    // Clean up AudioRecorder
    try {
      _record.dispose();
    } catch (e) {
      print('Error disposing AudioRecorder: $e');
    }
    
    // Close các StreamController
    try {
      _audioLevelController.close();
      _waveformController.close();
      _speechDetectedController.close();
    } catch (e) {
      print('Error closing stream controllers: $e');
    }

    // Explicitly dispose VAD handler
    try {
      _vadHandler.dispose();
    } catch (e) {
      print('Error disposing VAD handler: $e');
    }

    super.dispose();
  }
}

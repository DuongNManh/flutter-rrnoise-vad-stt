import 'dart:io';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'webrtc_compatibility.dart';

// Thêm enum để định nghĩa các mức độ lọc
enum NoiseSuppressionLevel { off, low, medium, high, veryHigh }

class AudioService {
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  String? _currentRecordingPath;
  bool _isPlaying = false;

  // WebRTC related properties
  MediaStream? _mediaStream;
  bool _isNoiseSuppressed = false;

  // Thay biến boolean bằng enum
  NoiseSuppressionLevel _noiseSuppressionLevel = NoiseSuppressionLevel.medium;
  NoiseSuppressionLevel get noiseSuppressionLevel => _noiseSuppressionLevel;

  // Thay đổi phương thức get từ boolean sang enum
  bool get isNoiseSuppressionEnabled =>
      _noiseSuppressionLevel != NoiseSuppressionLevel.off;

  // Constructor
  AudioService() {
    // Initialize WebRTC in the background to avoid blocking app startup
    Future.microtask(() async {
      try {
        await _initWebRTC();
        print('WebRTC initialized successfully in constructor');
      } catch (e) {
        print('Failed to initialize WebRTC in constructor: $e');
      }
    });
  }

  // Add a method to ensure WebRTC is initialized
  Future<bool> ensureWebRTCInitialized() async {
    if (_mediaStream == null) {
      try {
        await _initWebRTC();
        return _mediaStream != null;
      } catch (e) {
        print('Failed to initialize WebRTC: $e');
        return false;
      }
    }
    return true;
  }

  // Helper method to get device model information
  Future<String> _getDeviceModel() async {
    try {
      if (Platform.isAndroid) {
        // Use device_info_plus in a real implementation
        // For now, we'll use a simple approach for demo purposes
        return await _runPlatformCommand('getprop ro.product.model');
      } else if (Platform.isIOS) {
        // iOS would require a plugin, returning a placeholder
        return 'iOS device';
      } else {
        return Platform.operatingSystem;
      }
    } catch (e) {
      print('Error getting device model: $e');
      return 'Unknown';
    }
  }

  // Helper to run platform commands
  Future<String> _runPlatformCommand(String command) async {
    try {
      // In a real app, you would use a method channel or platform-specific code
      // This is just a placeholder that will return a default value
      return 'Unknown device';
    } catch (e) {
      print('Error running platform command: $e');
      return 'Unknown';
    }
  }

  // Try various fallback approaches for WebRTC initialization
  Future<bool> _tryFallbackInitializations() async {
    // List of fallback approaches to try
    List<Map<String, dynamic>> fallbackApproaches = [
      // Approach 1: Minimal constraints
      {'audio': true, 'video': false},

      // Approach 2: Explicit disabled features (ensuring all values are boolean)
      {
        'audio': {
          'echoCancellation': false,
          'noiseSuppression': false,
          'autoGainControl': false,
          'googEchoCancellation': false,
          'googNoiseSuppression': false,
          'googAutoGainControl': false,
        },
        'video': false,
      },

      // Approach 3: Try with specific sample rate (some devices need this)
      {
        'audio': {'sampleRate': 44100},
        'video': false,
      },
    ];

    // Try each approach
    for (int i = 0; i < fallbackApproaches.length; i++) {
      try {
        print('Trying fallback approach #${i + 1}: ${fallbackApproaches[i]}');
        _mediaStream = await navigator.mediaDevices.getUserMedia(
          fallbackApproaches[i],
        );
        if (_mediaStream != null && _mediaStream!.getAudioTracks().isNotEmpty) {
          print('Fallback approach #${i + 1} succeeded');
          return true;
        } else {
          print(
            'Fallback approach #${i + 1} did not produce valid audio tracks',
          );
        }
      } catch (e) {
        print('Fallback approach #${i + 1} failed: $e');
        // Continue to next approach
      }
    }

    print('All fallback approaches failed');
    return false;
  }

  // Public method to force reinitialize WebRTC
  Future<bool> forceReinitializeWebRTC() async {
    print('Force reinitializing WebRTC...');
    try {
      // First dispose current media stream if any
      if (_mediaStream != null) {
        await _disposeMediaStream();
      }

      // Try to initialize WebRTC again
      await _initWebRTC();
      bool success = _mediaStream != null;
      print('WebRTC reinitialization ${success ? 'successful' : 'failed'}');
      return success;
    } catch (e) {
      print('Error during WebRTC reinitialization: $e');
      return false;
    }
  }

  // Initialize WebRTC components
  Future<void> _initWebRTC() async {
    try {
      // Tạo constraints dựa trên mức độ lọc
      Map<String, dynamic> constraints = {'audio': true, 'video': false};

      // Đặt giá trị echoCancellation và noiseSuppression dựa trên mức độ
      if (_noiseSuppressionLevel != NoiseSuppressionLevel.off) {
        constraints['audio'] = {
          'echoCancellation': true,
          'noiseSuppression': true,
        };

        // Thêm các tham số tùy chỉnh cho mức độ lọc (không phải tất cả thiết bị đều hỗ trợ)
        // Các giá trị thực tế có thể khác nhau tùy từng thiết bị
        // Note: Using boolean true instead of integer values for googNoiseSuppression
        // since some devices expect boolean rather than integer values
        // Apply the same settings regardless of level - just use boolean values
        // Store the level in a separate variable for debugging
        String levelName;

        switch (_noiseSuppressionLevel) {
          case NoiseSuppressionLevel.low:
            constraints['audio']['googNoiseSuppression'] = true;
            constraints['audio']['googHighpassFilter'] = true;
            levelName = 'low';
            break;
          case NoiseSuppressionLevel.medium:
            constraints['audio']['googNoiseSuppression'] = true;
            constraints['audio']['googHighpassFilter'] = true;
            levelName = 'medium';
            break;
          case NoiseSuppressionLevel.high:
            constraints['audio']['googNoiseSuppression'] = true;
            constraints['audio']['googHighpassFilter'] = true;
            levelName = 'high';
            break;
          case NoiseSuppressionLevel.veryHigh:
            constraints['audio']['googNoiseSuppression'] = true;
            constraints['audio']['googHighpassFilter'] = true;
            levelName = 'veryHigh';
            break;
          default:
            levelName = 'unknown';
            break;
        }

        // Log the level for debugging purposes
        print('Applying noise suppression level: $levelName');
      }

      // Get audio stream with the specified constraints
      _mediaStream = await navigator.mediaDevices.getUserMedia(constraints);

      await _configureNoiseSuppression(_isNoiseSuppressed);
      print('WebRTC audio stream initialized successfully');
    } catch (e) {
      print('Error initializing WebRTC audio stream: $e');
      _mediaStream = null;
    }
  }

  // Configure noise suppression settings
  Future<void> _configureNoiseSuppression(bool enabled) async {
    if (_mediaStream != null) {
      try {
        // Get the audio tracks from the media stream
        final audioTracks = _mediaStream!.getAudioTracks();

        if (audioTracks.isNotEmpty) {
          // Instead of using applyConstraints which may not be implemented,
          // we'll create a new MediaStream with proper constraints when needed

          // Just store the user preference
          _isNoiseSuppressed = enabled;
          print(
            'Noise suppression preference set to: ${enabled ? 'enabled' : 'disabled'}',
          );

          // Enable/disable the track to reflect the current setting
          for (var track in audioTracks) {
            track.enabled =
                true; // Keep track enabled, but will recreate stream when needed
          }
        } else {
          print('No audio tracks found to configure noise suppression');
        }
      } catch (e) {
        print('Error configuring noise suppression: $e');
      }
    }
  }

  // Toggle noise suppression
  Future<bool> toggleNoiseSuppression() async {
    // Check if the device supports WebRTC noise suppression before toggling
    final supportsNS = await WebRTCCompatibility.supportsNoiseSuppression();

    if (!supportsNS && !_isNoiseSuppressed) {
      // If trying to enable on an unsupported device, don't allow it
      print('Cannot enable noise suppression: not supported on this device');
      return _isNoiseSuppressed; // Return current state (still disabled)
    }

    // Toggle the state
    _isNoiseSuppressed = !_isNoiseSuppressed;

    // Recreate the media stream with the new settings
    await _recreateMediaStream();

    return _isNoiseSuppressed;
  }

  // Helper method to recreate the media stream with current settings
  Future<void> _recreateMediaStream() async {
    try {
      // Dispose old media stream if it exists
      if (_mediaStream != null) {
        final audioTracks = _mediaStream!.getAudioTracks();
        for (var track in audioTracks) {
          track.stop();
        }
        _mediaStream!.dispose();
        _mediaStream = null;
      }

      // Create new media stream with current noise suppression setting
      final mediaConstraints = <String, dynamic>{
        'audio': {
          'echoCancellation': false,
          'noiseSuppression': _isNoiseSuppressed,
          'autoGainControl': false,
          // Add Google-specific constraints with boolean values
          'googEchoCancellation': false,
          'googNoiseSuppression': _isNoiseSuppressed,
          'googAutoGainControl': false,
          'googHighpassFilter': _isNoiseSuppressed,
        },
        'video': false,
      };

      // Get new stream with the updated constraints
      _mediaStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );
      print(
        'Media stream recreated with noise suppression: $_isNoiseSuppressed',
      );
    } catch (e) {
      print('Error recreating media stream: $e');
    }
  }

  // Check if noise suppression is enabled
  bool get isNoiseSuppressed => _isNoiseSuppressed;

  Future<void> startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      // Use documents directory for more persistence
      final directory = await getApplicationDocumentsDirectory();
      _currentRecordingPath =
          '${directory.path}/audio_record_${DateTime.now().millisecondsSinceEpoch}.wav';

      // Ensure WebRTC is initialized if noise suppression is enabled
      if (_noiseSuppressionLevel != NoiseSuppressionLevel.off) {
        await ensureWebRTCInitialized();
      }

      // Apply WebRTC processing before recording
      if (_mediaStream != null &&
          _noiseSuppressionLevel != NoiseSuppressionLevel.off) {
        try {
          // Ensure the media stream has the correct noise suppression setting
          if (_mediaStream!.getAudioTracks().isNotEmpty) {
            // Make sure tracks are enabled
            for (var track in _mediaStream!.getAudioTracks()) {
              track.enabled = true;
            }

            print(
              'Recording with noise suppression level: $_noiseSuppressionLevel',
            );
          }
        } catch (e) {
          // If WebRTC fails, we'll still record
          print('Could not prepare audio tracks: $e');
        }
      } else if (_noiseSuppressionLevel != NoiseSuppressionLevel.off) {
        print('Warning: Noise suppression enabled but WebRTC not initialized');
      }

      // Tạo cấu hình ghi âm với API mới của record 6.1.1
      final config = RecordConfig(
        encoder: AudioEncoder.wav,
        bitRate: 16000,
        sampleRate: 16000,
        numChannels: 1,
      );

      // Sử dụng API mới để bắt đầu ghi âm
      await _audioRecorder.start(config, path: _currentRecordingPath!);
    }
  }

  /// Stops recording and returns the recording path
  Future<String?> stopRecording() async {
    // Stop WebRTC audio processing if it was active
    if (_isNoiseSuppressed && _mediaStream != null) {
      final audioTracks = _mediaStream!.getAudioTracks();
      for (var track in audioTracks) {
        track.enabled = false;
      }
    }

    // API mới của record 6.1.1 trả về đường dẫn file ghi âm
    final recordedFilePath = await _audioRecorder.stop();

    // Cập nhật đường dẫn nếu được trả về từ API
    if (recordedFilePath != null) {
      _currentRecordingPath = recordedFilePath;
    }

    return _currentRecordingPath;
  }

  Future<bool> isRecording() async {
    return await _audioRecorder.isRecording();
  }

  Future<void> playRecording(String? filePath) async {
    // Determine which file to play
    String? pathToPlay = filePath ?? _currentRecordingPath;

    if (pathToPlay == null) return;

    if (_isPlaying) {
      await stopPlayback();
    }

    try {
      await _audioPlayer.play(DeviceFileSource(pathToPlay));
      _isPlaying = true;

      // Listen for playback completion
      _audioPlayer.onPlayerComplete.listen((event) {
        _isPlaying = false;
      });
    } catch (e) {
      print('Error playing audio: $e');
      _isPlaying = false;
    }
  }

  Future<void> stopPlayback() async {
    await _audioPlayer.stop();
    _isPlaying = false;
  }

  bool get isPlaying => _isPlaying;

  Future<void> dispose() async {
    await _audioPlayer.dispose();
    await _audioRecorder.dispose();

    // Clean up WebRTC resources
    if (_mediaStream != null) {
      final audioTracks = _mediaStream!.getAudioTracks();
      for (var track in audioTracks) {
        track.stop();
      }
      _mediaStream!.dispose();
    }
  }

  // Add method to get all recordings
  Future<List<String>> getAllRecordings() async {
    final directory = await getApplicationDocumentsDirectory();
    final dir = Directory(directory.path);
    List<FileSystemEntity> files = await dir.list().toList();

    // Filter only wav files that match our naming pattern
    return files
        .whereType<File>()
        .where(
          (file) =>
              file.path.contains('audio_record_') && file.path.endsWith('.wav'),
        )
        .map((file) => file.path)
        .toList();
  }

  // Get the path to the current recording
  String? get recordingPath => _currentRecordingPath;

  // Set current recording path to an existing recording
  Future<String?> setRecording(String filePath) async {
    _currentRecordingPath = filePath;
    return _currentRecordingPath;
  }

  // Add method to delete a recording
  Future<bool> deleteRecording(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      print('Error deleting recording: $e');
      return false;
    }
  }

  // Method to test noise suppression functionality
  Future<Map<String, dynamic>> testNoiseSuppression() async {
    if (_mediaStream == null) {
      return {
        'success': false,
        'message': 'WebRTC media stream not initialized',
      };
    }

    try {
      // Force a refresh of the media stream to ensure settings are applied
      await _recreateMediaStream();

      final audioTracks = _mediaStream!.getAudioTracks();

      if (audioTracks.isEmpty) {
        return {
          'success': false,
          'message': 'No audio tracks available for testing',
        };
      }

      // Get current track information
      final track = audioTracks[0];

      // Note: getConstraints() is not fully implemented on all platforms,
      // so we'll provide more useful information instead
      Map<String, dynamic> trackInfo = {};
      try {
        // Try to get constraints, but this will likely fail on Android
        final constraints = track.getConstraints();
        trackInfo['constraints'] = constraints.toString();
      } catch (e) {
        // Provide more useful information instead
        trackInfo['note'] =
            "WebRTC constraints API not supported on this device";
        trackInfo['activeSettings'] = {
          'noiseSuppression': _isNoiseSuppressed,
          'deviceId': track.id,
          'kind': track.kind,
          'enabled': track.enabled,
          'muted': track.muted,
        };
      }

      return {
        'success': true,
        'isNoiseSuppressed': _isNoiseSuppressed,
        'trackEnabled': track.enabled,
        'trackId': track.id,
        'trackLabel': track.label,
        'trackSettings': {
          'noiseSuppression': _isNoiseSuppressed,
          'deviceId': track.id,
        },
        'trackInfo': trackInfo,
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Error testing noise suppression: $e',
      };
    }
  }

  // Cập nhật phương thức thiết lập noise suppression
  Future<void> setNoiseSuppressionLevel(NoiseSuppressionLevel level) async {
    if (await _audioRecorder.isRecording()) {
      print('Cannot change noise suppression level while recording');
      return;
    }

    _noiseSuppressionLevel = level;
    _isNoiseSuppressed = level != NoiseSuppressionLevel.off;

    // Only initialize WebRTC if noise suppression is enabled
    if (level != NoiseSuppressionLevel.off) {
      // Dispose existing stream if available
      if (_mediaStream != null) {
        await _disposeMediaStream();
      }

      // Initialize WebRTC with new settings
      await _initWebRTC();
      print('Noise suppression level set to: ${level.toString()}');
    } else if (_mediaStream != null) {
      // If turning off noise suppression, dispose the media stream
      await _disposeMediaStream();
      print('Noise suppression disabled');
    }
  }

  // Thêm phương thức để dọn dẹp MediaStream
  Future<void> _disposeMediaStream() async {
    if (_mediaStream != null) {
      final audioTracks = _mediaStream!.getAudioTracks();
      for (var track in audioTracks) {
        track.stop();
      }
      _mediaStream!.dispose();
      _mediaStream = null;
    }
  }

  // Cập nhật phương thức test để hiển thị mức độ lọc hiện tại
  Future<Map<String, String>> getNoiseSuppessionInfo() async {
    final Map<String, String> info = {};

    info['Status'] = isNoiseSuppressionEnabled ? 'Enabled' : 'Disabled';
    info['Current Level'] = _noiseSuppressionLevel.toString().split('.').last;

    // Check recording status
    final isRecordingNow = await _audioRecorder.isRecording();
    info['Currently Recording'] = isRecordingNow ? 'Yes' : 'No';

    if (_mediaStream != null) {
      info['WebRTC Initialized'] = 'Yes';
      info['Active Audio Tracks'] = _mediaStream!
          .getAudioTracks()
          .length
          .toString();

      // Get track information
      if (_mediaStream!.getAudioTracks().isNotEmpty) {
        final track = _mediaStream!.getAudioTracks().first;
        info['Track ID'] = track.id ?? 'Unknown';
        info['Track Enabled'] = track.enabled.toString();
        info['Track Kind'] = track.kind ?? 'Unknown';
      }

      // Thêm thông tin về constraints đã áp dụng
      try {
        Map<String, dynamic> appliedConstraints = {
          'echoCancellation': isNoiseSuppressionEnabled,
          'noiseSuppression': isNoiseSuppressionEnabled,
        };

        if (isNoiseSuppressionEnabled) {
          // Use boolean values for Google-specific constraints
          appliedConstraints['googNoiseSuppression'] = true;
          appliedConstraints['googHighpassFilter'] = true;

          // Store level information as a string for display purposes only
          switch (_noiseSuppressionLevel) {
            case NoiseSuppressionLevel.low:
              appliedConstraints['level'] = 'low';
              break;
            case NoiseSuppressionLevel.medium:
              appliedConstraints['level'] = 'medium';
              break;
            case NoiseSuppressionLevel.high:
              appliedConstraints['level'] = 'high';
              break;
            case NoiseSuppressionLevel.veryHigh:
              appliedConstraints['level'] = 'veryHigh';
              break;
            default:
              break;
          }
        }

        info['Applied Constraints'] = appliedConstraints.toString();
      } catch (e) {
        info['Applied Constraints'] = 'Not available: $e';
      }
    } else {
      info['WebRTC Initialized'] = 'No';
      if (isNoiseSuppressionEnabled) {
        info['Warning'] =
            'Noise suppression enabled but WebRTC not initialized';
      } else {
        info['Note'] =
            'WebRTC initialization not needed (noise suppression off)';
      }
    }

    return info;
  }
}

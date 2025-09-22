import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Manages audio buffer with WAV format for real-time recording
class AudioBufferManager {
  static const int _sampleRate = 16000;
  static const int _channels = 1;
  static const int _bitsPerSample = 16;
  static const int _bytesPerSample = 2;
  static const int _wavHeaderSize = 44;
  static const int _maxBufferSizeBytes = 10 * 1024 * 1024; // 10MB max

  // Main audio buffer with WAV header
  final List<int> _buffer = [];
  int _totalAudioBytes = 0;
  DateTime? _recordingStartTime;

  // Getters
  int get totalBytes => _buffer.length;
  int get audioDataBytes => _totalAudioBytes;
  double get durationSeconds =>
      _totalAudioBytes / (_sampleRate * _bytesPerSample);
  bool get isEmpty => _totalAudioBytes == 0;
  DateTime? get recordingStartTime => _recordingStartTime;

  /// Initialize buffer with WAV header
  void initialize() {
    _buffer.clear();
    _totalAudioBytes = 0;
    _recordingStartTime = DateTime.now();
    _addWavHeader();

    if (kDebugMode) {
      debugPrint('AudioBufferManager initialized');
    }
  }

  /// Add audio frame from VAD to buffer
  void addAudioFrame(List<double> audioFrame) {
    if (audioFrame.isEmpty) return;

    // Convert float samples (-1.0 to 1.0) to 16-bit PCM
    for (final sample in audioFrame) {
      final clampedSample = sample.clamp(-1.0, 1.0);
      final intSample = (clampedSample * 32767.0).round();

      // Add as little-endian 16-bit
      _buffer.add(intSample & 0xFF);
      _buffer.add((intSample >> 8) & 0xFF);
      _totalAudioBytes += 2;
    }

    _updateWavHeader();
    _checkBufferSize();
  }

  /// Extract audio segment from buffer
  Uint8List? extractSegment({
    required DateTime startTime,
    required DateTime endTime,
  }) {
    if (_recordingStartTime == null) return null;

    final startOffsetMs = startTime
        .difference(_recordingStartTime!)
        .inMilliseconds;
    final endOffsetMs = endTime.difference(_recordingStartTime!).inMilliseconds;

    // Convert time to byte positions
    final bytesPerMs = (_sampleRate * _bytesPerSample) / 1000;
    final requestedStartPos =
        _wavHeaderSize + (startOffsetMs * bytesPerMs).round();
    final requestedEndPos = _wavHeaderSize + (endOffsetMs * bytesPerMs).round();

    // Clamp positions to actual buffer bounds
    final actualStartPos = math.max(_wavHeaderSize, requestedStartPos);
    final actualEndPos = math.min(_buffer.length, requestedEndPos);

    // Validate positions after clamping
    if (actualStartPos >= actualEndPos ||
        actualEndPos <= _wavHeaderSize ||
        actualStartPos >= _buffer.length) {
      if (kDebugMode) {
        debugPrint(
          'Invalid segment after clamping: requested $requestedStartPos-$requestedEndPos, actual $actualStartPos-$actualEndPos (buffer size: ${_buffer.length})',
        );
      }
      return null;
    }

    // Check if we have meaningful audio data
    final segmentAudioSize = actualEndPos - actualStartPos;
    if (segmentAudioSize < 1000) {
      // Less than ~30ms of audio
      if (kDebugMode) {
        debugPrint(
          'Segment too small: ${segmentAudioSize} bytes (~${(segmentAudioSize / bytesPerMs).toStringAsFixed(1)}ms)',
        );
      }
      return null;
    }

    final totalSegmentSize = _wavHeaderSize + segmentAudioSize;

    // Create segment buffer with WAV header
    final segmentBuffer = Uint8List(totalSegmentSize);

    // Copy WAV header
    for (int i = 0; i < _wavHeaderSize; i++) {
      segmentBuffer[i] = _buffer[i];
    }

    // Copy audio data
    for (int i = 0; i < segmentAudioSize; i++) {
      segmentBuffer[_wavHeaderSize + i] = _buffer[actualStartPos + i];
    }

    // Update segment WAV header
    _updateSegmentWavHeader(segmentBuffer, segmentAudioSize);

    if (kDebugMode) {
      final actualDurationMs = (actualEndPos - actualStartPos) / bytesPerMs;
      final requestedDurationMs = endOffsetMs - startOffsetMs;
      debugPrint(
        'Extracted segment: requested ${requestedDurationMs.toStringAsFixed(1)}ms, actual ${actualDurationMs.toStringAsFixed(1)}ms, ${segmentBuffer.length} bytes',
      );
    }

    return segmentBuffer;
  }

  /// Get current audio level (RMS)
  double getCurrentAudioLevel() {
    if (_totalAudioBytes < 1000) return 0.0; // Need minimum data

    // Analyze last 500 samples (1 second at 16kHz)
    final samplesToAnalyze = math.min(1000, _totalAudioBytes ~/ 2);
    final startPos = _buffer.length - (samplesToAnalyze * 2);

    double sumOfSquares = 0.0;
    int samplesCount = 0;

    for (int i = startPos; i < _buffer.length; i += 2) {
      if (i + 1 < _buffer.length) {
        final sample = _buffer[i] | (_buffer[i + 1] << 8);
        final normalizedSample = (sample < 32768) ? sample : sample - 65536;
        final amplitude = normalizedSample / 32768.0;
        sumOfSquares += amplitude * amplitude;
        samplesCount++;
      }
    }

    if (samplesCount == 0) return 0.0;

    final rms = math.sqrt(sumOfSquares / samplesCount);
    final dbLevel = 20 * math.log(rms + 1e-10) / math.ln10;
    return ((dbLevel + 60) / 60 * 100).clamp(0.0, 100.0);
  }

  /// Clear buffer and reset
  void clear() {
    _buffer.clear();
    _totalAudioBytes = 0;
    _recordingStartTime = null;

    if (kDebugMode) {
      debugPrint('AudioBufferManager cleared');
    }
  }

  /// Get full buffer as Uint8List
  Uint8List getFullBuffer() {
    return Uint8List.fromList(_buffer);
  }

  // Private methods

  void _addWavHeader() {
    // RIFF header
    _buffer.addAll([0x52, 0x49, 0x46, 0x46]); // "RIFF"
    _buffer.addAll([0x00, 0x00, 0x00, 0x00]); // File size (placeholder)
    _buffer.addAll([0x57, 0x41, 0x56, 0x45]); // "WAVE"

    // Format chunk
    _buffer.addAll([0x66, 0x6D, 0x74, 0x20]); // "fmt "
    _buffer.addAll([0x10, 0x00, 0x00, 0x00]); // Chunk size (16 bytes)
    _buffer.addAll([0x01, 0x00]); // Format (1 = PCM)
    _buffer.addAll([_channels & 0xFF, (_channels >> 8) & 0xFF]); // Channels

    // Sample rate (little-endian)
    _buffer.addAll([
      _sampleRate & 0xFF,
      (_sampleRate >> 8) & 0xFF,
      (_sampleRate >> 16) & 0xFF,
      (_sampleRate >> 24) & 0xFF,
    ]);

    // Byte rate
    final byteRate = _sampleRate * _channels * _bytesPerSample;
    _buffer.addAll([
      byteRate & 0xFF,
      (byteRate >> 8) & 0xFF,
      (byteRate >> 16) & 0xFF,
      (byteRate >> 24) & 0xFF,
    ]);

    // Block align
    final blockAlign = _channels * _bytesPerSample;
    _buffer.addAll([blockAlign & 0xFF, (blockAlign >> 8) & 0xFF]);

    // Bits per sample
    _buffer.addAll([_bitsPerSample & 0xFF, (_bitsPerSample >> 8) & 0xFF]);

    // Data chunk
    _buffer.addAll([0x64, 0x61, 0x74, 0x61]); // "data"
    _buffer.addAll([0x00, 0x00, 0x00, 0x00]); // Data size (placeholder)
  }

  void _updateWavHeader() {
    if (_buffer.length < _wavHeaderSize) return;

    final fileSize = _totalAudioBytes + 36;

    // Update file size (bytes 4-7)
    _buffer[4] = fileSize & 0xFF;
    _buffer[5] = (fileSize >> 8) & 0xFF;
    _buffer[6] = (fileSize >> 16) & 0xFF;
    _buffer[7] = (fileSize >> 24) & 0xFF;

    // Update data size (bytes 40-43)
    _buffer[40] = _totalAudioBytes & 0xFF;
    _buffer[41] = (_totalAudioBytes >> 8) & 0xFF;
    _buffer[42] = (_totalAudioBytes >> 16) & 0xFF;
    _buffer[43] = (_totalAudioBytes >> 24) & 0xFF;
  }

  void _updateSegmentWavHeader(Uint8List buffer, int audioDataSize) {
    final fileSize = audioDataSize + 36;

    // Update file size
    buffer[4] = fileSize & 0xFF;
    buffer[5] = (fileSize >> 8) & 0xFF;
    buffer[6] = (fileSize >> 16) & 0xFF;
    buffer[7] = (fileSize >> 24) & 0xFF;

    // Update data size
    buffer[40] = audioDataSize & 0xFF;
    buffer[41] = (audioDataSize >> 8) & 0xFF;
    buffer[42] = (audioDataSize >> 16) & 0xFF;
    buffer[43] = (audioDataSize >> 24) & 0xFF;
  }

  void _checkBufferSize() {
    if (_buffer.length > _maxBufferSizeBytes) {
      // Remove oldest audio data (keep header)
      final excessBytes = _buffer.length - _maxBufferSizeBytes;
      final bytesToRemove =
          (excessBytes ~/ 1000) * 1000; // Remove in 1KB chunks

      if (bytesToRemove > 0) {
        _buffer.removeRange(_wavHeaderSize, _wavHeaderSize + bytesToRemove);
        _totalAudioBytes -= bytesToRemove;
        _updateWavHeader();

        if (kDebugMode) {
          debugPrint('Buffer trimmed: removed ${bytesToRemove} bytes');
        }
      }
    }
  }
}

/// Speech segment detected by VAD
class SpeechSegment {
  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final double confidence;
  final Uint8List? audioData;

  // STT results
  String? transcript;
  double? sttConfidence;
  bool isProcessing = false;

  SpeechSegment({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.confidence,
    this.audioData,
  });

  Duration get duration => endTime.difference(startTime);
  bool get hasTranscript => transcript != null && transcript!.isNotEmpty;

  void updateTranscript(String newTranscript, double confidence) {
    transcript = newTranscript;
    sttConfidence = confidence;
    isProcessing = false;
  }

  void markProcessing() {
    isProcessing = true;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'confidence': confidence,
      'duration': duration.inMilliseconds,
      'transcript': transcript,
      'sttConfidence': sttConfidence,
      'hasAudioData': audioData != null,
      'audioDataSize': audioData?.length ?? 0,
    };
  }
}

/// Configuration for speech detection
class SpeechDetectionConfig {
  final double positiveSpeechThreshold;
  final double negativeSpeechThreshold;
  final int minSpeechFrames;
  final int maxLowConfidenceFrames;
  final Duration preBufferDuration;
  final Duration postBufferDuration;

  const SpeechDetectionConfig({
    this.positiveSpeechThreshold = 0.4,
    this.negativeSpeechThreshold = 0.2,
    this.minSpeechFrames = 1,
    this.maxLowConfidenceFrames = 10,
    this.preBufferDuration = const Duration(milliseconds: 200),
    this.postBufferDuration = const Duration(milliseconds: 300),
  });
}

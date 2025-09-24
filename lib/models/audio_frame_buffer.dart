import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_google_stt/models/audio_frame.dart';

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
      debugPrint(
        'No frames found in time range: ${startTime.millisecondsSinceEpoch} - ${endTime.millisecondsSinceEpoch}',
      );
      debugPrint(
        'Available range: ${_frames.first.timestamp.millisecondsSinceEpoch} - ${_frames.last.timestamp.millisecondsSinceEpoch}',
      );

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

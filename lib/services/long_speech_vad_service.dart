import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_google_stt/models/speech_segment.dart';
import 'package:flutter_google_stt/services/google_stt_service.dart';
import 'package:flutter_google_stt/services/synchronized_vad_service.dart';

/// Enhanced VAD service with long speech handling
class LongSpeechVADService extends SynchronizedVADService {
  // Long speech configuration
  static const Duration _maxSegmentDuration = Duration(
    seconds: 45,
  ); // Under 60s limit
  static const int _maxSegmentBytes = 8 * 1024 * 1024; // 8MB under 10MB limit
  static const Duration _overlapDuration = Duration(
    milliseconds: 500,
  ); // Overlap between segments

  // Long speech tracking
  bool _isLongSpeechActive = false;
  Timer? _segmentSplitTimer;
  DateTime? _currentSegmentStart;
  List<SpeechSegment> _longSpeechParts = [];

  LongSpeechVADService({GoogleSTTService? sttService})
    : super(sttService: sttService) {
    _setupLongSpeechHandlers();
  }

  void _setupLongSpeechHandlers() {
    // Listen to speech state changes from parent
    speechStateStream.listen((isActive) {
      if (isActive) {
        _onSpeechStart();
      } else {
        _onSpeechEnd();
      }
    });
  }

  void _onSpeechStart() {
    _startLongSpeechMonitoring();
  }

  void _onSpeechEnd() {
    // Cancel long speech monitoring
    _segmentSplitTimer?.cancel();

    // If it was long speech, finalize all parts
    if (_isLongSpeechActive) {
      _finalizeLongSpeech();
    }
  }

  void _startLongSpeechMonitoring() {
    _segmentSplitTimer?.cancel();
    _currentSegmentStart = realSpeechStartTime;
    _isLongSpeechActive = false;
    _longSpeechParts.clear();

    // Set timer to check for long speech
    _segmentSplitTimer = Timer(_maxSegmentDuration, () {
      if (isSpeechActive) {
        _handleLongSpeech();
      }
    });

    if (kDebugMode) {
      debugPrint(
        'Long speech monitoring started, will split after ${_maxSegmentDuration.inSeconds}s',
      );
    }
  }

  void _handleLongSpeech() {
    if (!isSpeechActive || _currentSegmentStart == null) return;

    _isLongSpeechActive = true;
    final now = DateTime.now();

    if (kDebugMode) {
      debugPrint('Long speech detected! Auto-splitting segment...');
    }

    // Create segment for current part
    _createLongSpeechSegment(
      _currentSegmentStart!,
      now,
      _longSpeechParts.length,
    );

    // Setup for next segment with overlap
    _currentSegmentStart = now.subtract(_overlapDuration);

    // Schedule next split
    _segmentSplitTimer = Timer(_maxSegmentDuration, () {
      if (isSpeechActive) {
        _handleLongSpeech();
      }
    });
  }

  void _createLongSpeechSegment(
    DateTime startTime,
    DateTime endTime,
    int partIndex,
  ) {
    final segmentId =
        'long_speech_${DateTime.now().microsecondsSinceEpoch}_part_$partIndex';

    try {
      final audioData = frameBuffer.extractAudioBetween(startTime, endTime);

      if (audioData == null || audioData.length <= 44) {
        if (kDebugMode) {
          debugPrint('Failed to extract long speech part $partIndex');
        }
        return;
      }

      // Check if segment is too large
      if (audioData.length > _maxSegmentBytes) {
        if (kDebugMode) {
          debugPrint(
            'Long speech part $partIndex too large: ${audioData.length} bytes, splitting further...',
          );
        }
        _splitOversizedSegment(audioData, startTime, endTime, partIndex);
        return;
      }

      final segment = SpeechSegment(
        id: segmentId,
        startTime: startTime,
        endTime: endTime,
        confidence: currentConfidence,
        audioData: audioData,
      );

      // Mark as part of long speech
      segment.isLongSpeechPart = true;
      segment.longSpeechIndex = partIndex;

      _longSpeechParts.add(segment);
      speechSegmentsList.add(segment);

      if (kDebugMode) {
        final duration = endTime.difference(startTime);
        debugPrint(
          'Long speech part $partIndex created: ${audioData.length} bytes, ${duration.inMilliseconds}ms',
        );
      }

      // Queue for STT processing immediately
      if (sttService != null) {
        queueSTTProcessing(segment);
      }

      scheduleUIUpdate();
    } catch (e) {
      debugPrint('Error creating long speech segment part $partIndex: $e');
    }
  }

  void _splitOversizedSegment(
    Uint8List audioData,
    DateTime startTime,
    DateTime endTime,
    int partIndex,
  ) {
    // Calculate how many sub-parts we need
    final totalDuration = endTime.difference(startTime);
    final targetDuration = Duration(seconds: 30); // 30s per sub-part
    final subParts =
        (totalDuration.inMilliseconds / targetDuration.inMilliseconds).ceil();

    if (kDebugMode) {
      debugPrint('Splitting oversized segment into $subParts sub-parts');
    }

    for (int i = 0; i < subParts; i++) {
      final subStartTime = startTime.add(
        Duration(
          milliseconds: (totalDuration.inMilliseconds * i / subParts).round(),
        ),
      );
      final subEndTime = startTime.add(
        Duration(
          milliseconds: (totalDuration.inMilliseconds * (i + 1) / subParts)
              .round(),
        ),
      );

      _createLongSpeechSegment(subStartTime, subEndTime, partIndex * 100 + i);
    }
  }

  void _finalizeLongSpeech() {
    if (_currentSegmentStart != null && isSpeechActive) {
      final endTime = DateTime.now().add(postBufferPadding);
      _createLongSpeechSegment(
        _currentSegmentStart!,
        endTime,
        _longSpeechParts.length,
      );
    }

    _segmentSplitTimer?.cancel();
    // Don't modify parent class state directly since it handles state management

    if (kDebugMode) {
      debugPrint(
        'Long speech finalized: ${_longSpeechParts.length} parts total',
      );
    }

    // Combine transcripts from all parts
    _combineTranscriptsWhenReady();

    // Reset state
    _isLongSpeechActive = false;
    _currentSegmentStart = null;
    speechStartTime = null;
    realSpeechStartTime = null;

    scheduleUIUpdate();
  }

  void _combineTranscriptsWhenReady() {
    // Wait for all parts to be processed
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      final allProcessed = _longSpeechParts.every(
        (part) => part.hasTranscript || !part.isProcessing,
      );

      if (allProcessed) {
        timer.cancel();
        _createCombinedTranscript();
      }

      // Timeout after 2 minutes
      if (timer.tick > 240) {
        timer.cancel();
        _createCombinedTranscript();
        if (kDebugMode) {
          debugPrint(
            'Timeout waiting for long speech parts, combining available transcripts',
          );
        }
      }
    });
  }

  void _createCombinedTranscript() {
    if (_longSpeechParts.isEmpty) return;

    // Sort parts by index
    _longSpeechParts.sort(
      (a, b) => (a.longSpeechIndex ?? 0).compareTo(b.longSpeechIndex ?? 0),
    );

    // Combine transcripts
    final combinedTranscript = _longSpeechParts
        .where((part) => part.hasTranscript)
        .map((part) => part.transcript!)
        .join(' ')
        .trim();

    if (combinedTranscript.isNotEmpty) {
      // Create a combined segment for UI display
      final combinedSegment = SpeechSegment(
        id: 'combined_${DateTime.now().microsecondsSinceEpoch}',
        startTime: _longSpeechParts.first.startTime,
        endTime: _longSpeechParts.last.endTime,
        confidence: _calculateAverageConfidence(),
        audioData: null, // Don't store combined audio to save memory
      );

      combinedSegment.updateTranscript(
        combinedTranscript,
        _calculateAverageConfidence(),
      );
      combinedSegment.isLongSpeechCombined = true;

      speechSegmentsList.add(combinedSegment);
      transcriptController.add(combinedSegment);

      if (kDebugMode) {
        debugPrint('Combined long speech transcript: "$combinedTranscript"');
      }
    }

    _longSpeechParts.clear();
    scheduleUIUpdate();
  }

  double _calculateAverageConfidence() {
    if (_longSpeechParts.isEmpty) return 0.0;

    final validParts = _longSpeechParts.where(
      (part) => part.sttConfidence != null,
    );
    if (validParts.isEmpty) return 0.0;

    final sum = validParts.fold(0.0, (sum, part) => sum + part.sttConfidence!);
    return sum / validParts.length;
  }

  @override
  String getFullTranscript() {
    // Filter out individual long speech parts from display, show only combined ones
    final displaySegments = speechSegmentsList.where(
      (segment) =>
          !(segment.isLongSpeechPart == true && !segment.isLongSpeechCombined),
    );

    return displaySegments
        .where((segment) => segment.hasTranscript)
        .map((segment) => segment.transcript)
        .join(' ')
        .trim();
  }

  @override
  void clearAll() {
    _segmentSplitTimer?.cancel();
    _isLongSpeechActive = false;
    _currentSegmentStart = null;
    _longSpeechParts.clear();
    super.clearAll();
  }

  @override
  void dispose() {
    _segmentSplitTimer?.cancel();
    super.dispose();
  }

  // Additional utility methods

  /// Get statistics about long speech handling
  Map<String, dynamic> getLongSpeechStats() {
    final longSpeechSegments = speechSegmentsList.where(
      (s) => s.isLongSpeechPart == true,
    );
    final combinedSegments = speechSegmentsList.where(
      (s) => s.isLongSpeechCombined == true,
    );

    return {
      'totalLongSpeechParts': longSpeechSegments.length,
      'totalCombinedSegments': combinedSegments.length,
      'maxSegmentDurationSeconds': _maxSegmentDuration.inSeconds,
      'maxSegmentSizeMB': (_maxSegmentBytes / 1024 / 1024).toStringAsFixed(1),
      'overlapMs': _overlapDuration.inMilliseconds,
    };
  }

  /// Check if current speech might become long speech
  bool get mightBecomeLongSpeech {
    if (!isSpeechActive || realSpeechStartTime == null) return false;

    final currentDuration = DateTime.now().difference(realSpeechStartTime!);
    return currentDuration >
        Duration(seconds: (_maxSegmentDuration.inSeconds * 0.8).round());
  }
}

/// Extended SpeechSegment class with long speech support
extension LongSpeechSegment on SpeechSegment {
  static final Map<String, bool> _isLongSpeechPart = {};
  static final Map<String, int> _longSpeechIndex = {};
  static final Map<String, bool> _isLongSpeechCombined = {};

  bool get isLongSpeechPart => _isLongSpeechPart[id] ?? false;
  set isLongSpeechPart(bool value) => _isLongSpeechPart[id] = value;

  int? get longSpeechIndex => _longSpeechIndex[id];
  set longSpeechIndex(int? value) {
    if (value != null) {
      _longSpeechIndex[id] = value;
    } else {
      _longSpeechIndex.remove(id);
    }
  }

  bool get isLongSpeechCombined => _isLongSpeechCombined[id] ?? false;
  set isLongSpeechCombined(bool value) => _isLongSpeechCombined[id] = value;
}

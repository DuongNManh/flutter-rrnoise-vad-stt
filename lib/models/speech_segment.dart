import 'dart:typed_data';

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

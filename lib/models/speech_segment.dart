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
  String? language;
  bool isProcessing = false;
  bool hasError = false;

  SpeechSegment({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.confidence,
    this.audioData,
    this.language,
    this.isProcessing = false,
    this.hasError = false,
  });

  Duration get duration => endTime.difference(startTime);
  bool get hasTranscript => transcript != null && transcript!.isNotEmpty;

  void updateTranscript(
    String newTranscript,
    double confidence, {
    String? detectedLanguage,
  }) {
    transcript = newTranscript;
    sttConfidence = confidence;
    language = detectedLanguage ?? language;
    isProcessing = false;
    hasError = false;
  }

  void markProcessing() {
    isProcessing = true;
    hasError = false;
  }

  void markError() {
    isProcessing = false;
    hasError = true;
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

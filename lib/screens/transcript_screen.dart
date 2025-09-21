import 'package:flutter/material.dart';
import 'package:flutter_google_stt/services/package_vad_service.dart';
import 'package:flutter_google_stt/services/google_stt_service.dart';
import 'dart:async';

class TranscriptScreen extends StatefulWidget {
  final PackageVadService vadService;

  const TranscriptScreen({super.key, required this.vadService});

  @override
  State<TranscriptScreen> createState() => _TranscriptScreenState();
}

class _TranscriptScreenState extends State<TranscriptScreen> {
  List<String> _transcripts = [];
  late StreamSubscription _transcriptSubscription;
  late StreamSubscription _speechSubscription;
  final ScrollController _scrollController = ScrollController();
  bool _isRecording = false;
  String _combinedText = '';

  @override
  void initState() {
    super.initState();

    // Listen to transcription stream
    _transcriptSubscription = widget.vadService.transcriptionStream.listen((
      transcript,
    ) {
      if (transcript.isNotEmpty) {
        setState(() {
          _transcripts.add(transcript);
          _combinedText = _transcripts.join(' ');
        });

        // Auto scroll to bottom
        _autoScrollToBottom();
      }
    });

    // Listen to speech detection for recording status
    _speechSubscription = widget.vadService.speechDetectedStream.listen((
      isDetected,
    ) {
      setState(() {
        _isRecording = widget.vadService.isRecording;
      });
    });

    // Initialize recording status
    _isRecording = widget.vadService.isRecording;
  }

  void _autoScrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearTranscripts() {
    setState(() {
      _transcripts.clear();
      _combinedText = '';
    });
  }

  void _copyToClipboard() {
    if (_combinedText.isNotEmpty) {
      // In a real app, you'd use clipboard package
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Text copied to clipboard: ${_combinedText.length} characters',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcription'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _combinedText.isNotEmpty ? _copyToClipboard : null,
            tooltip: 'Copy text',
          ),
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: _transcripts.isNotEmpty ? _clearTranscripts : null,
            tooltip: 'Clear all',
          ),
        ],
      ),
      body: Column(
        children: [
          // Status indicator
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _isRecording
                  ? Colors.green.withOpacity(0.1)
                  : Colors.grey.withOpacity(0.1),
              border: Border(
                bottom: BorderSide(
                  color: _isRecording ? Colors.green : Colors.grey,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isRecording ? Icons.mic : Icons.mic_off,
                  color: _isRecording ? Colors.green : Colors.grey,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isRecording
                            ? 'Listening for speech...'
                            : 'Not recording',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      if (_transcripts.isNotEmpty)
                        Text(
                          '${_transcripts.length} segments transcribed',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.vadService.isSpeechDetected)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'SPEECH',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Transcript list
          Expanded(
            flex: 2,
            child: _transcripts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No transcriptions yet...',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isRecording
                              ? 'Speak to see your words appear here'
                              : 'Start recording from the VAD screen',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _transcripts.length,
                    itemBuilder: (context, index) {
                      final transcript = _transcripts[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.blue.withOpacity(0.2),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Segment ${index + 1}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${transcript.length} chars',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              transcript,
                              style: const TextStyle(fontSize: 16),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),

          // Combined text view
          if (_transcripts.isNotEmpty)
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.05),
                border: Border(
                  top: BorderSide(color: Colors.grey.withOpacity(0.3)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Text(
                          'Combined Text',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_combinedText.split(' ').length} words',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SelectableText(
                        _combinedText,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: !_isRecording
          ? FloatingActionButton.extended(
              onPressed: () {
                Navigator.pop(context);
              },
              icon: const Icon(Icons.keyboard_voice),
              label: const Text('Start Recording'),
            )
          : null,
    );
  }

  @override
  void dispose() {
    _transcriptSubscription.cancel();
    _speechSubscription.cancel();
    _scrollController.dispose();
    super.dispose();
  }
}

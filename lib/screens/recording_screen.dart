import 'package:flutter/material.dart';
import '../services/audio_service.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  final _audioService = AudioService();
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isLoading = false;
  NoiseSuppressionLevel _currentNoiseSuppressionLevel =
      NoiseSuppressionLevel.medium;
  String? _lastRecordingPath;
  List<String> _recordings = [];

  // Set up listener for playback completion
  void _setupPlaybackCompletionListener() {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        if (!_audioService.isPlaying && _isPlaying) {
          setState(() {
            _isPlaying = false;
          });
        }

        if (_isPlaying) {
          // Keep checking if still playing
          _setupPlaybackCompletionListener();
        }
      }
    });
  }

  @override
  void dispose() {
    _audioService.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadRecordings();

    // Get initial noise suppression status
    _currentNoiseSuppressionLevel = _audioService.noiseSuppressionLevel;

    // Add listener for playback completion
    _setupPlaybackCompletionListener();
  }

  Future<void> _loadRecordings() async {
    final recordings = await _audioService.getAllRecordings();
    setState(() {
      _recordings = recordings;
    });
  }

  Future<void> _toggleRecording() async {
    final bool isCurrentlyRecording = await _audioService.isRecording();

    if (!isCurrentlyRecording) {
      await _audioService.startRecording();
    } else {
      // Get recording path when stopping recording
      _lastRecordingPath = await _audioService.stopRecording();
      await _loadRecordings(); // Refresh list
    }
    setState(() {
      _isRecording = !isCurrentlyRecording;
    });
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _audioService.stopPlayback();
    } else {
      await _audioService.playRecording(_lastRecordingPath);
    }
    setState(() {
      _isPlaying = !_isPlaying;
    });
  }

  // Cập nhật phương thức toggle
  void _toggleNoiseSuppression(NoiseSuppressionLevel level) async {
    bool isRecording = await _audioService.isRecording();
    if (isRecording) {
      // Không thể thay đổi trong khi ghi âm
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot change noise suppression while recording'),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    await _audioService.setNoiseSuppressionLevel(level);

    setState(() {
      _currentNoiseSuppressionLevel = level;
      _isLoading = false;
    });
  }

  // Show WebRTC settings dialog
  void _showWebRTCSettings() async {
    // Show loading dialog first
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text("Loading WebRTC settings..."),
            ],
          ),
        );
      },
    );

    // Get the information asynchronously
    final Map<String, String> info = await _audioService
        .getNoiseSuppessionInfo();

    // Close the loading dialog
    Navigator.of(context).pop();

    // Show the actual settings dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('WebRTC Settings'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: info.entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(entry.value),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // Show loading indicator
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Attempting to reinitialize WebRTC...'),
                ),
              );

              // Try to reinitialize WebRTC
              bool success = await _audioService.forceReinitializeWebRTC();

              // Show result
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success
                          ? 'WebRTC reinitialized successfully!'
                          : 'Failed to reinitialize WebRTC. Check logs for details.',
                    ),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
              }
            },
            child: const Text('Reinitialize WebRTC'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Recorder'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'WebRTC Settings',
            onPressed: _showWebRTCSettings,
          ),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Recording status
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _isRecording
                          ? Colors.red.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          _isRecording ? Icons.mic : Icons.mic_off,
                          size: 48,
                          color: _isRecording ? Colors.red : Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isRecording ? 'Recording...' : 'Not Recording',
                          style: const TextStyle(fontSize: 18),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Record button
                  ElevatedButton.icon(
                    onPressed: _toggleRecording,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                    ),
                    icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                    label: Text(
                      _isRecording ? 'Stop Recording' : 'Start Recording',
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Noise Suppression Settings
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Noise Suppression Settings',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildNoiseSuppressionRadio(
                            NoiseSuppressionLevel.off,
                            'Off',
                            'No noise suppression',
                          ),
                          _buildNoiseSuppressionRadio(
                            NoiseSuppressionLevel.low,
                            'Low',
                            'Slight noise reduction',
                          ),
                          _buildNoiseSuppressionRadio(
                            NoiseSuppressionLevel.medium,
                            'Medium',
                            'Medium noise reduction',
                          ),
                          _buildNoiseSuppressionRadio(
                            NoiseSuppressionLevel.high,
                            'High',
                            'Strong noise reduction',
                          ),
                          _buildNoiseSuppressionRadio(
                            NoiseSuppressionLevel.veryHigh,
                            'Very High',
                            'Maximum noise reduction',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Playback for last recording
                  if (_lastRecordingPath != null) ...[
                    const Text('Last Recording:'),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _togglePlayback,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                      icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        _isPlaying ? 'Stop Playback' : 'Play Recording',
                      ),
                    ),

                    if (_lastRecordingPath != null)
                      Text(
                        'File: ${_lastRecordingPath!.split('/').last}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                  ],

                  const SizedBox(height: 32),

                  // List of all recordings
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Text(
                          'Recordings:',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        height: 250, // Fixed height for recordings list
                        child: _recordings.isEmpty
                            ? const Center(child: Text('No recordings yet'))
                            : ListView.builder(
                                itemCount: _recordings.length,
                                itemBuilder: (context, index) {
                                  final path = _recordings[index];
                                  final fileName = path.split('/').last;
                                  return ListTile(
                                    title: Text(fileName),
                                    leading: const Icon(Icons.audio_file),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.play_arrow),
                                          onPressed: () async {
                                            // First stop any current playback
                                            if (_isPlaying) {
                                              await _audioService
                                                  .stopPlayback();
                                              setState(() {
                                                _isPlaying = false;
                                              });
                                            }

                                            // Set the current recording path
                                            await _audioService.setRecording(
                                              path,
                                            );
                                            setState(() {
                                              _lastRecordingPath = path;
                                            });

                                            // Play the recording
                                            await _audioService.playRecording(
                                              path,
                                            );
                                            setState(() {
                                              _isPlaying = true;
                                            });
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete),
                                          onPressed: () async {
                                            await _audioService.deleteRecording(
                                              path,
                                            );
                                            _loadRecordings();
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Show loading indicator while changing settings
          if (_isLoading)
            Container(
              color: Colors.black45,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  // Widget tạo radio button cho mỗi mức độ lọc
  Widget _buildNoiseSuppressionRadio(
    NoiseSuppressionLevel level,
    String title,
    String subtitle,
  ) {
    return FutureBuilder<bool>(
      future: _audioService.isRecording(),
      builder: (context, snapshot) {
        final bool isRecording = snapshot.data ?? false;

        return ListTile(
          title: Text(title),
          subtitle: Text(subtitle),
          leading: Radio<NoiseSuppressionLevel>(
            value: level,
            groupValue: _currentNoiseSuppressionLevel,
            onChanged: (NoiseSuppressionLevel? value) {
              if (value != null && !isRecording) {
                _toggleNoiseSuppression(value);
              }
            },
          ),
          enabled: !isRecording,
          onTap: isRecording
              ? null
              : () {
                  _toggleNoiseSuppression(level);
                },
        );
      },
    );
  }

  // Cập nhật phương thức test
}

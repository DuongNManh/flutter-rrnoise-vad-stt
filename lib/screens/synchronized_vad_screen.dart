import 'package:flutter/material.dart';
import 'package:flutter_google_stt/models/speech_segment.dart';
import 'package:flutter_google_stt/services/synchronized_vad_service.dart';
import 'package:flutter_google_stt/services/google_stt_service.dart';
import '../services/stt_test_service.dart';

class SynchronizedVADScreen extends StatefulWidget {
  const SynchronizedVADScreen({Key? key}) : super(key: key);

  @override
  State<SynchronizedVADScreen> createState() => _SynchronizedVADScreenState();
}

class _SynchronizedVADScreenState extends State<SynchronizedVADScreen> {
  late SynchronizedVADService _vadService;
  double _currentConfidence = 0.0;
  bool _isSpeechActive = false;
  double _audioLevel = 0.0;
  List<SpeechSegment> _segments = [];
  String _fullTranscript = '';
  
  // Thêm các biến cho ngôn ngữ
  final List<LanguageOption> _languageOptions = GoogleSTTService.getSupportedLanguageOptions();
  LanguageOption? _selectedMainLanguage;
  List<LanguageOption> _selectedAlternativeLanguages = [];

  @override
  void initState() {
    super.initState();
    _initializeLanguages();
    _initializeVADService();
  }
  
  void _initializeLanguages() {
    // Mặc định ngôn ngữ chính là tiếng Anh (US)
    _selectedMainLanguage = _languageOptions.firstWhere(
      (lang) => lang.code == 'en-US',
      orElse: () => _languageOptions.first,
    );
    
    // Mặc định ngôn ngữ phụ là tiếng Việt
    _selectedAlternativeLanguages = [
      _languageOptions.firstWhere(
        (lang) => lang.code == 'vi-VN',
        orElse: () => _languageOptions[1],
      ),
    ];
  }

  void _initializeVADService() {
    final sttService = STTTestService.instance;
    _vadService = SynchronizedVADService(sttService: sttService);

    if (sttService == null && mounted) {
      Future.microtask(() {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Google STT service not available. Please configure API key in settings.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      });
    }

    _vadService.confidenceStream.listen((confidence) {
      setState(() {
        _currentConfidence = confidence;
      });
    });

    _vadService.speechStateStream.listen((isActive) {
      setState(() {
        _isSpeechActive = isActive;
      });
    });

    _vadService.audioLevelStream.listen((level) {
      setState(() {
        _audioLevel = level;
      });
    });

    _vadService.transcriptStream.listen((segment) {
      setState(() {
        _segments = List.from(_vadService.speechSegments);
        _fullTranscript = _vadService.getFullTranscript();
      });

      if (segment.hasTranscript) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('New transcript: "${segment.transcript}"'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });

    _vadService.addListener(() {
      setState(() {
        _segments = List.from(_vadService.speechSegments);
        _fullTranscript = _vadService.getFullTranscript();
      });
    });
    
    // Cập nhật ngôn ngữ nếu STT service có sẵn
    if (sttService != null) {
      final mainCode = _selectedMainLanguage?.code ?? 'en-US';
      final altCodes = _selectedAlternativeLanguages.map((e) => e.code).toList();
      sttService.setLanguages(mainCode, altCodes);
    }
  }
  
  // Thêm phương thức để cập nhật ngôn ngữ
  void _updateLanguageSettings() {
    if (_selectedMainLanguage != null) {
      final mainCode = _selectedMainLanguage!.code;
      final altCodes = _selectedAlternativeLanguages.map((e) => e.code).toList();
      _vadService.updateLanguageSettings(mainCode, altCodes);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Language updated: ${_selectedMainLanguage!.nameEn} + ${_selectedAlternativeLanguages.length} alternative(s)'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _startRecording() async {
    await _vadService.startRecording();
  }

  Future<void> _stopRecording() async {
    await _vadService.stopRecording();
  }

  @override
  void dispose() {
    _vadService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Synchronized VAD Test'),
        actions: [
          // Thêm nút cấu hình ngôn ngữ
          IconButton(
            icon: const Icon(Icons.language),
            onPressed: () => _showLanguageDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: _vadService.isRecording
                ? null
                : () {
                    _vadService.clearAll();
                    setState(() {
                      _segments.clear();
                      _fullTranscript = '';
                      _currentConfidence = 0.0;
                      _audioLevel = 0.0;
                    });
                  },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildRecordingControls(),
            const SizedBox(height: 12),
            _buildLanguageDisplay(), // Thêm widget hiển thị ngôn ngữ đã chọn
            const SizedBox(height: 12),
            _buildStatusIndicators(),
            const SizedBox(height: 20),
            _buildAudioLevelIndicator(),
            const SizedBox(height: 20),
            _buildFullTranscript(),
            const SizedBox(height: 20),
            Expanded(child: _buildSegmentsList()),
          ],
        ),
      ),
    );
  }
  
  // Thêm widget hiển thị ngôn ngữ đã chọn
  Widget _buildLanguageDisplay() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.language, size: 20, color: Colors.blue),
          const SizedBox(width: 8),
          Text(
            'Main: ${_selectedMainLanguage?.nameEn ?? "None"}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 16),
          Text(
            'Alt: ${_selectedAlternativeLanguages.map((e) => e.nameEn).join(", ")}',
            style: const TextStyle(fontStyle: FontStyle.italic),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
  
  // Thêm dialog để chọn ngôn ngữ
  void _showLanguageDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Select Languages'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Main Language:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<LanguageOption>(
                    isExpanded: true,
                    value: _selectedMainLanguage,
                    items: _languageOptions.map((language) {
                      return DropdownMenuItem<LanguageOption>(
                        value: language,
                        child: Text(language.displayName),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedMainLanguage = value;
                        
                        // Đảm bảo ngôn ngữ phụ không trùng với ngôn ngữ chính
                        _selectedAlternativeLanguages.removeWhere(
                          (lang) => lang.code == value?.code
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Alternative Languages:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 200,
                    child: ListView(
                      children: _languageOptions
                          .where((lang) => lang != _selectedMainLanguage)
                          .map((language) {
                        return CheckboxListTile(
                          title: Text(language.displayName),
                          value: _selectedAlternativeLanguages.contains(language),
                          onChanged: (selected) {
                            setState(() {
                              if (selected == true) {
                                if (!_selectedAlternativeLanguages.contains(language)) {
                                  _selectedAlternativeLanguages.add(language);
                                }
                              } else {
                                _selectedAlternativeLanguages.remove(language);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                child: const Text('CANCEL'),
                onPressed: () => Navigator.pop(context),
              ),
              TextButton(
                child: const Text('APPLY'),
                onPressed: () {
                  Navigator.pop(context);
                  setState(() {
                    // Cập nhật state trong màn hình chính
                    this.setState(() {});
                  });
                  _updateLanguageSettings();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRecordingControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ElevatedButton(
          onPressed: _vadService.isRecording ? null : _startRecording,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
          child: const Text('Start Recording'),
        ),
        const SizedBox(width: 20),
        ElevatedButton(
          onPressed: _vadService.isRecording ? _stopRecording : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
          child: const Text('Stop Recording'),
        ),
      ],
    );
  }

  Widget _buildStatusIndicators() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatusItem(
                  'Recording',
                  _vadService.isRecording ? 'Active' : 'Inactive',
                  _vadService.isRecording ? Colors.green : Colors.grey,
                ),
                _buildStatusItem(
                  'Speech',
                  _isSpeechActive ? 'Detected' : 'Silent',
                  _isSpeechActive ? Colors.blue : Colors.grey,
                ),
                _buildStatusItem(
                  'Confidence',
                  '${(_currentConfidence * 100).toInt()}%',
                  _getConfidenceColor(_currentConfidence),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatusItem(
                  'Segments',
                  '${_segments.length}',
                  Colors.purple,
                ),
                _buildStatusItem(
                  'Buffer',
                  '${_vadService.availableBufferDuration.inSeconds}s',
                  Colors.orange,
                ),
                _buildStatusItem(
                  'Processing',
                  '${_segments.where((s) => s.isProcessing).length}',
                  Colors.amber,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Color _getConfidenceColor(double confidence) {
    if (confidence > 0.7) return Colors.green;
    if (confidence > 0.4) return Colors.orange;
    return Colors.red;
  }

  Widget _buildAudioLevelIndicator() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              'Audio Level',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _audioLevel / 100,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(
                _audioLevel > 50 ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(height: 4),
            Text('${_audioLevel.toInt()}%'),
          ],
        ),
      ),
    );
  }

  Widget _buildFullTranscript() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Full Transcript',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _fullTranscript.isEmpty ? 'No transcript yet.' : _fullTranscript,
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentsList() {
    if (_segments.isEmpty) {
      return const Center(child: Text('No segments yet.'));
    }

    return ListView.builder(
      itemCount: _segments.length,
      itemBuilder: (context, index) {
        final segment = _segments[index];
        return Card(
          child: ListTile(
            leading: Icon(
              segment.hasTranscript
                  ? Icons.check_circle
                  : Icons.hourglass_empty,
              color: segment.hasTranscript ? Colors.green : Colors.grey,
            ),
            title: Text(
              segment.hasTranscript
                  ? (segment.transcript ?? 'Processing...')
                  : 'Processing...',
            ),
            subtitle: Text(
              'Duration: ${segment.duration.inMilliseconds}ms\nConf: ${(segment.confidence * 100).toStringAsFixed(1)}%',
            ),
          ),
        );
      },
    );
  }
}

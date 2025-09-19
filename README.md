# Flutter Google STT

**các bước cần làm để triển khai MVP STT (speech-to-text) trong app Flutter**:

---

## 📝 Các bước thực hiện

### 1. Chuẩn bị môi trường

* Quyết định backend STT ban đầu: **Google Speech-to-Text API** (dùng free credit)
* Tạo **Google Cloud Project**, bật **Speech-to-Text API**, lấy **API Key / Service Account JSON**.
* Thêm package Flutter để gọi API (ví dụ `googleapis`, `http`, hoặc gRPC client).

---

### 2. Xử lý audio tại client (Flutter app)

* Thu âm bằng `flutter_sound` hoặc `record` plugin.
* Chia audio thành **chunk nhỏ** (5–10 giây) để giảm latency.
* Tiền xử lý:

  * **Noise reduction** (lọc nhiễu cơ bản).
  * **Silence detection** (loại bỏ quãng lặng không cần thiết).
  * **Format chuẩn**: PCM LINEAR16 hoặc FLAC, 16kHz–48kHz mono.

---

**rnnoise** source rồi. Đây là lib C (DSP + RNN) để **noise suppression** chạy **local on-device**.

Để dùng được trong Flutter thì bạn sẽ **không gọi trực tiếp mấy file `.c` đâu**, mà cần **build ra thư viện động (.so / .a / .dll)** rồi wrap vào Flutter qua **FFI hoặc Platform Channel**.

---

### 1. Những file nào quan trọng để build rnnoise

Trong folder bạn list:

* **Core DSP + RNN**

  * `denoise.c / denoise.h` → main noise suppression API (`rnnoise_process_frame`)
  * `rnn.c / rnn.h` → model runner
  * `nnet.c / nnet.h / nnet_default.c` → neural net weights
  * `rnnoise_tables.c` → pre-trained model weights
* **Helper / dependencies**

  * `kiss_fft.c / kiss_fft.h / _kiss_fft_guts.h` → FFT implementation
  * `celt_lpc.c / celt_lpc.h` → linear predictive coding
  * `vec_*.h` → SIMD optimizations (AVX, NEON)
* **Not needed for runtime**

  * `dump_features.c`, `dump_rnnoise_tables.c`, `rnn_train.py`, `write_weights.c`, `parse_lpcnet_weights.c` → training / debug tools

👉 Với Flutter app (chạy model đã pre-trained), bạn chỉ cần:

* `denoise.c`
* `rnn.c`
* `nnet.c` (với `nnet_default.c` chứa weights mặc định)
* `kiss_fft.c`
* `celt_lpc.c`
* cùng các `.h` liên quan

---

### 2. Build thành native library

#### 🔹 Android (NDK)

* Viết `Android.mk` hoặc `CMakeLists.txt` → compile thành `librnnoise.so`.
* Dùng `ndk-build` hoặc Gradle với CMake.

Ví dụ `CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.4.1)

add_library(rnnoise SHARED
    denoise.c
    rnn.c
    nnet.c
    kiss_fft.c
    celt_lpc.c
    rnnoise_tables.c)

target_include_directories(rnnoise PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
```

#### 🔹 iOS

* Tạo Xcode static lib project, build thành `.a` (libRNNoise.a).
* Link vào Flutter iOS Runner project.

---

### 3. Expose API ra Flutter

Trong `denoise.h` có hàm chính:

```c
typedef struct RNNState RNNState;

RNNState *rnnoise_create(void);
void rnnoise_destroy(RNNState *st);
float rnnoise_process_frame(RNNState *st, float *out, const float *in);
```

* `rnnoise_process_frame` xử lý 1 **frame 480 mẫu** (30ms @ 16kHz).
* Input/Output là float array (mono).

Flutter gọi qua **Dart FFI**:

```dart
final rnnoiseLib = DynamicLibrary.open("librnnoise.so");

typedef rnnoise_create_c = Pointer<Void> Function();
typedef rnnoise_create_dart = Pointer<Void> Function();
final rnnoiseCreate = rnnoiseLib
    .lookupFunction<rnnoise_create_c, rnnoise_create_dart>("rnnoise_create");
```

---

### 4. Workflow trong Flutter

1. Ghi âm mic → PCM16 → convert sang float 16kHz mono.
2. Chunk thành **480 samples** → gọi `rnnoise_process_frame`.
3. Nhận frame sạch → append lại thành audio stream.
4. Stream sạch này mới gửi đi **Google STT / Whisper**.


---

### 3. Gửi dữ liệu đến API

Có 2 chế độ chính:

* **Streaming** (real-time): app gửi audio chunk liên tục đến Google STT → trả transcript gần như live.
* **Batch (async)**: app thu xong file dài → gửi cả file → nhận transcript hoàn chỉnh.

👉 MVP của bạn hướng đến **cuộc họp dài**, vậy hợp lý nhất là:

* Gửi **chunk theo thời gian thực** (Streaming API).
* Lưu transcript raw vào DB/local để hậu xử lý sau.

---

### 4. Hậu xử lý transcript

* Gom các chunk transcript → thành văn bản thô.
* Làm **cleanup**: sửa chính tả, loại bỏ từ thừa, lọc nhiễu.
* Có thể chạy **speaker diarization** (nhận diện người nói) nếu cần phân biệt ai đang nói.

---

### 5. Tóm tắt & tạo task

* Sau khi có transcript “sạch”:

  * Gửi qua **LLM / NLP service** (ví dụ OpenAI GPT, Gemini, hoặc model tự train) để tóm tắt nội dung.
  * Sinh **action items / tasks** từ nội dung.

---

### 6. Tích hợp UI Flutter

* UI hiển thị transcript **theo thời gian thực** (subtitle style).
* Có chế độ xem **toàn bộ transcript sau cuộc họp**.
* Cho phép **xuất bản tóm tắt + tasks** (PDF, email, share).

---

### 7. Tối ưu hóa chi phí

* Google STT free credit → test MVP.
* Sau đó so sánh chi phí Google STT vs Whisper API (OpenAI hoặc self-host).
* Cân nhắc **hybrid**:

  * Google STT cho real-time.
  * Whisper cho batch cleanup (offline rẻ hơn).

---

👉 Tổng quát flow:

🎤 Thu âm → 🎛️ Xử lý noise/silence → 📤 Gửi chunk (Streaming API) → 📄 Transcript raw → 🧹 Cleanup → 📑 Tóm tắt + Tasks → 📱 Hiển thị trong app

---

## Voice Activity Detection (VAD) Implementation

This project includes two Voice Activity Detection (VAD) implementations:

### 1. Simulated VAD

The initial implementation uses a basic amplitude-based approach to detect voice activity:

* Uses WebRTC audio processing
* Detects speech based on audio amplitude thresholds
* Available in `VadService` and `VadTestingScreen`

### 2. Package-based VAD (Silero VAD)

A more advanced implementation using the `vad` Flutter package that provides ML-based VAD:

* Uses Silero VAD models (v4 and v5)
* More accurate speech detection
* Cross-platform support (iOS, Android, Web)
* Available in `PackageVadService` and `PackageVADScreen`

### How to Use the Package-based VAD

Our `PackageVadService` implementation provides:

* **Real-time audio visualization**: Waveforms and confidence levels
* **Automatic speech segmentation**: Captures individual utterances
* **Audio recording management**: Records and saves speech segments
* **Event logging**: Tracks all speech detection events

The implementation exposes several streams for UI updates:

```dart
// Audio level updates for visualization
vadService.audioLevelStream.listen((level) {
  // Update waveform UI
});

// Speech detection state changes
vadService.speechDetectedStream.listen((isSpeech) {
  // Update UI to show active speech state
});

// Access to waveform data
vadService.waveformStream.listen((waveformData) {
  // Update detailed waveform visualization
});
```

The VAD handler provides these core event streams:

```dart
// When speech is first detected
vadHandler.onSpeechStart.listen((_) {
  print('Speech detected');
});

// When speech is confirmed (not a misfire)
vadHandler.onRealSpeechStart.listen((_) {
  print('Real speech confirmed');
});

// When speech ends
vadHandler.onSpeechEnd.listen((samples) {
  print('Speech ended, processing audio segment');
});

// For processing each audio frame
vadHandler.onFrameProcessed.listen((frameData) {
  // Update UI with confidence score: frameData.isSpeech
  // Process audio data: frameData.frame
});
```

### Web Implementation Notes

For web support, the following scripts are added to `web/index.html`:

```html
<!-- In <head> -->
<script src="assets/packages/vad/assets/ort.js"></script>
<script src="enable-threads.js"></script>

<!-- Before </body> -->
<script src="assets/packages/vad/assets/bundle.min.js" defer></script>
<script src="assets/packages/vad/assets/vad_web.js" defer></script>
```

The `enable-threads.js` script helps enable WebAssembly threading for local development.

### VAD Configuration Options

```dart
await vadHandler.startListening(
  model: 'v5',                    // 'legacy' or 'v5'
  frameSamples: 512,              // 512 for v5, 1536 for legacy
  positiveSpeechThreshold: 0.5,   // Speech detection threshold
  negativeSpeechThreshold: 0.3,   // Silence detection threshold
  minSpeechFrames: 2,             // Minimum frames for valid speech
);
```

### The PackageVADScreen UI

The `PackageVADScreen` component provides a comprehensive UI for testing and visualizing VAD:

* **Status Indicator**: Shows active speech detection state
* **Audio Waveform**: Real-time visualization of audio levels
* **Event Logs**: Chronological list of all VAD events with timestamps
* **Audio Segments**: List of captured speech segments with playback options
* **Control Panel**: Start/stop recording and adjust VAD settings

To include this screen in your application:

```dart
Navigator.push(
  context,
  MaterialPageRoute(builder: (context) => const PackageVADScreen()),
);
```

### Integration with STT Pipeline

To integrate the VAD service with a Speech-to-Text pipeline:

1. Start the VAD service and recording
2. Listen to the `onSpeechEnd` event to get completed audio segments
3. Send these segments to your STT service
4. Process the transcription results

Example:

```dart
// Initialize VAD service
final vadService = PackageVadService();

// Setup STT processing
vadHandler.onSpeechEnd.listen((samples) {
  // Get the latest completed audio segment
  final latestSegment = vadService.segments.last;
  
  // Send to STT service
  sendAudioToSTT(latestSegment.path);
});
```

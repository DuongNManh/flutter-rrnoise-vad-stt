import 'dart:async';
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Helper class to check WebRTC compatibility and features
class WebRTCCompatibility {
  /// Checks if the device supports WebRTC noise suppression
  /// Uses a more robust approach to detect actual noise suppression support
  static Future<bool> supportsNoiseSuppression() async {
    try {
      // Try to create a media stream with noise suppression using only boolean values
      final mediaConstraints = <String, dynamic>{
        'audio': {
          'noiseSuppression': true,
          'echoCancellation':
              false, // Disable echo cancellation to isolate NS test
          'autoGainControl': false, // Disable AGC to isolate NS test
          'googNoiseSuppression': true, // Google-specific parameter
          'googEchoCancellation': false,
          'googAutoGainControl': false,
        },
        'video': false,
      };

      final stream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );

      // Check if we got audio tracks
      final hasAudioTracks = stream.getAudioTracks().isNotEmpty;
      bool nsSupported = false;

      if (hasAudioTracks) {
        // Check if noise suppression is actually applied
        try {
          final audioTrack = stream.getAudioTracks().first;
          final settings = audioTrack.getSettings();

          // Debug output
          print('WebRTC Track Settings:');
          settings.forEach((key, value) {
            print(' - $key: $value');
          });

          // Check if noise suppression is reported as supported/enabled
          final nsValue = settings['noiseSuppression'];
          if (nsValue != null) {
            // If it's explicitly true or a non-zero value (for devices reporting integers)
            if (nsValue == true || (nsValue is int && nsValue > 0)) {
              nsSupported = true;
            }
          }

          // Some implementations use Google-specific keys
          final googleNsValue = settings['googNoiseSuppression'];
          if (googleNsValue != null) {
            if (googleNsValue == true ||
                (googleNsValue is int && googleNsValue > 0)) {
              nsSupported = true;
            }
          }
        } catch (e) {
          print('Error checking track settings: $e');
        }
      }

      // Clean up
      for (var track in stream.getAudioTracks()) {
        track.stop();
      }
      stream.dispose();

      return nsSupported;
    } catch (e) {
      print('Error checking noise suppression support: $e');
      return false;
    }
  }

  /// Gets information about the WebRTC implementation
  static Future<Map<String, dynamic>> getImplementationDetails() async {
    final details = <String, dynamic>{
      'platform': Platform.operatingSystem,
      'version': Platform.operatingSystemVersion,
      'features': <String, bool>{},
    };

    try {
      details['features']['noiseSuppression'] =
          await supportsNoiseSuppression();
    } catch (e) {
      details['features']['noiseSuppression'] = false;
      details['error'] = e.toString();
    }

    return details;
  }
}

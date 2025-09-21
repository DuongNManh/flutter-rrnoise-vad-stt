import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Enhanced waveform painter for better audio visualization
class WaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color activeColor;
  final Color inactiveColor;
  final bool isSpeechDetected;
  final double confidenceLevel;
  final bool showGradient;
  final bool showSmoothing;
  final AnimationController? rippleController;

  WaveformPainter({
    required this.samples,
    required this.activeColor,
    required this.inactiveColor,
    required this.isSpeechDetected,
    required this.confidenceLevel,
    this.showGradient = true,
    this.showSmoothing = true,
    this.rippleController,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    // Smooth the samples if enabled
    final processedSamples = showSmoothing ? _smoothSamples(samples) : samples;

    // Calculate circle spacing and sizing
    final circleSpacing = size.width / processedSamples.length;
    final maxRadius = math.min(circleSpacing * 0.4, size.height * 0.15);
    final centerY = size.height / 2;

    // Draw water drops/circles
    for (int i = 0; i < processedSamples.length; i++) {
      final x = i * circleSpacing + circleSpacing / 2;
      final normalizedHeight = processedSamples[i].clamp(0.0, 1.0);

      // Add confidence-based size modulation
      final confidenceModulation = isSpeechDetected
          ? 1.0 +
                (confidenceLevel * 0.5) // Boost size when confident
          : 1.0;

      final baseRadius = normalizedHeight * maxRadius * confidenceModulation;

      // Create water drop effect with multiple circles
      _drawWaterDrop(
        canvas,
        Offset(x, centerY),
        baseRadius,
        normalizedHeight,
        i,
      );
    }

    // Draw subtle baseline
    final baselinePaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.2)
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      baselinePaint,
    );
  }

  /// Draw a water drop effect with multiple layered circles
  void _drawWaterDrop(
    Canvas canvas,
    Offset center,
    double radius,
    double intensity,
    int index,
  ) {
    if (radius <= 0) return;

    // Create gradient for water effect
    final dropGradient = RadialGradient(
      center: const Alignment(-0.3, -0.4), // Light source from top-left
      radius: 1.0,
      colors: isSpeechDetected
          ? [
              Colors.white.withValues(alpha: 0.8),
              activeColor.withValues(alpha: 0.9),
              activeColor.withValues(alpha: 0.6),
              activeColor.withValues(alpha: 0.3),
            ]
          : [
              Colors.white.withValues(alpha: 0.5),
              inactiveColor.withValues(alpha: 0.7),
              inactiveColor.withValues(alpha: 0.4),
              inactiveColor.withValues(alpha: 0.2),
            ],
      stops: const [0.0, 0.3, 0.7, 1.0],
    );

    // Main water drop circle
    final dropPaint = Paint()
      ..shader = dropGradient.createShader(
        Rect.fromCircle(center: center, radius: radius),
      )
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, radius, dropPaint);

    // Add ripple effect for high-intensity drops
    if (intensity > 0.7 && isSpeechDetected) {
      _drawRippleEffect(canvas, center, radius, intensity, index);
    }

    // Add highlight for 3D water effect
    final highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: intensity * 0.6)
      ..style = PaintingStyle.fill;

    final highlightRadius = radius * 0.3;
    final highlightCenter = Offset(
      center.dx - radius * 0.2,
      center.dy - radius * 0.3,
    );

    canvas.drawCircle(highlightCenter, highlightRadius, highlightPaint);

    // Add subtle shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);

    final shadowCenter = Offset(center.dx + 1, center.dy + 1);
    canvas.drawCircle(shadowCenter, radius * 0.8, shadowPaint);
  }

  /// Draw animated ripple effect for high-intensity water drops
  void _drawRippleEffect(
    Canvas canvas,
    Offset center,
    double radius,
    double intensity,
    int index,
  ) {
    if (rippleController == null) return;

    final animationValue = rippleController!.value;
    final animationOffset = animationValue + (index * 0.2); // Stagger animation

    // Create multiple ripple rings
    for (int ring = 0; ring < 3; ring++) {
      final rippleRadius =
          radius +
          (ring * 8.0) +
          (math.sin(animationOffset * 2 * math.pi + ring * 0.5) * 4.0);

      final rippleAlpha =
          (intensity * 0.3) *
          (1.0 - (ring / 3.0)) *
          math.max(0.0, math.sin(animationOffset * 4 * math.pi));

      if (rippleAlpha > 0.05) {
        final ripplePaint = Paint()
          ..color = activeColor.withValues(alpha: rippleAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;

        canvas.drawCircle(center, rippleRadius, ripplePaint);
      }
    }
  }

  /// Apply smoothing to samples to reduce noise
  List<double> _smoothSamples(List<double> rawSamples) {
    if (rawSamples.length <= 2) return rawSamples;

    final smoothed = <double>[];
    const windowSize = 3;

    for (int i = 0; i < rawSamples.length; i++) {
      double sum = 0.0;
      int count = 0;

      // Moving average within window
      for (
        int j = math.max(0, i - windowSize ~/ 2);
        j <= math.min(rawSamples.length - 1, i + windowSize ~/ 2);
        j++
      ) {
        sum += rawSamples[j];
        count++;
      }

      smoothed.add(sum / count);
    }

    return smoothed;
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.isSpeechDetected != isSpeechDetected ||
        oldDelegate.confidenceLevel != confidenceLevel ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        // Always repaint for ripple animation when speech is detected
        (isSpeechDetected && samples.any((sample) => sample > 0.7));
  }
}

/// Enhanced waveform widget with animations and better performance
class EnhancedWaveform extends StatefulWidget {
  final List<double> samples;
  final double height;
  final double width;
  final Color activeColor;
  final Color inactiveColor;
  final bool isSpeechDetected;
  final double confidenceLevel;
  final bool enableAnimation;
  final bool showGradient;
  final bool showSmoothing;

  const EnhancedWaveform({
    super.key,
    required this.samples,
    required this.height,
    required this.width,
    required this.activeColor,
    required this.inactiveColor,
    required this.isSpeechDetected,
    required this.confidenceLevel,
    this.enableAnimation = true,
    this.showGradient = true,
    this.showSmoothing = true,
  });

  @override
  State<EnhancedWaveform> createState() => _EnhancedWaveformState();
}

class _EnhancedWaveformState extends State<EnhancedWaveform>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rippleController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    if (widget.enableAnimation) {
      _pulseController = AnimationController(
        duration: const Duration(milliseconds: 800),
        vsync: this,
      );

      // Continuous ripple animation for water drops
      _rippleController = AnimationController(
        duration: const Duration(milliseconds: 2000),
        vsync: this,
      );

      _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
      );

      // Start continuous ripple animation
      if (widget.isSpeechDetected) {
        _rippleController.repeat();
      }
    }
  }

  @override
  void didUpdateWidget(EnhancedWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.enableAnimation) {
      // Trigger pulse animation when speech is detected
      if (widget.isSpeechDetected && !oldWidget.isSpeechDetected) {
        _pulseController.repeat(reverse: true);
        _rippleController.repeat();
      } else if (!widget.isSpeechDetected && oldWidget.isSpeechDetected) {
        _pulseController.stop();
        _pulseController.reset();
        _rippleController.stop();
        _rippleController.reset();
      }
    }
  }

  @override
  void dispose() {
    if (widget.enableAnimation) {
      _pulseController.dispose();
      _rippleController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget waveform = AnimatedBuilder(
      animation: widget.enableAnimation
          ? _rippleController
          : Listenable.merge([]),
      builder: (context, child) {
        return CustomPaint(
          size: Size(widget.width, widget.height),
          painter: WaveformPainter(
            samples: widget.samples,
            activeColor: widget.activeColor,
            inactiveColor: widget.inactiveColor,
            isSpeechDetected: widget.isSpeechDetected,
            confidenceLevel: widget.confidenceLevel,
            showGradient: widget.showGradient,
            showSmoothing: widget.showSmoothing,
            rippleController: widget.enableAnimation ? _rippleController : null,
          ),
        );
      },
    );

    // Add pulse animation if enabled
    if (widget.enableAnimation) {
      return AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: widget.isSpeechDetected ? _pulseAnimation.value : 1.0,
            child: waveform,
          );
        },
      );
    }

    return waveform;
  }
}

/// Performance-optimized waveform configuration
class WaveformConfig {
  static const int maxSamples = 100; // Limit samples for performance
  static const int uiUpdateThrottleMs = 50; // UI update frequency
  static const double confidenceThreshold = 0.05; // Minimum change to update
  static const bool enableGradient = true;
  static const bool enableSmoothing = true;
  static const bool enableAnimation = true;

  /// Optimize samples for better performance
  static List<double> optimizeSamples(List<double> rawSamples) {
    if (rawSamples.length <= maxSamples) return rawSamples;

    // Downsample by taking every nth sample
    final step = rawSamples.length / maxSamples;
    final optimized = <double>[];

    for (int i = 0; i < maxSamples; i++) {
      final index = (i * step).floor();
      if (index < rawSamples.length) {
        optimized.add(rawSamples[index]);
      }
    }

    return optimized;
  }

  /// Get performance-appropriate configuration based on device capabilities
  static WaveformPerformanceConfig getPerformanceConfig() {
    // In a real app, you might detect device capabilities here
    return const WaveformPerformanceConfig(
      maxSamples: maxSamples,
      enableGradient: enableGradient,
      enableSmoothing: enableSmoothing,
      enableAnimation: enableAnimation,
      updateThrottleMs: uiUpdateThrottleMs,
    );
  }
}

/// Configuration class for waveform performance settings
class WaveformPerformanceConfig {
  final int maxSamples;
  final bool enableGradient;
  final bool enableSmoothing;
  final bool enableAnimation;
  final int updateThrottleMs;

  const WaveformPerformanceConfig({
    required this.maxSamples,
    required this.enableGradient,
    required this.enableSmoothing,
    required this.enableAnimation,
    required this.updateThrottleMs,
  });
}

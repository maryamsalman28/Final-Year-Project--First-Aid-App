import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class BurnImageGuideScreen extends StatefulWidget {
  final File imageFile;
  final String label; // e.g., "First-degree burn"

  const BurnImageGuideScreen({
    super.key,
    required this.imageFile,
    required this.label,
  });

  @override
  State<BurnImageGuideScreen> createState() => _BurnImageGuideScreenState();
}

class _BurnImageGuideScreenState extends State<BurnImageGuideScreen> {
  Rect _rectFrac = const Rect.fromLTWH(0.3, 0.3, 0.4, 0.25); // x,y,w,h in [0..1]
  int _step = 0;
  static const double _handle = 18;

  late final List<_GuideStep> _steps = _stepsFor(widget.label);

  bool _isPositiveDetection(String label) {
    final l = label.toLowerCase();
    return l.contains('first') || l.contains('1st') ||
        l.contains('second') || l.contains('2nd') ||
        l.contains('third') || l.contains('3rd');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSteps = _steps.isNotEmpty;
    final currentMode = hasSteps ? _steps[_step].mode : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Guidance (Image)'),
        actions: [
          IconButton(
            tooltip: 'Reset overlay',
            onPressed: () => setState(() => _rectFrac = const Rect.fromLTWH(0.3, 0.3, 0.4, 0.25)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _ImageWithOverlay(
              imageFile: widget.imageFile,
              rectFrac: _rectFrac,
              onRectFracChanged: (r) => setState(() => _rectFrac = r),
              handle: _handle,
              animationMode: currentMode, // animated cue for the current step (or null)
            ),
          ),

          if (hasSteps)
            _StepCard(
              step: _steps[_step],
              total: _steps.length,
              index: _step,
              onPrev: _step > 0 ? () => setState(() => _step -= 1) : null,
              onNext: _step < _steps.length - 1 ? () => setState(() => _step += 1) : null,
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'No AR steps are available for this result.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          const _DisclaimerBar(),
        ],
      ),
    );
  }

  List<_GuideStep> _stepsFor(String label) {
    // If someone ever routes here with a non burn label, return no steps.
    if (!_isPositiveDetection(label)) {
      return <_GuideStep>[];
    }

    final l = label.toLowerCase();

    if (l.contains('third')) {
      // Third degree — warn + light cover
      return [
        _GuideStep(
          title: 'Emergency Care Needed',
          body:
              'This may be a third-degree burn. Call emergency services now. '
              'Keep the person warm and still. Do not apply ointments or remove stuck clothing.',
          icon: Icons.local_hospital,
          usesOverlay: true,
          mode: 'warn',
        ),
        _GuideStep(
          title: 'Cover Lightly',
          body:
              'If safe to do so, loosely cover the area with a clean, dry cloth. '
              'Avoid pressure on the wound.',
          icon: Icons.health_and_safety,
          usesOverlay: true,
          mode: 'bandage',
        ),
      ];
    } else if (l.contains('second')) {
      // Second degree — cool, blister warning, then cover
      return [
        _GuideStep(
          title: 'Cool the Burn (10–20 min)',
          body:
              'Gently cool under cool running water for 10–20 minutes. '
              'Do NOT use ice. Keep the rest of the body warm.',
          icon: Icons.water_drop,
          usesOverlay: true,
          mode: 'cool',
        ),
        _GuideStep(
          title: 'Protect Blisters',
          body: 'Do not burst blisters. If available, apply a sterile, non-stick dressing.',
          icon: Icons.do_not_disturb_on_total_silence,
          usesOverlay: true,
          mode: 'warn',
        ),
        _GuideStep(
          title: 'Apply Loose Cover',
          body:
              'Use a clean plastic film or non-stick dressing. Align and size the overlay to cover the burn loosely.',
          icon: Icons.crop_square,
          usesOverlay: true,
          mode: 'bandage',
        ),
        _GuideStep(
          title: 'Consider Medical Attention',
          body:
              'Seek care if the burn is large, very painful, on face/hands/genitals, or if you feel unwell.',
          icon: Icons.emergency_share,
        ),
      ];
    } else {
      // First degree — cool, then soothing/cover
      return [
        _GuideStep(
          title: 'Cool the Burn (10–20 min)',
          body: 'Cool under cool running water for 10–20 minutes. Avoid ice, butter, or oils.',
          icon: Icons.water_drop,
          usesOverlay: true,
          mode: 'cool',
        ),
        _GuideStep(
          title: 'Soothe & Protect',
          body:
              'After cooling, you may apply a soothing gel such as aloe vera. '
              'If needed, cover lightly with a clean, dry dressing.',
          icon: Icons.spa,
          usesOverlay: true,
          mode: 'bandage',
        ),
        _GuideStep(
          title: 'Monitor',
          body:
              'Watch for increasing pain, redness, or swelling. If symptoms worsen, seek medical advice.',
          icon: Icons.visibility,
        ),
      ];
    }
  }
}

/* ---------- UI widgets ---------- */

class _ImageWithOverlay extends StatefulWidget {
  final File imageFile;
  final Rect rectFrac; // x,y,w,h in [0..1] relative to displayed image
  final void Function(Rect) onRectFracChanged;
  final double handle;
  final String? animationMode; // 'cool' | 'bandage' | 'warn' | null

  const _ImageWithOverlay({
    required this.imageFile,
    required this.rectFrac,
    required this.onRectFracChanged,
    required this.handle,
    this.animationMode,
  });

  @override
  State<_ImageWithOverlay> createState() => _ImageWithOverlayState();
}

class _ImageWithOverlayState extends State<_ImageWithOverlay> {
  final GlobalKey _imageKey = GlobalKey();
  Offset? _dragStart;
  Rect? _startRect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        return InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Stack(
            children: [
              _MeasuredImage(
                key: _imageKey,
                file: widget.imageFile,
              ),
              Positioned.fill(
                child: Builder(
                  builder: (context) {
                    final box = _imageBox();
                    if (box == null) return const SizedBox.shrink();

                    final rectPx = _fracToPx(widget.rectFrac, box);
                    return Stack(
                      children: [
                        // Translucent selection rectangle (interactive area)
                        Positioned.fromRect(
                          rect: rectPx,
                          child: IgnorePointer(
                            ignoring: true,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.lightBlueAccent,
                                  width: 2,
                                ),
                                color: Colors.lightBlueAccent.withOpacity(0.15),
                              ),
                            ),
                          ),
                        ),

                        // AR-style cue anchored to the rectangle
                        if (widget.animationMode != null)
                          Positioned.fromRect(
                            rect: rectPx,
                            child: IgnorePointer(
                              ignoring: true,
                              child: _LottieGuidance(
                                mode: widget.animationMode!,
                              ),
                            ),
                          ),

                        // Drag to move entire rectangle
                        Positioned.fromRect(
                          rect: rectPx,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (d) {
                              _dragStart = d.localPosition;
                              _startRect = widget.rectFrac;
                            },
                            onPanUpdate: (d) {
                              if (_dragStart == null || _startRect == null) return;
                              final delta = (d.localPosition - _dragStart!);
                              final dx = delta.dx / box.size.width;
                              final dy = delta.dy / box.size.height;
                              var r = _startRect!.shift(Offset(dx, dy));
                              r = _clampRect(r);
                              widget.onRectFracChanged(r);
                            },
                            onPanEnd: (_) {
                              _dragStart = null;
                              _startRect = null;
                            },
                          ),
                        ),

                        // Resize handles
                        ..._cornerHandles(rectPx, box),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  RenderBox? _imageBox() {
    final ctx = _imageKey.currentContext;
    if (ctx == null) return null;
    return ctx.findRenderObject() as RenderBox?;
  }

  Rect _fracToPx(Rect r, RenderBox box) {
    final w = box.size.width;
    final h = box.size.height;
    return Rect.fromLTWH(r.left * w, r.top * h, r.width * w, r.height * h);
  }

  Rect _pxToFrac(Rect r, RenderBox box) {
    final w = box.size.width;
    final h = box.size.height;
    return Rect.fromLTWH(r.left / w, r.top / h, r.width / w, r.height / h);
  }

  Rect _clampRect(Rect r) {
    const minW = 0.08;
    const minH = 0.08;
    var x = r.left;
    var y = r.top;
    var w = math.max(minW, r.width);
    var h = math.max(minH, r.height);
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + w > 1) x = 1 - w;
    if (y + h > 1) y = 1 - h;
    return Rect.fromLTWH(x, y, w, h);
  }

  List<Widget> _cornerHandles(Rect rectPx, RenderBox box) {
    final handle = widget.handle;
    final corners = <Offset>[
      rectPx.topLeft,
      rectPx.topRight,
      rectPx.bottomLeft,
      rectPx.bottomRight,
    ];

    Rect rectFrac = widget.rectFrac;

    Widget buildHandle(int idx) {
      return Positioned(
        left: corners[idx].dx - handle / 2,
        top: corners[idx].dy - handle / 2,
        width: handle,
        height: handle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            _dragStart = d.localPosition;
            _startRect = rectFrac;
          },
          onPanUpdate: (d) {
            if (_dragStart == null || _startRect == null) return;
            final local = d.localPosition;
            final deltaPx = local - _dragStart!;
            Rect rPx = _fracToPx(_startRect!, box);
            switch (idx) {
              case 0:
                rPx = Rect.fromLTRB(
                    rPx.left + deltaPx.dx, rPx.top + deltaPx.dy, rPx.right, rPx.bottom);
                break;
              case 1:
                rPx = Rect.fromLTRB(
                    rPx.left, rPx.top + deltaPx.dy, rPx.right + deltaPx.dx, rPx.bottom);
                break;
              case 2:
                rPx = Rect.fromLTRB(
                    rPx.left + deltaPx.dx, rPx.top, rPx.right, rPx.bottom + deltaPx.dy);
                break;
              case 3:
                rPx = Rect.fromLTRB(
                    rPx.left, rPx.top, rPx.right + deltaPx.dx, rPx.bottom + deltaPx.dy);
                break;
            }
            var rFrac = _pxToFrac(rPx, box);
            rFrac = _clampRect(rFrac);
            widget.onRectFracChanged(rFrac);
            rectFrac = rFrac;
          },
          onPanEnd: (_) {
            _dragStart = null;
            _startRect = null;
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.lightBlueAccent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white, width: 1),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
            ),
          ),
        ),
      );
    }

    return [buildHandle(0), buildHandle(1), buildHandle(2), buildHandle(3)];
  }
}

class _MeasuredImage extends StatelessWidget {
  final File file;
  const _MeasuredImage({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return Image.file(
      file,
      key: key,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
    );
  }
}

class _GuideStep {
  final String title;
  final String body;
  final IconData icon;
  final bool usesOverlay;
  final String? mode; // 'cool' | 'bandage' | 'warn'

  const _GuideStep({
    required this.title,
    required this.body,
    required this.icon,
    this.usesOverlay = false,
    this.mode,
  });
}

class _StepCard extends StatelessWidget {
  final _GuideStep step;
  final int index;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _StepCard({
    required this.step,
    required this.index,
    required this.total,
    this.onPrev,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Row(
          children: [
            Icon(step.icon, size: 28, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(step.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(step.body, style: theme.textTheme.bodyMedium),
                  if (step.usesOverlay) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Tip: drag and resize the translucent rectangle to loosely cover the burn area.',
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.blueGrey),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              children: [
                IconButton(
                  onPressed: onPrev,
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous',
                ),
                Text('${index + 1}/$total', style: theme.textTheme.labelLarge),
                IconButton(
                  onPressed: onNext,
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next',
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}

class _DisclaimerBar extends StatelessWidget {
  const _DisclaimerBar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF6E5),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Text(
        'This app provides general guidance only and is not a medical diagnosis. '
        'Seek urgent care for: suspected third-degree burns, large/deep burns, face/hands/genitals, electrical/chemical burns, or if you feel unwell.',
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.brown[800]),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/* ---------- Lottie animation anchored to the selection rectangle ---------- */

class _LottieGuidance extends StatelessWidget {
  final String mode; // 'cool' | 'bandage' | 'warn'
  const _LottieGuidance({required this.mode});

  String get _asset {
    switch (mode) {
      case 'cool':
        return 'assets/lottie/water.json';
      case 'bandage':
        return 'assets/lottie/bandage.json';
      case 'warn':
        return 'assets/lottie/warn.json';
      default:
        return 'assets/lottie/warn.json';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (mode == 'warn') {
      // Always available fallback for warn cue
      return const _WarnPulse();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Lottie.asset(
        _asset,
        fit: BoxFit.cover,   // fills the selected rectangle
        repeat: true,
        animate: true,
        frameRate: FrameRate.max,
      ),
    );
  }
}

/* ---------- Simple pulsing warning cue (fallback for 'warn') ---------- */

class _WarnPulse extends StatefulWidget {
  const _WarnPulse({super.key});

  @override
  State<_WarnPulse> createState() => _WarnPulseState();
}

class _WarnPulseState extends State<_WarnPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        return CustomPaint(
          painter: _WarnPainter(progress: _ctl.value),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class _WarnPainter extends CustomPainter {
  final double progress; // 0..1
  _WarnPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = math.min(size.width, size.height) / 2;
    final bg = Paint()..color = const Color(0x22FF5252);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      bg,
    );

    // Two expanding rings
    for (int i = 0; i < 2; i++) {
      final p = (progress + i * 0.5) % 1.0;
      final r = 0.25 * maxR + p * 0.6 * maxR;
      final alpha = (255 * (1 - p)).clamp(30, 200).toInt();
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Color.fromARGB(alpha, 255, 82, 82);
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WarnPainter oldDelegate) => oldDelegate.progress != progress;
}

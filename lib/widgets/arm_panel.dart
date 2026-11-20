import '../app_language.dart';
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../arm.dart';

/// Joint jog panel: one slider per joint (thumb follows the real position, or the target while
/// dragging), fine-step buttons that repeat while held, Home, and gripper open/close.
class ArmPanel extends StatefulWidget {
  const ArmPanel({super.key, required this.joints, required this.positions, required this.limits,
    required this.onTarget, required this.onHome, this.onGripper, this.onSavePose, this.enabled = true});

  final List<String> joints;
  final Map<String, double> positions; // latest /joint_states
  final Map<String, JointLimit> limits;
  /// [live] is true while a slider is being dragged (callers may rate-limit those).
  final void Function(Map<String, double> targets, {required bool live}) onTarget;
  final VoidCallback onHome;
  final ValueChanged<bool>? onGripper; // true = open; null when there is no gripper
  /// Saves the current posture under a name (for the AI assistant and routines); null hides the button.
  final VoidCallback? onSavePose;
  final bool enabled;

  static const step = 0.0873; // 5 degrees

  @override
  State<ArmPanel> createState() => _ArmPanelState();
}

class _ArmPanelState extends State<ArmPanel> {
  Timer? _repeat;

  JointLimit _limit(String joint) => widget.limits[joint] ?? fallbackLimit;

  Map<String, double> _currentTargets() =>
      {for (final j in widget.joints) j: widget.positions[j] ?? 0.0};

  void _nudge(String joint, double delta) {
    final targets = _currentTargets();
    targets[joint] = _limit(joint).clamp((targets[joint] ?? 0) + delta);
    widget.onTarget(targets, live: false);
  }

  void _startRepeat(String joint, double delta) {
    _nudge(joint, delta);
    _repeat?.cancel();
    _repeat = Timer.periodic(const Duration(milliseconds: 180), (_) => _nudge(joint, delta));
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.joints.isNotEmpty && widget.joints.every(widget.positions.containsKey);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: const Color(0xF0101C26), borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x33FFFFFF))),
      child: !ready
          ? Padding(padding: const EdgeInsets.all(16), child: Text(context.strings.waitingJoints,
              style: TextStyle(color: Colors.white70)))
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final j in widget.joints) _jointRow(j),
              ])),
              const SizedBox(width: 12),
              SizedBox(width: 112, child: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (widget.onGripper != null) ...[
                  Text(context.strings.gripper, style: TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 1.2)),
                  const SizedBox(height: 4),
                  FilledButton.tonalIcon(key: const Key('gripper-open'),
                    onPressed: widget.enabled ? () => widget.onGripper!(true) : null,
                    icon: const Icon(Icons.open_in_full, size: 18), label: Text(context.strings.open)),
                  const SizedBox(height: 6),
                  FilledButton.tonalIcon(key: const Key('gripper-close'),
                    onPressed: widget.enabled ? () => widget.onGripper!(false) : null,
                    icon: const Icon(Icons.close_fullscreen, size: 18), label: Text(context.strings.close)),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(key: const Key('arm-home'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0x66FFFFFF))),
                  onPressed: widget.enabled ? widget.onHome : null,
                  icon: const Icon(Icons.home_outlined, size: 18), label: Text(context.strings.home)),
                if (widget.onSavePose != null) ...[
                  const SizedBox(height: 6),
                  OutlinedButton.icon(key: const Key('arm-save-pose'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0x66FFFFFF))),
                    onPressed: widget.enabled ? widget.onSavePose : null,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18), label: Text(context.strings.savePose)),
                ],
              ])),
            ]),
    );
  }

  Widget _jointRow(String joint) {
    final limit = _limit(joint);
    final actual = limit.clamp(widget.positions[joint] ?? 0);
    final rounded = (actual * 57.2958).round();
    final degrees = '${rounded == 0 ? 0 : rounded}'; // no "-0"
    Widget stepButton(IconData icon, double delta, String key) => GestureDetector(
      key: Key(key),
      onTapDown: widget.enabled ? (_) => _startRepeat(joint, delta) : null,
      onTapUp: (_) => _stopRepeat(),
      onTapCancel: _stopRepeat,
      child: Container(width: 36, height: 36, alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0x22FFFFFF), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: Colors.white, size: 20)),
    );
    return SizedBox(height: 44, child: Row(children: [
      SizedBox(width: 60, child: Text(joint, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
      stepButton(Icons.remove, -ArmPanel.step, 'jog-$joint-minus'),
      Expanded(child: _JogTrack(
        key: Key('joint-$joint'), limit: limit, actual: actual, enabled: widget.enabled,
        onTarget: (v, live) => widget.onTarget({..._currentTargets(), joint: v}, live: live),
      )),
      stepButton(Icons.add, ArmPanel.step, 'jog-$joint-plus'),
      SizedBox(width: 44, child: Text('$degrees°', textAlign: TextAlign.right,
        style: const TextStyle(color: Color(0xFF78E0CE), fontSize: 12))),
    ]));
  }
}

/// Relative jog track: dragging moves the target by the distance dragged at a fixed sensitivity
/// ([radPerPixel], independent of how narrow the track is on a phone); a tap does nothing, so
/// touching the track never makes the arm jump to that point.
class _JogTrack extends StatefulWidget {
  const _JogTrack({super.key, required this.limit, required this.actual, required this.onTarget, this.enabled = true});
  final JointLimit limit;
  final double actual;
  final void Function(double target, bool live) onTarget;
  final bool enabled;

  @override
  State<_JogTrack> createState() => _JogTrackState();
}

class _JogTrackState extends State<_JogTrack> {
  static const radPerPixel = 0.005; // ~0.3 degrees per logical pixel
  double? _target; // non-null while dragging
  double _start = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final range = widget.limit.upper - widget.limit.lower;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.enabled ? (_) => setState(() => _target = _start = widget.actual) : null,
        onHorizontalDragUpdate: widget.enabled ? (d) {
          final next = widget.limit.clamp((_target ?? widget.actual) + d.delta.dx * radPerPixel);
          setState(() => _target = next);
          widget.onTarget(next, true);
        } : null,
        onHorizontalDragEnd: widget.enabled ? (_) {
          final target = _target;
          setState(() => _target = null);
          // A lone drag recognizer also "wins" a plain tap (zero movement): send nothing then.
          if (target != null && (target - _start).abs() > 1e-4) widget.onTarget(target, false);
        } : null,
        child: CustomPaint(size: Size(box.maxWidth, 36), painter: _JogTrackPainter(
          fraction: (widget.actual - widget.limit.lower) / range,
          target: _target == null ? null : (_target! - widget.limit.lower) / range,
          zero: (0 - widget.limit.lower) / range,
          enabled: widget.enabled)),
      );
    });
  }
}

class _JogTrackPainter extends CustomPainter {
  _JogTrackPainter({required this.fraction, required this.target, required this.zero, required this.enabled});
  final double fraction;
  final double zero; // where 0 rad sits on the track (outside [0, 1] = not drawn)
  final double? target;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 12.0;
    final y = size.height / 2;
    final width = size.width - inset * 2;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(inset, y - 3, width, 6), const Radius.circular(3)),
        Paint()..color = const Color(0x44FFFFFF));
    if (zero >= 0 && zero <= 1) { // tick at 0 rad (the home pose) for orientation
      final tick = Offset(inset + width * zero, y);
      canvas.drawLine(tick.translate(0, -7), tick.translate(0, 7), Paint()..color = const Color(0x77FFFFFF)..strokeWidth = 1.5);
    }
    final actual = Offset(inset + width * fraction.clamp(0.0, 1.0), y);
    canvas.drawCircle(actual, 9, Paint()..color = enabled ? const Color(0xFF78E0CE) : const Color(0x6678E0CE));
    final t = target;
    if (t != null) {
      canvas.drawCircle(Offset(inset + width * t.clamp(0.0, 1.0), y), 11, Paint()
        ..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.5);
    }
  }

  @override
  bool shouldRepaint(covariant _JogTrackPainter old) =>
      old.fraction != fraction || old.target != target || old.zero != zero || old.enabled != enabled;
}

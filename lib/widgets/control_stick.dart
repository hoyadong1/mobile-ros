import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_joystick/flutter_joystick.dart';

/// A thumb stick that owns its touches (no enclosing scroll or gesture can steal a drag) and
/// reports deflection in [-1, 1] while held, and zero on release.
class ControlStick extends StatefulWidget {
  const ControlStick({super.key, required this.onChanged, this.mode = JoystickMode.all,
    this.size = 168, this.enabled = true, this.label});

  final ValueChanged<Offset> onChanged;
  final JoystickMode mode;
  final double size;
  final bool enabled;
  final String? label;

  @override
  State<ControlStick> createState() => _ControlStickState();
}

class _ControlStickState extends State<ControlStick> {
  final _controller = JoystickController();
  bool _held = false;

  void _release() {
    if (!_held) return;
    _held = false;
    widget.onChanged(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    final stick = Joystick(
      controller: _controller,
      mode: widget.mode,
      includeInitialAnimation: false,
      base: JoystickBase(size: widget.size, mode: widget.mode),
      stick: JoystickStick(size: widget.size * 0.36),
      listener: (details) {
        if (_held) widget.onChanged(Offset(details.x, details.y));
      },
    );
    return Semantics(
      label: widget.label, enabled: widget.enabled,
      child: Opacity(opacity: widget.enabled ? 1 : 0.4, child: AbsorbPointer(absorbing: !widget.enabled,
        child: Listener(
          onPointerDown: (_) => _held = true,
          onPointerUp: (_) => _release(),
          onPointerCancel: (_) => _release(),
          child: RawGestureDetector(
            gestures: {
              _EagerPanGestureRecognizer: GestureRecognizerFactoryWithHandlers<_EagerPanGestureRecognizer>(
                _EagerPanGestureRecognizer.new,
                (r) => r
                  ..onStart = ((d) => _controller.start(d.globalPosition))
                  ..onUpdate = ((d) => _controller.update(d.globalPosition))
                  ..onEnd = ((_) => _controller.end())
                  ..onCancel = _controller.end,
              ),
            },
            child: stick,
          ),
        ),
      )),
    );
  }
}

/// Wins the gesture arena on touch-down so the stick never loses a drag to a scroll view.
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  _EagerPanGestureRecognizer() {
    dragStartBehavior = DragStartBehavior.down;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

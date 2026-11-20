import '../app_language.dart';
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../robot_requests.dart';

/// Shows the robot's questions one at a time, on top of whatever screen is open, and its notices as
/// snack bars. Put it around the workspace; it starts [requests] listening.
class RobotRequestsHost extends StatefulWidget {
  const RobotRequestsHost({super.key, required this.requests, required this.robotName, required this.child});

  final RobotRequests requests;
  /// Shown with each question, so the person knows which robot (and connection) is asking.
  final String robotName;
  final Widget child;

  @override
  State<RobotRequestsHost> createState() => _RobotRequestsHostState();
}

class _RobotRequestsHostState extends State<RobotRequestsHost> {
  StreamSubscription<HelpRequest>? _requests;
  StreamSubscription<RobotNotice>? _notices;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    try {
      widget.requests.start();
    } catch (_) {
      return; // a connection that cannot subscribe: no robot questions
    }
    _requests = widget.requests.requests.listen((_) => _showNext());
    _notices = widget.requests.noticeStream.listen(_showNotice);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showNext());
  }

  @override
  void dispose() {
    _requests?.cancel();
    _notices?.cancel();
    super.dispose();
  }

  Future<void> _showNext() async {
    if (_showing || !mounted) return;
    final next = widget.requests.pending.firstOrNull;
    if (next == null) return;
    _showing = true;
    await showDialog<void>(context: context, barrierDismissible: false,
        builder: (_) => HelpRequestDialog(request: next, requests: widget.requests, robotName: widget.robotName));
    _showing = false;
    if (mounted) unawaited(_showNext());
  }

  void _showNotice(RobotNotice notice) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final color = switch (notice.level) {
      NoticeLevel.error => const Color(0xFFB3261E),
      NoticeLevel.warning => const Color(0xFF8A5A00),
      NoticeLevel.info => const Color(0xFF182D42),
    };
    messenger?.showSnackBar(SnackBar(backgroundColor: color, duration: const Duration(seconds: 6),
        content: Text(notice.message.isEmpty ? notice.title : '${notice.title}: ${notice.message}')));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One question from the robot, with its answers as buttons. Closes itself if the robot withdraws the
/// question or it times out.
class HelpRequestDialog extends StatefulWidget {
  const HelpRequestDialog({super.key, required this.request, required this.requests, required this.robotName});

  final HelpRequest request;
  final RobotRequests requests;
  final String robotName;

  @override
  State<HelpRequestDialog> createState() => _HelpRequestDialogState();
}

class _HelpRequestDialogState extends State<HelpRequestDialog> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.requests.addListener(_onChange);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.requests.removeListener(_onChange);
    _tick?.cancel();
    super.dispose();
  }

  void _onChange() {
    if (mounted && !widget.requests.pending.any((r) => r.id == widget.request.id)) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final left = r.deadline.difference(DateTime.now()).inSeconds.clamp(0, 1 << 30);
    return AlertDialog(
      key: const Key('robot-request'),
      icon: Icon(r.urgent ? Icons.warning_amber_rounded : Icons.smart_toy_outlined,
          color: r.urgent ? const Color(0xFFB3261E) : const Color(0xFF5365C6)),
      title: Text(r.title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (r.message.isNotEmpty) Text(r.message, style: const TextStyle(fontSize: 16, height: 1.4)),
        const SizedBox(height: 12),
        Text('${widget.robotName} · ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')} left',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        TextButton(key: const Key('robot-request-dismiss'),
            onPressed: () => widget.requests.dismiss(r.id), child: Text(context.strings.ignore)),
        for (final (i, option) in r.options.indexed)
          FilledButton(key: Key('robot-request-option-$i'),
              onPressed: () => widget.requests.answer(r.id, i), child: Text(option)),
      ],
    );
  }
}

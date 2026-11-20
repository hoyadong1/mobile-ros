import 'app_language.dart';
import 'app_theme.dart';
import 'cloud_robots_page.dart';
import 'cloud_session.dart';
import 'package:material_ui/material_ui.dart';

/// Short registration codes as shown on the robot computer: XXXX-XXXX (no 0/O, 1/I/L or U).
final robotCodePattern = RegExp(r'^[A-HJKMNP-TV-Z2-9]{4}-?[A-HJKMNP-TV-Z2-9]{4}$');

/// "XXXX-XXXX" from what was typed or scanned ("abcd efgh"), or null when it cannot be a code.
String? normalizeRobotCode(String text) {
  final plain = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (!robotCodePattern.hasMatch(plain)) return null;
  return '${plain.substring(0, 4)}-${plain.substring(4)}';
}

/// The page the robot's QR code opens (`/app/#/link?code=XXXX-XXXX`): after signing in, it shows which
/// robot is waiting and adds it to the account only when the person approves.
class LinkRobotPage extends StatefulWidget {
  const LinkRobotPage({super.key, required this.code, this.session});
  final String code;
  final CloudSession? session;
  @override
  State<LinkRobotPage> createState() => _LinkRobotPageState();
}

class _LinkRobotPageState extends State<LinkRobotPage> {
  late final CloudSession session = widget.session ?? CloudSession.shared;
  late final String? code = normalizeRobotCode(widget.code);
  bool _loading = true, _busy = false, _added = false;
  ({String name, bool online})? _robot;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final strings = appStrings; // runs from initState
    try {
      if (!session.signedIn) await session.restore();
    } catch (_) { /* shown as signed out */ }
    if (code == null) {
      _error = strings.linkInvalid;
    } else if (session.signedIn) {
      try {
        _robot = await session.previewClaim(code!);
      } on CloudFailure catch (error) {
        _error = error.message;
      } catch (_) {
        _error = strings.mrosUnreachable;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _signIn() async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CloudRobotsPage(session: session, signInOnly: true)));
    if (mounted) await _load();
  }

  Future<void> _add() async {
    setState(() { _busy = true; _error = null; });
    try {
      await session.claim(code!);
      if (mounted) setState(() => _added = true);
    } on CloudFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = context.strings.mrosUnreachable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openMyRobots() => Navigator.pushReplacement(context,
      MaterialPageRoute<void>(builder: (_) => CloudRobotsPage(session: session)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final robot = _robot;
    return Scaffold(
      appBar: AppBar(title: Text(context.strings.addARobot)),
      body: SafeArea(child: Align(alignment: Alignment.topCenter, child: SingleChildScrollView(
        padding: const EdgeInsets.all(20), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_loading) const LinearProgressIndicator()
          else if (_added) ...[
            Icon(Icons.check_circle_outline, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(context.strings.robotInMyRobots(robot?.name ?? context.strings.theRobot), key: const Key('link-done'), style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(context.strings.connectAnywhereDone),
            const SizedBox(height: 20),
            FilledButton(key: const Key('link-my-robots'), onPressed: _openMyRobots, child: Text(context.strings.openMyRobots)),
          ] else if (code != null && !session.signedIn) ...[
            Text(context.strings.addRobotToAccount, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(context.strings.signInToApprove(code!), style: TextStyle(color: context.muted)),
            const SizedBox(height: 20),
            FilledButton(key: const Key('link-signin'), onPressed: _signIn, child: Text(context.strings.signIn)),
          ] else if (robot != null) ...[
            Text(context.strings.addThisRobotQ, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Card(margin: EdgeInsets.zero, child: ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(robot.name, key: const Key('link-robot-name')),
              subtitle: Text(context.strings.statusCode(robot.online ? context.strings.online : context.strings.offline, code!)))),
            const SizedBox(height: 12),
            Text(context.strings.approveOwnOnly,
              style: TextStyle(color: context.muted)),
            const SizedBox(height: 20),
            FilledButton(key: const Key('link-add'), onPressed: _busy ? null : _add,
              child: Text(_busy ? context.strings.adding : context.strings.addToMyAccount)),
            TextButton(onPressed: _busy ? null : _openMyRobots, child: Text(context.strings.cancel)),
          ] else
            TextButton(onPressed: _openMyRobots, child: Text(context.strings.openMyRobots)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!,
            key: const Key('link-error'), style: TextStyle(color: theme.colorScheme.error))),
        ])),
      ))),
    );
  }
}

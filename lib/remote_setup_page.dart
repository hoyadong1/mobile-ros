import 'app_language.dart';
import 'app_theme.dart';
import 'cloud_robots_page.dart';
import 'cloud_session.dart';
import 'package:material_ui/material_ui.dart';
import 'remote_setup.dart';

/// context.strings.remoteAccessTitle for a robot reached nearby: the app signs in to the robot computer once over SSH,
/// installs Mobile ROS there and adds the robot to the account. Nothing is typed on the robot.
class RemoteSetupPage extends StatefulWidget {
  const RemoteSetupPage({super.key, required this.host, required this.name, this.session, this.connect});
  final String host, name;
  final CloudSession? session;
  /// SSH to the robot computer (tests pass a fake).
  final Future<RobotShell> Function({required String host, required int port, required String user,
      String password, String? privateKey, String? passphrase,
      required Future<bool> Function(String fingerprint) verifyHostKey})? connect;
  @override
  State<RemoteSetupPage> createState() => _RemoteSetupPageState();
}

class _RemoteSetupPageState extends State<RemoteSetupPage> {
  late final CloudSession session = widget.session ?? CloudSession.shared;
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name);
  late final _host = TextEditingController(text: widget.host);
  final _user = TextEditingController(), _password = TextEditingController(), _key = TextEditingController(),
      _passphrase = TextEditingController(), _sudo = TextEditingController();
  /// Sign in with a private key instead of a password (computers that allow only keys).
  bool _useKey = false;
  bool _rosbridge = true, _busy = false, _checking = true, _done = false, _already = false, _reregister = false;
  final _steps = <String>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkSignIn();
  }

  Future<void> _checkSignIn() async {
    try { if (!session.signedIn) await session.restore(); } catch (_) { /* shown as signed out */ }
    if (mounted) setState(() => _checking = false);
  }

  @override
  void dispose() {
    _name.dispose(); _host.dispose(); _user.dispose(); _password.dispose();
    _key.dispose(); _passphrase.dispose(); _sudo.dispose();
    super.dispose();
  }

  Future<bool> _confirmHost(String host, String fingerprint) async {
    final known = await KnownRobotHosts.fingerprintFor(host);
    if (known != null) return known == fingerprint; // a different key: refused (see the error text)
    if (!mounted) return false;
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.isThisComputer),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.strings.firstConnectionTo(host)),
          const SizedBox(height: 8),
          SelectableText(fingerprint, key: const Key('remote-fingerprint'), style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 12),
          Text(context.strings.hostKeyHelp,
            style: TextStyle(color: context.muted)),
        ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.strings.cancel)),
        FilledButton(key: const Key('remote-trust'), onPressed: () => Navigator.pop(context, true), child: Text(context.strings.continueLabel)),
      ]));
    if (ok == true) await KnownRobotHosts.remember(host, fingerprint);
    return ok == true;
  }

  Future<void> _setUp() async {
    if (_form.currentState?.validate() != true) return;
    FocusScope.of(context).unfocus();
    setState(() { _busy = true; _error = null; _steps.clear(); _done = false; _already = false; });
    final host = _host.text.trim();
    RobotShell? shell;
    var mismatch = false;
    try {
      setState(() => _steps.add(context.strings.signingInComputer));
      final connect = widget.connect ?? SshRobotShell.connect;
      shell = await connect(host: host, port: 22, user: _user.text.trim(),
        password: _useKey ? '' : _password.text,
        privateKey: _useKey ? _key.text : null, passphrase: _useKey ? _passphrase.text : null,
        verifyHostKey: (fingerprint) async {
          final known = await KnownRobotHosts.fingerprintFor(host);
          mismatch = known != null && known != fingerprint;
          return _confirmHost(host, fingerprint);
        });
      final result = await RemoteSetup.install(shell, relay: relayBase(session), name: _name.text.trim(),
        user: _user.text.trim(), sudoPassword: _useKey ? _sudo.text : _password.text,
        rosbridgeService: _rosbridge, reregister: _reregister,
        claim: session.claim, onStep: (step) { if (mounted) setState(() => _steps.add(step)); });
      if (mounted) setState(() { _done = !result.alreadySetUp; _already = result.alreadySetUp; _reregister = false; });
    } on RemoteSetupFailure catch (error) {
      if (mounted) {
        setState(() => _error = mismatch
            ? context.strings.hostChanged(host)
            : error.message);
      }
    } on CloudFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = context.strings.setupNotFinished);
    } finally {
      await shell?.close();
      // Nothing secret stays in the form.
      if (mounted) setState(() { _busy = false; _password.clear(); _key.clear(); _passphrase.clear(); _sudo.clear(); });
    }
  }

  Future<void> _signIn() async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CloudRobotsPage(session: session, fromLocal: true)));
    if (mounted) setState(() {});
  }

  void _openMyRobots() => Navigator.pushReplacement(context,
      MaterialPageRoute<void>(builder: (_) => CloudRobotsPage(session: session, fromLocal: true)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.strings.remoteAccessTitle)),
      body: SafeArea(child: Align(alignment: Alignment.topCenter, child: SingleChildScrollView(
        padding: const EdgeInsets.all(20), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_checking) const LinearProgressIndicator()
          else if (!session.signedIn) ...[
            Text(context.strings.reachAnywhere, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(context.strings.signInFirst, style: TextStyle(color: context.muted)),
            const SizedBox(height: 20),
            FilledButton(key: const Key('remote-signin'), onPressed: _signIn, child: Text(context.strings.signIn)),
          ] else if (_done) ...[
            Icon(Icons.cloud_done_outlined, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(context.strings.remoteIsOn, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(context.strings.inMyRobotsStarts(_name.text.trim())),
            const SizedBox(height: 20),
            FilledButton(key: const Key('remote-my-robots'), onPressed: _openMyRobots, child: Text(context.strings.openMyRobots)),
          ] else if (_already) ...[
            Text(context.strings.alreadySetUp, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(context.strings.alreadySetUpBody),
            const SizedBox(height: 20),
            FilledButton(onPressed: _openMyRobots, child: Text(context.strings.openMyRobots)),
            TextButton(key: const Key('remote-again'), onPressed: () => setState(() { _already = false; _reregister = true; _steps.clear(); }),
              child: Text(context.strings.setUpAgain)),
          ] else ...[
            Text(context.strings.reachAnywhere, style: theme.textTheme.headlineSmall),
            if (_reregister) Padding(padding: const EdgeInsets.only(top: 8), child: Text(
              context.strings.replacesEarlier, style: TextStyle(color: theme.colorScheme.error))),
            const SizedBox(height: 8),
            Text(context.strings.setupExplain, style: TextStyle(color: context.muted)),
            const SizedBox(height: 20),
            Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextFormField(key: const Key('remote-name'), controller: _name, enabled: !_busy, maxLength: 60,
                decoration: InputDecoration(labelText: context.strings.robotName),
                validator: (v) => (v ?? '').trim().isEmpty ? context.strings.enterRobotName : null),
              TextFormField(key: const Key('remote-host'), controller: _host, enabled: !_busy, autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(labelText: context.strings.computerAddress, hintText: '192.168.1.20'),
                validator: (v) => RegExp(r'^[A-Za-z0-9.:-]+$').hasMatch((v ?? '').trim()) ? null : context.strings.enterComputerAddress),
              const SizedBox(height: 12),
              TextFormField(key: const Key('remote-user'), controller: _user, enabled: !_busy, autocorrect: false,
                enableSuggestions: false, decoration: InputDecoration(labelText: context.strings.computerUser,
                  helperText: context.strings.sudoAccount),
                validator: (v) => RegExp(r'^[a-z_][a-z0-9_-]*$').hasMatch((v ?? '').trim()) ? null : context.strings.enterUserName),
              const SizedBox(height: 12),
              SegmentedButton<bool>(key: const Key('remote-auth'),
                segments: [
                  ButtonSegment(value: false, icon: Icon(Icons.password), label: Text(context.strings.password)),
                  ButtonSegment(value: true, icon: Icon(Icons.key), label: Text(context.strings.privateKey)),
                ],
                selected: {_useKey}, onSelectionChanged: _busy ? null : (v) => setState(() => _useKey = v.first)),
              const SizedBox(height: 12),
              if (!_useKey)
                TextFormField(key: const Key('remote-password'), controller: _password, enabled: !_busy, obscureText: true,
                  autocorrect: false, enableSuggestions: false, decoration: InputDecoration(labelText: context.strings.password),
                  validator: (v) => (v ?? '').isEmpty ? context.strings.enterThePassword : null,
                  onFieldSubmitted: (_) => _busy ? null : _setUp())
              else ...[
                TextFormField(key: const Key('remote-key'), controller: _key, enabled: !_busy, minLines: 3, maxLines: 6,
                  autocorrect: false, enableSuggestions: false, keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(labelText: context.strings.privateKey,
                    hintText: '-----BEGIN OPENSSH PRIVATE KEY----- …', helperText: context.strings.pasteWholeKey),
                  validator: (v) => (v ?? '').contains('PRIVATE KEY') ? null : context.strings.pastePrivateKey),
                const SizedBox(height: 12),
                TextFormField(key: const Key('remote-passphrase'), controller: _passphrase, enabled: !_busy, obscureText: true,
                  autocorrect: false, enableSuggestions: false,
                  decoration: InputDecoration(labelText: context.strings.keyPassphrase)),
                const SizedBox(height: 12),
                TextFormField(key: const Key('remote-sudo'), controller: _sudo, enabled: !_busy, obscureText: true,
                  autocorrect: false, enableSuggestions: false, decoration: InputDecoration(
                    labelText: context.strings.sudoPassword, helperText: context.strings.sudoNoPassword)),
              ],
              CheckboxListTile(key: const Key('remote-rosbridge'), value: _rosbridge, contentPadding: EdgeInsets.zero,
                onChanged: _busy ? null : (v) => setState(() => _rosbridge = v ?? true),
                title: Text(context.strings.alsoRosbridge)),
              const SizedBox(height: 8),
              FilledButton(key: const Key('remote-setup'), onPressed: _busy ? null : _setUp,
                child: Text(_busy ? context.strings.settingUp : context.strings.setUpRemote)),
            ])),
          ],
          if (_steps.isNotEmpty && !_done) ...[
            const SizedBox(height: 20),
            for (final (i, step) in _steps.indexed) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
              if (_busy && i == _steps.length - 1)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else Icon(_error != null && i == _steps.length - 1 ? Icons.error_outline : Icons.check, size: 18,
                color: _error != null && i == _steps.length - 1 ? theme.colorScheme.error : theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(step)),
            ])),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!,
            key: const Key('remote-error'), style: TextStyle(color: theme.colorScheme.error))),
        ])),
      ))),
    );
  }
}

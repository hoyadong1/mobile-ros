import 'app_language.dart';
import 'dart:async';
import 'app_theme.dart';
import 'cloud_session.dart';
import 'link_robot_page.dart';
import 'scan_robot_code_page.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'main_page.dart';
import 'connect_page.dart' show ConnectPage;
import 'recovery_link.dart';
import 'remote_support.dart';
import 'support.dart';
import 'package:material_ui/material_ui.dart';

class CloudRobotsPage extends StatefulWidget {
  const CloudRobotsPage({super.key, this.session, this.fromLocal = false, this.resetToken, this.signInOnly = false,
    this.restoreBenefits});
  final CloudSession? session;
  final bool fromLocal;
  /// Opened only to sign in (e.g. from a robot's approval link): goes back there once signed in.
  final bool signInOnly;
  final Future<int> Function()? restoreBenefits;
  /// A password reset link's token (tests); the web page otherwise hands it over itself.
  final String? resetToken;
  @override
  State<CloudRobotsPage> createState() => _CloudRobotsPageState();
}

class _CloudRobotsPageState extends State<CloudRobotsPage> {
  late final CloudSession session = widget.session ?? CloudSession.shared;
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final _email = TextEditingController(), _password = TextEditingController(),
      _confirmPassword = TextEditingController(), _code = TextEditingController();
  List<CloudRobot> _robots = [];
  CloudUsage? _usage;
  bool _busy = true, _signup = false, _awaitingEmail = false, _adding = false;
  String? _error, _notice;
  Timer? _poll;
  int _version = 0;
  /// Opened from a password reset email (web): the new-password form uses this token.
  String? _resetToken;
  @override
  void initState() {
    super.initState();
    _resetToken = widget.resetToken ?? takeRecoveryToken();
    if (_resetToken == null && Uri.base.queryParameters['password_reset'] == 'ready') {
      _error = context.strings.resetLinkUsed;
    }
    final confirmation = Uri.base.queryParameters['email_confirmation'];
    if (confirmation == 'complete') _notice = context.strings.emailConfirmed;
    if (confirmation == 'failed') _error = context.strings.confirmLinkFailed;
    _load();
  }
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    final version = ++_version;
    setState(() { _busy = true; _error = null; _notice = null; });
    try { await action(); }
    catch (error) {
      if (mounted && version == _version) setState(() => _error = error is CloudFailure ? error.message : context.strings.requestFailed);
    } finally {
      if (mounted && version == _version) setState(() => _busy = false);
    }
  }
  Future<void> _load() async {
    try {
      if (!session.signedIn) await session.restore();
      if (session.signedIn) {
        _robots = await session.robots();
        await _loadUsage();
      }
    } catch (error) {
      if (mounted) _error = error is CloudFailure ? error.message : context.strings.remoteUnreachable;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }
  Future<void> _loadUsage() async {
    try { final usage = await session.usage(); if (mounted) setState(() => _usage = usage); }
    catch (_) { /* Robot access remains enforced by the server if usage is unavailable. */ }
  }
  Future<void> _restoreRemoteBenefits() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.restoreBenefitsQ),
      content: Text(context.strings.linkPurchasesTo(session.email ?? context.strings.thisAccount)),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.strings.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.strings.restore))],
    ));
    if (confirmed != true || !mounted || !session.signedIn) return;
    await _run(() async {
      final restore = widget.restoreBenefits ?? PlaySupportStore.shared?.restoreRemote;
      if (restore == null) throw CloudFailure(context.strings.openFromPlay);
      final count = await restore();
      await _loadUsage();
      if (mounted) {
        setState(() => _notice = count == 0
          ? context.strings.noPurchasesFound
          : context.strings.benefitsRestored);
      }
    });
  }
  Future<void> _refresh() async {
    if (_busy || !session.signedIn || ModalRoute.of(context)?.isCurrent != true) return;
    final version = _version;
    try {
      final robots = await session.robots();
      await _loadUsage();
      if (mounted && version == _version) setState(() { _robots = robots; _error = null; });
    } catch (_) { /* Explicit refresh/connect reports failures; polling does not cover the screen. */ }
  }
  Future<void> _authenticate() async {
    if (_form.currentState?.validate() != true) return;
    FocusScope.of(context).unfocus();
    await _run(() async {
      if (_signup) {
        await session.signUp(_email.text, _password.text);
        if (mounted) {
          setState(() {
            _signup = false; _awaitingEmail = true; _password.clear(); _confirmPassword.clear();
            if (_scroll.hasClients) _scroll.jumpTo(0);
          });
        }
      } else {
        await session.signIn(_email.text, _password.text);
        _password.clear();
        if (widget.signInOnly) {
          if (mounted) Navigator.pop(context, true);
          return;
        }
        final robots = await session.robots();
        await _loadUsage();
        if (mounted) setState(() => _robots = robots);
      }
    });
  }
  /// Scan the robot's QR code, then approve it on the same page a link opens.
  Future<void> _scan() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanRobotCodePage()));
    if (code == null || !mounted) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LinkRobotPage(code: code, session: session)));
    if (!mounted) return;
    await _run(() async {
      final robots = await session.robots();
      if (mounted) setState(() { _robots = robots; _adding = false; });
    });
  }
  Future<void> _claim() async {
    final code = normalizeRobotCode(_code.text);
    if (code == null) {
      setState(() => _error = context.strings.enterRegCode);
      return;
    }
    FocusScope.of(context).unfocus();
    await _run(() async {
      await session.claim(code);
      final robots = await session.robots();
      if (mounted) setState(() { _robots = robots; _adding = false; _code.clear(); });
    });
  }
  String _roleName(String role) => role == 'viewer' ? context.strings.roleViewer : context.strings.roleOperator;

  /// Shares [robot]: pick what the other person may do, then hand them a one-time code.
  Future<void> _share(CloudRobot robot) async {
    final role = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
      title: Text(context.strings.shareRobot),
      children: [
        for (final r in const ['viewer', 'operator']) SimpleDialogOption(key: Key('share-$r'),
          onPressed: () => Navigator.pop(context, r),
          child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(r == 'viewer' ? Icons.visibility_outlined : Icons.gamepad_outlined),
            title: Text(_roleName(r)),
            subtitle: Text(r == 'viewer' ? context.strings.roleViewerHelp : context.strings.roleOperatorHelp))),
      ]));
    if (role == null || !mounted) return;
    ({String code, DateTime expires})? created;
    await _run(() async { created = await session.invite(robot, role); });
    final invite = created;
    if (invite == null || !mounted) return;
    {
      final when = invite.expires.toLocal();
      await showDialog<void>(context: context, builder: (context) => AlertDialog(
        title: Text('${robot.name} · ${_roleName(role)}'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.strings.shareIntro),
          const SizedBox(height: 16),
          SelectableText(invite.code, key: const Key('share-code'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 2)),
          Text(context.strings.codeExpires('${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}'),
            style: TextStyle(color: context.muted)),
        ])),
        actions: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: invite.code)), child: Text(context.strings.copy)),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.ok)),
        ]));
    }
  }

  /// Who the robot is shared with; the owner can take access away.
  Future<void> _members(CloudRobot robot) async {
    ({List<CloudMember> members, int openInvites})? loaded;
    await _run(() async { loaded = await session.members(robot); });
    if (loaded == null || !mounted) return;
    {
      var list = loaded!;
      await showDialog<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, setDialog) => AlertDialog(
        title: Text(context.strings.peopleWithAccess),
        content: SizedBox(width: 360, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (list.members.isEmpty) Text(context.strings.noMembers),
          for (final (i, m) in list.members.indexed) ListTile(key: Key('member-${m.user}'), contentPadding: EdgeInsets.zero,
            leading: Icon(m.role == 'viewer' ? Icons.visibility_outlined : Icons.gamepad_outlined),
            title: Text(context.strings.memberLabel(i + 1)), subtitle: Text(_roleName(m.role)),
            trailing: IconButton(tooltip: context.strings.remove, icon: const Icon(Icons.person_remove_outlined), onPressed: () async {
              await session.removeMember(robot, m.user);
              final next = await session.members(robot);
              setDialog(() => list = next);
            })),
          if (list.openInvites > 0) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(context.strings.openInvites(list.openInvites), style: TextStyle(color: context.muted))),
        ]))),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.ok))],
      )));
    }
  }

  Future<void> _leave(CloudRobot robot) => _run(() async {
    await session.removeMember(robot);
    final robots = await session.robots(); // not _refresh: it waits while this runs
    if (mounted) setState(() => _robots = robots);
  });

  /// The invitation code being typed (kept: the dialog still shows it while it closes).
  final _joinCode = TextEditingController();

  Future<void> _join() async {
    final code = _joinCode..clear();
    final entered = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.joinShared),
      content: TextField(key: const Key('join-code'), controller: code, autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(labelText: context.strings.invitationCode, hintText: 'XXXX-XXXX')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(key: const Key('join-submit'), onPressed: () => Navigator.pop(context, code.text), child: Text(context.strings.join)),
      ]));
    if (entered == null || entered.trim().isEmpty || !mounted) return;
    await _run(() async {
      final robot = await session.join(entered);
      final robots = await session.robots();
      if (mounted) setState(() { _robots = robots; _notice = context.strings.joinedRobot(robot.name, _roleName(robot.role)); });
    });
  }

  Future<void> _connect(CloudRobot robot) async {
    await _run(() async {
      var reconnect = true;
      while (reconnect && mounted) {
        final connection = await session.connect(robot);
        if (!mounted) { connection.close(); return; }
        try {
          reconnect = await Navigator.push<bool>(context, MaterialPageRoute<bool>(builder: (_) => MainPage(
            ip: '${session.base.toString().replaceFirst('https:', 'wss:').replaceFirst(RegExp(r'/$'), '')}/robots/${robot.id}',
            port: '443', connection: connection, address: 'Remote · ${robot.name}${robot.viewOnly ? ' · ${context.strings.roleViewer}' : ''}',
            connectionFactory: (_, _) => session.additionalConnection(robot)))) == true;
        } finally { connection.close(); }
      }
    });
    if (mounted) await _refresh();
  }
  Future<void> _remove(CloudRobot robot) async {
    final remove = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.removeRobotQ),
      content: SingleChildScrollView(child: Text(context.strings.removeRobotBody(robot.name))),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.strings.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.strings.remove))]));
    if (remove != true || !mounted) return;
    await _run(() async {
      await session.remove(robot);
      final robots = await session.robots();
      if (mounted) setState(() => _robots = robots);
    });
  }
  Future<void> _forgotPassword() async {
    final email = await showDialog<String>(context: context,
        builder: (_) => _ResetRequestDialog(initial: _email.text.trim()));
    if (email == null || !mounted) return;
    await _run(() async {
      await session.requestPasswordReset(email);
      if (mounted) setState(() => _notice = context.strings.resetLinkSent(email));
    });
  }
  Future<void> _setNewPassword() async {
    if (_form.currentState?.validate() != true) return;
    FocusScope.of(context).unfocus();
    final token = _resetToken!;
    final unconfirmed = context.strings.pwChangeUnconfirmed;
    await _run(() async {
        try { await session.setNewPassword(token, _password.text); }
        catch (_) {
          if (mounted) _showSignIn();
          throw CloudFailure(unconfirmed);
        }
      if (mounted) {
        setState(() {
          _resetToken = null; _password.clear(); _confirmPassword.clear();
          _notice = context.strings.pwChanged;
        });
      }
    });
  }
  Future<void> _deleteAccount() async {
    final password = await showDialog<String>(context: context, builder: (_) => const _DeleteAccountDialog());
    if (password == null || !mounted) return;
    await _run(() async {
      final gone = await session.deleteAccount(password);
      if (mounted) {
        setState(() {
          _robots = []; _usage = null; _adding = false;
          _notice = gone ? context.strings.accountDeleted
              : context.strings.accountClosed;
        });
      }
    });
  }
  /// The same for everyone and every robot: the account is chosen later, by approving on a signed-in phone.
  String get installCommand => 'curl -fsSL ${session.base.origin}/i | sudo bash';
  void _setupHelp() {
    showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.otherSetupWays),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.strings.setupNearby),
          const SizedBox(height: 12),
          Text(context.strings.setupName),
          const SizedBox(height: 8),
          SelectableText('python3 robot_side/register_robot.py --relay ${session.base.origin} --name "My robot"'),
          const SizedBox(height: 12),
          Text(context.strings.noCredentialNeeded),
        ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.gotIt))],
    ));
  }
  void _showSignIn() => setState(() {
      _signup = false; _awaitingEmail = false; _resetToken = null; _error = null; _notice = null;
    _password.clear(); _confirmPassword.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });
  void _createAccount() => setState(() {
    _signup = true; _awaitingEmail = false; _error = null; _notice = null;
    _password.clear(); _confirmPassword.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });
  void _goLocal() {
    if (widget.fromLocal && Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ConnectPage()));
    }
  }
  @override
  void dispose() {
    _joinCode.dispose();
    ++_version; _poll?.cancel();
    _email.dispose(); _password.dispose(); _confirmPassword.dispose(); _code.dispose(); _scroll.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(session.signedIn ? context.strings.myRobots : 'Mobile ROS'),
      leading: _signup || _awaitingEmail || _resetToken != null ? IconButton(tooltip: context.strings.backToSignIn, onPressed: _busy ? null : _showSignIn,
        icon: const Icon(Icons.arrow_back)) : null, actions: [
      if (session.signedIn) IconButton(tooltip: context.strings.signOut, onPressed: _busy ? null : () => _run(() async {
        await session.signOut(); if (mounted) setState(() { _robots = []; _usage = null; _adding = false; });
      }), icon: const Icon(Icons.logout)),
    ]),
    body: SafeArea(child: Align(alignment: Alignment.topCenter, child: SingleChildScrollView(controller: _scroll,
      padding: const EdgeInsets.all(20), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_busy) const LinearProgressIndicator(key: Key('cloud-progress')),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_error!,
          key: const Key('cloud-error'), style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_notice != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_notice!, key: const Key('cloud-notice'))),
        if (!session.signedIn && _resetToken != null) ...[
          const SizedBox(height: 16),
          Text(context.strings.setNewPassword, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(context.strings.everyDeviceSignsIn, style: TextStyle(color: context.muted)),
          const SizedBox(height: 24),
          Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextFormField(key: const Key('cloud-new-password'), controller: _password, enabled: !_busy,
              obscureText: true, autocorrect: false, enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(labelText: context.strings.newPassword, helperText: context.strings.min12, errorMaxLines: 3),
              validator: (value) => (value ?? '').length < 12 ? context.strings.min12 : null),
            const SizedBox(height: 16),
            TextFormField(key: const Key('cloud-confirm-password'), controller: _confirmPassword, enabled: !_busy,
              obscureText: true, autocorrect: false, enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(labelText: context.strings.confirmPassword, errorMaxLines: 3),
              validator: (value) => value == _password.text && (value ?? '').isNotEmpty ? null : context.strings.pwMismatch,
              onFieldSubmitted: (_) => _busy ? null : _setNewPassword()),
            const SizedBox(height: 24),
            FilledButton(key: const Key('cloud-save-password'), onPressed: _busy ? null : _setNewPassword,
              child: Text(context.strings.saveNewPassword)),
          ])),
        ] else if (!session.signedIn && _awaitingEmail) ...[
          const SizedBox(height: 24),
          Text(context.strings.step2Verify, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 20),
          Align(alignment: Alignment.centerLeft, child: CircleAvatar(radius: 30,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Icon(Icons.mark_email_unread_outlined, size: 30, color: Theme.of(context).colorScheme.onPrimaryContainer))),
          const SizedBox(height: 20),
          Text(context.strings.checkEmail, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text(context.strings.openConfirmLink),
          const SizedBox(height: 8),
          Text(_email.text.trim(), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          Text(context.strings.afterConfirm, style: TextStyle(color: context.muted)),
          const SizedBox(height: 28),
          FilledButton(key: const Key('cloud-email-confirmed'), onPressed: () {
            _showSignIn();
            setState(() => _notice = context.strings.signInToFinish);
          }, child: Text(context.strings.iConfirmed)),
          TextButton(onPressed: _createAccount, child: Text(context.strings.differentEmail)),
        ] else if (!session.signedIn) ...[
          const SizedBox(height: 16),
          if (_signup) ...[
            Text(context.strings.step1Account, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 12),
          ],
          Text(_signup ? context.strings.createAnAccount : context.strings.signIn, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(_signup ? context.strings.createThenVerify : context.strings.accessRegistered, style: TextStyle(color: context.muted)),
          const SizedBox(height: 24),
          Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextFormField(key: const Key('cloud-email'), controller: _email, enabled: !_busy,
              keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next,
              autocorrect: false, autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(labelText: context.strings.email, errorMaxLines: 3),
              validator: (value) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '') ? null : context.strings.enterEmail),
            const SizedBox(height: 16),
            TextFormField(key: const Key('cloud-password'), controller: _password, enabled: !_busy,
              obscureText: true, autocorrect: false, enableSuggestions: false,
              textInputAction: _signup ? TextInputAction.next : TextInputAction.done,
              autofillHints: [_signup ? AutofillHints.newPassword : AutofillHints.password],
              decoration: InputDecoration(labelText: _signup ? context.strings.newPassword : context.strings.password,
                helperText: _signup ? context.strings.min12 : null, helperMaxLines: 3, errorMaxLines: 3),
              validator: (value) => (value ?? '').isEmpty ? context.strings.enterPassword
                : _signup && value!.length < 12 ? context.strings.min12 : null,
              onFieldSubmitted: (_) {
                if (!_busy && !_signup) _authenticate();
              }),
            if (_signup) ...[
              const SizedBox(height: 16),
              TextFormField(key: const Key('cloud-confirm-password'), controller: _confirmPassword, enabled: !_busy,
                obscureText: true, autocorrect: false, enableSuggestions: false,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(labelText: context.strings.confirmPassword, errorMaxLines: 3),
                validator: (value) => value == _password.text && (value ?? '').isNotEmpty ? null : context.strings.pwMismatch,
                onFieldSubmitted: (_) => _busy ? null : _authenticate()),
            ],
            const SizedBox(height: 24),
            FilledButton(key: const Key('cloud-signin'), onPressed: _busy ? null : _authenticate,
              child: Text(_signup ? context.strings.createAccount : context.strings.signIn)),
            TextButton(key: const Key('cloud-switch-mode'), onPressed: _busy ? null : _signup ? _showSignIn : _createAccount,
              child: Text(_signup ? context.strings.haveAccount : context.strings.newHere)),
            if (!_signup) TextButton(key: const Key('cloud-forgot'), onPressed: _busy ? null : _forgotPassword,
              child: Text(context.strings.forgotPassword)),
          ])),
          const SizedBox(height: 16),
          if (!_signup) TextButton(onPressed: _goLocal,
            child: Text(context.strings.connectNearbyInstead)),
        ] else ...[
          const SizedBox(height: 16),
          Text(session.email ?? context.strings.signedIn, style: TextStyle(color: context.muted)),
          if (_robots.isEmpty && !_busy) Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text(context.strings.noRobotsYet)),
          for (final robot in _robots) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [Icon(robot.online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
                const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(robot.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(robot.online ? context.strings.online : context.strings.offline, style: TextStyle(color: context.muted)),
                  if (robot.shared) Text(context.strings.sharedByOwner(_roleName(robot.role)),
                    key: Key('cloud-role-${robot.id}'), style: TextStyle(color: context.muted)),
                ])), PopupMenuButton<String>(key: Key('cloud-menu-${robot.id}'), enabled: !_busy,
                  onSelected: (v) => switch (v) {
                    'share' => _share(robot),
                    'members' => _members(robot),
                    'leave' => _leave(robot),
                    _ => _remove(robot),
                  },
                  itemBuilder: (_) => [
                    if (!robot.shared) ...[
                      PopupMenuItem(value: 'share', child: Text(context.strings.shareRobot)),
                      PopupMenuItem(value: 'members', child: Text(context.strings.peopleWithAccess)),
                      PopupMenuItem(value: 'remove', child: Text(context.strings.removeRobot)),
                    ] else PopupMenuItem(value: 'leave', child: Text(context.strings.leaveRobot)),
                  ])]),
              const SizedBox(height: 12),
              FilledButton(onPressed: !_busy && robot.online && _usage?.exhausted != true ? () => _connect(robot) : null, child: Text(context.strings.connect)),
          ]))),
          const SizedBox(height: 16),
          if (_adding) ...[
            Text(context.strings.registerRobot, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(context.strings.step1Terminal),
            const SizedBox(height: 8),
            Container(padding: const EdgeInsets.fromLTRB(12, 4, 4, 4), decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Expanded(child: SelectableText(installCommand, key: const Key('cloud-install-command'),
                  style: const TextStyle(fontFamily: 'monospace'))),
                IconButton(key: const Key('cloud-copy-command'), tooltip: context.strings.copy, icon: const Icon(Icons.copy),
                  onPressed: () {
                    final messenger = ScaffoldMessenger.of(context);
                    final copied = context.strings.commandCopied;
                    Clipboard.setData(ClipboardData(text: installCommand))
                        .then((_) => messenger.showSnackBar(SnackBar(content: Text(copied))));
                  }),
              ])),
            const SizedBox(height: 12),
            Text(context.strings.step2Qr),
            if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS))
              OutlinedButton.icon(key: const Key('cloud-scan'), onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner), label: Text(context.strings.scanQr)),
            TextButton(onPressed: _setupHelp, child: Text(context.strings.otherSetupWays)),
            const SizedBox(height: 8),
            TextField(key: const Key('cloud-claim-code'), controller: _code, enabled: !_busy,
              autocorrect: false, enableSuggestions: false, textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: context.strings.registrationCode, hintText: 'XXXX-XXXX')),
            const SizedBox(height: 16),
            FilledButton(key: const Key('cloud-register'), onPressed: _busy ? null : _claim, child: Text(context.strings.registerRobotShort)),
            TextButton(onPressed: _busy ? null : () => setState(() { _adding = false; _code.clear(); }), child: Text(context.strings.cancel)),
          ] else OutlinedButton.icon(key: const Key('cloud-add'), onPressed: _busy ? null : () => setState(() => _adding = true),
            icon: const Icon(Icons.add), label: Text(context.strings.registerRobot)),
          TextButton(onPressed: _busy ? null : () => _run(() async {
            final robots = await session.robots(); await _loadUsage(); if (mounted) setState(() => _robots = robots);
          }), child: Text(context.strings.refresh)),
          TextButton(key: const Key('cloud-join'), onPressed: _busy ? null : _join, child: Text(context.strings.joinShared)),
          TextButton(onPressed: _busy ? null : _goLocal, child: Text(context.strings.connectNearby)),
          const SizedBox(height: 12),
          if (_usage != null) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.strings.remoteUsage, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_usage!.plan == 'free') Text(context.strings.freeAllowance),
              if (_usage!.plan == 'subscriber') Text(context.strings.subscriberAllowance),
              Text(_usage!.summaryIn(context.strings)),
              if (_usage!.maxActiveRobots != null) Text(context.strings.remoteRobotsAtATime(_usage!.maxActiveRobots!)),
              const SizedBox(height: 8),
              Text(_usage!.exhausted ? context.strings.remotePaused
                : _usage!.usedBytes >= _usage!.limitBytes * 0.8 ? context.strings.remote80
                : context.strings.noOverage),
              if (widget.restoreBenefits != null || (remoteBenefitsEnabled && PlaySupportStore.supported))
                TextButton(key: const Key('cloud-restore-benefits'), onPressed: _busy ? null : _restoreRemoteBenefits,
                  child: Text(context.strings.restoreBenefits)),
            ]))),
          Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text(context.strings.remotePreviewNote)),
          const SizedBox(height: 24),
          TextButton(key: const Key('cloud-delete-account'), onPressed: _busy ? null : _deleteAccount,
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: Text(context.strings.deleteAccount)),
        ],
      ])),
    ))),
  );
}

/// Asks for the email to send a reset link to; owns its field (it lives through the closing animation).
class _ResetRequestDialog extends StatefulWidget {
  const _ResetRequestDialog({required this.initial});
  final String initial;
  @override
  State<_ResetRequestDialog> createState() => _ResetRequestDialogState();
}

class _ResetRequestDialogState extends State<_ResetRequestDialog> {
  late final _email = TextEditingController(text: widget.initial);
  @override
  void dispose() { _email.dispose(); super.dispose(); }
  void _send() {
    final email = _email.text.trim();
    if (RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) Navigator.pop(context, email);
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.resetPassword),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(context.strings.weEmailLink),
      const SizedBox(height: 16),
      TextField(key: const Key('cloud-reset-email'), controller: _email, autofocus: true,
        keyboardType: TextInputType.emailAddress, autocorrect: false,
        decoration: InputDecoration(labelText: context.strings.email), onSubmitted: (_) => _send()),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(key: const Key('cloud-reset-send'), onPressed: _send, child: Text(context.strings.sendLink)),
    ]);
}

/// Confirms deleting the account with the password; says what goes.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();
  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  @override
  void dispose() { _password.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.deleteAccountQ),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.strings.deleteAccountBody),
        const SizedBox(height: 8),
        Text(context.strings.nearbyWithoutAccount),
        if (remoteBenefitsEnabled) Padding(padding: EdgeInsets.only(top: 8), child: Text(context.strings.deleteNoCancelSub)),
        const SizedBox(height: 16),
        TextField(key: const Key('cloud-delete-password'), controller: _password, obscureText: true, autofocus: true,
          autocorrect: false, enableSuggestions: false,
          decoration: InputDecoration(labelText: context.strings.password), onChanged: (_) => setState(() {})),
      ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(key: const Key('cloud-delete-confirm'),
        style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError),
        onPressed: _password.text.isEmpty ? null : () => Navigator.pop(context, _password.text),
        child: Text(context.strings.deleteAccount)),
    ]);
}

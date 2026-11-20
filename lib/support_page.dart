import 'app_language.dart';
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'support.dart';
import 'cloud_session.dart' show CloudFailure;

/// "Support Mobile ROS": tip once or support monthly, through Google Play. Nothing is locked behind it.
class SupportPage extends StatefulWidget {
  const SupportPage({super.key, this.store});
  final SupportStore? store;

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  late final SupportStore store = widget.store ?? (PlaySupportStore.supported
      ? PlaySupportStore.shared ?? (PlaySupportStore.shared = PlaySupportStore())
      : UnavailableSupportStore());
  List<SupportOffer>? offers;
  String? problem;
  String? busy; // product being bought
  StreamSubscription? _events;

  static const _blurbs = {
    SupportProducts.coffee: ('Coffee', Icons.coffee_outlined),
    SupportProducts.lunch: ('Lunch', Icons.lunch_dining_outlined),
    SupportProducts.monthly: ('Monthly', Icons.favorite_outline),
    SupportProducts.remoteMonthly: ('Remote Plus', Icons.public),
    SupportProducts.dataPack: ('Extra data', Icons.add_circle_outline),
  };

  @override
  void initState() {
    super.initState();
    _events = store.events.listen(_onEvent);
    _load();
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { offers = null; problem = null; });
    try {
      if (!await store.available()) {
        if (!mounted) return;
        setState(() { offers = const []; problem = context.strings.playOnly; });
        return;
      }
      final list = await store.offers();
      if (!mounted) return;
      setState(() {
        offers = list;
        if (list.isEmpty) problem = context.strings.playLoadError;
      });
    } catch (e) {
      if (mounted) setState(() { offers = const []; problem = e is CloudFailure ? e.message : context.strings.playReachError; });
    }
  }

  void _onEvent((String, SupportEvent, String?) e) {
    if (!mounted) return;
    final (product, event, error) = e;
    // Only a purchase started here gets the dialog; others (restored, finished elsewhere) are just remembered.
    final mine = busy != null && (product.isEmpty || product == busy);
    if (event != SupportEvent.pending && mine) setState(() => busy = null);
    switch (event) {
      case SupportEvent.thanked:
        SupporterBadge.instance.thank();
        if (!mine) return;
        showDialog<void>(context: context, builder: (c) => AlertDialog(
          key: const Key('support-thanks'),
          icon: const Icon(Icons.favorite, color: Color(0xFFD81B60), size: 40),
          title: Text(context.strings.thankYou),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ));
      case SupportEvent.pending:
        if (mine) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(context.strings.paymentPending)));
        }
      case SupportEvent.failed:
        if (mine) {
          setState(() => problem = context.strings.paymentFailed(error == null ? '.' : '\n$error'));
        }
      case SupportEvent.needsRestore:
        if (mine) setState(() => problem = error ?? context.strings.restoreToFinish);
      case SupportEvent.canceled:
        break;
    }
  }

  Future<void> _buy(SupportOffer o) async {
    if (busy != null) return;
    setState(() { busy = o.id; problem = null; });
    try {
      await store.buy(o);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = null;
          problem ??= context.strings.paymentStartFailed('${e is StateError ? e.message : e}');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = offers;
    return Scaffold(
      appBar: AppBar(title: Text(store is PlaySupportStore && (store as PlaySupportStore).delivery != null ? context.strings.remoteAccessTitle : context.strings.supportTitle)),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
        const Icon(Icons.favorite, color: Color(0xFFD81B60), size: 44),
        const SizedBox(height: 12),
        Text(store is PlaySupportStore && (store as PlaySupportStore).delivery != null
          ? context.strings.supportIntroRemote : context.strings.supportIntro, textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, height: 1.4, color: context.ink, fontWeight: FontWeight.w600)),
        ListenableBuilder(listenable: SupporterBadge.instance, builder: (context, _) =>
          SupporterBadge.instance.supporter ? Padding(padding: const EdgeInsets.only(top: 8), child: Text(
            context.strings.thanksSupport, key: const Key('support-badge'), textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFD81B60), fontWeight: FontWeight.w700))) : const SizedBox.shrink()),
        const SizedBox(height: 28),
        if (list == null)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else ...[
          for (final o in list) ...[
            if (o.id == SupportProducts.coffee && list.any((item) => item.remote))
              Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(context.strings.supportDev, style: Theme.of(context).textTheme.titleMedium)),
            _offer(o, cs),
          ],
          if (list.any((o) => o.remoteBytes != null)) Text(
            context.strings.dataMeasured,
            style: TextStyle(fontSize: 12, color: context.muted)),
          if (problem != null) Column(children: [
            SelectableText(problem!, key: const Key('support-problem'), textAlign: TextAlign.center,
              style: TextStyle(color: context.muted)),
            TextButton(onPressed: _load, child: Text(context.strings.tryAgain)),
          ]),
          if (list.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(
            context.strings.throughPlay, textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.muted))),
        ],
      ]),
    );
  }

  Widget _offer(SupportOffer o, ColorScheme cs) {
    final (title, icon) = _blurbs[o.id] ?? (o.title, Icons.favorite_outline);
    final loading = busy == o.id;
    final details = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: context.ink)),
      if (o.remoteBenefitLabel != null) Text(o.remoteBenefitLabel!, style: TextStyle(fontSize: 12, color: context.muted)),
      if (o.remoteRobots != null) Text('${o.remoteRobots} remote robot${o.remoteRobots == 1 ? '' : 's'} at a time', style: TextStyle(fontSize: 12, color: context.muted)),
    ]);
    final button = FilledButton(onPressed: busy != null ? null : () => _buy(o),
      child: loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Text(o.subscription ? '${o.price}/month' : o.price));
    final heading = Row(children: [Icon(icon, color: const Color(0xFFD81B60)), const SizedBox(width: 14), Expanded(child: details)]);
    return Card(key: Key('support-${o.id}'), elevation: 0, color: context.card,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: context.border)),
      child: Padding(padding: const EdgeInsets.all(14), child: LayoutBuilder(builder: (context, constraints) =>
        constraints.maxWidth < 360 ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          heading, const SizedBox(height: 12), Align(alignment: Alignment.centerRight, child: button),
        ]) : Row(children: [Expanded(child: heading), const SizedBox(width: 8), button]))));
  }
}

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supporting the app's development through Google Play: one-off tips and a monthly support
/// subscription. Nothing is unlocked by it; the app stays complete without paying.
///
/// The products are created in the Play Console with exactly these IDs (prices are set there and shown
/// as Play reports them, in the person's currency).
class SupportProducts {
  static const coffee = 'support_coffee'; // one-off (consumable): "a coffee"
  static const lunch = 'support_lunch'; // one-off (consumable): "a lunch"
  static const monthly = 'support_monthly'; // subscription, monthly
  static const remoteMonthly = 'remote_monthly';
  static const dataPack = 'remote_data_pack';
  static const all = {coffee, lunch, monthly};
  static const remote = {remoteMonthly, dataPack};
  static bool isSubscription(String id) => id == monthly || id == remoteMonthly;
}

/// A product as shown on the support screen.
class SupportOffer {
  const SupportOffer({required this.id, required this.title, required this.price, this.raw, this.remoteBytes, this.remoteRobots});
  final String id;
  final String title;
  /// Formatted by the store ("₩1,500", "$0.99").
  final String price;
  final Object? raw;
  final int? remoteBytes;
  final int? remoteRobots;
  bool get remote => SupportProducts.remote.contains(id);
  bool get subscription => SupportProducts.isSubscription(id);
  String? get remoteBenefitLabel {
    final bytes = remoteBytes;
    if (bytes == null) return null;
    final (unit, divisor) = bytes >= 1000000000 ? ('GB', 1000000000)
      : bytes >= 1000000 ? ('MB', 1000000) : bytes >= 1000 ? ('KB', 1000) : ('bytes', 1);
    final value = (bytes / divisor).toStringAsFixed(bytes % divisor == 0 ? 0 : 2);
    return '$value $unit remote ${subscription ? 'data/month' : 'bonus data'}';
  }
}

enum SupportEvent { pending, thanked, canceled, failed, needsRestore }

enum SupportDelivery { legacy, completed, deferred, ineligible }

class SupportBenefits {
  const SupportBenefits(this.bytes, {this.robots = const {}});
  final Map<String, int> bytes, robots;
}

/// Optional remote-beta integration. The backend owns receipt verification and delivery.
abstract interface class SupportPurchaseDelivery {
  Future<SupportBenefits> allowances();
  Future<String> restoreAccount();
  Future<String?> checkoutAccount(String product, {int? expectedBytes});
  Future<SupportDelivery> deliver(PurchaseDetails purchase, {String? restoringAccount});
}

/// The store behind the support screen (Google Play through in_app_purchase; tests use a fake).
abstract class SupportStore {
  Future<bool> available();
  Future<List<SupportOffer>> offers();
  Future<void> buy(SupportOffer offer);
  /// Purchases finishing (also ones started earlier and finished while the app was closed).
  Stream<(String productId, SupportEvent event, String? error)> get events;
  Future<void> restore();
}

class PlaySupportStore implements SupportStore {
  static bool get supported => !kIsWeb && Platform.isAndroid;
  /// One for the app, started at launch: a purchase finished while the app was closed is delivered
  /// on the next start and must be acknowledged (Google refunds it otherwise).
  static PlaySupportStore? shared;
  static void start({SupportPurchaseDelivery? delivery}) {
    if (!supported) return;
    shared ??= PlaySupportStore(delivery: delivery);
    shared!.events.listen((e) {
      if (e.$2 == SupportEvent.thanked) SupporterBadge.instance.thank();
    });
  }

  PlaySupportStore({InAppPurchase? billing, this.delivery}) : _billing = billing ?? InAppPurchase.instance {
    _sub = _billing.purchaseStream.listen((list) {
      final restore = _remoteRestore;
      final remoteBatch = restore != null && _restoringAccount != null && list.every((p) => p.status == PurchaseStatus.restored);
      final account = remoteBatch ? _restoringAccount : null;
      _work = _work.then((_) async {
        try {
          final count = await _onPurchases(list, restoringAccount: account);
          if (remoteBatch && !restore.isCompleted) restore.complete(count);
        } catch (_) {
          if (remoteBatch && !restore.isCompleted) restore.completeError(StateError('Could not restore remote benefits. Please try again.'));
        }
      });
    }, onError: (Object e) {
      _events.add(('', SupportEvent.failed, 'Could not read Google Play purchases.'));
      final restore = _remoteRestore;
      if (restore != null && !restore.isCompleted) restore.completeError(StateError('Could not read Google Play purchases.'));
    });
  }

  final InAppPurchase _billing;
  final SupportPurchaseDelivery? delivery;
  Future<void> _work = Future.value();
  Completer<int>? _remoteRestore;
  String? _restoringAccount;
  final _events = StreamController<(String, SupportEvent, String?)>.broadcast();
  late final StreamSubscription<List<PurchaseDetails>> _sub;

  @override
  Stream<(String, SupportEvent, String?)> get events => _events.stream;

  @override
  Future<bool> available() async {
    try {
      return await _billing.isAvailable();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<SupportOffer>> offers() async {
    final allowances = await delivery?.allowances() ?? const SupportBenefits({});
    final identifiers = {...SupportProducts.all, ...SupportProducts.remote.where(allowances.bytes.containsKey)};
    final r = await _billing.queryProductDetails(identifiers);
    if (r.error != null && r.productDetails.isEmpty) {
      throw StateError(r.error!.message);
    }
    final order = [...SupportProducts.remote, ...SupportProducts.all];
    final list = [
      for (final p in r.productDetails)
        SupportOffer(id: p.id, title: p.title, price: p.price, raw: p, remoteBytes: allowances.bytes[p.id], remoteRobots: allowances.robots[p.id]),
    ]..sort((a, b) => order.indexOf(a.id).compareTo(order.indexOf(b.id)));
    // Play can list a subscription once per base plan/offer: keep one line per product.
    final seen = <String>{};
    return [for (final o in list) if (seen.add(o.id)) o];
  }

  @override
  Future<void> buy(SupportOffer offer) async {
    if (_remoteRestore != null) throw StateError('Wait for purchase restoration to finish.');
    final account = await delivery?.checkoutAccount(offer.id, expectedBytes: offer.remoteBytes);
    if (_remoteRestore != null) throw StateError('Wait for purchase restoration to finish.');
    final param = PurchaseParam(productDetails: offer.raw! as ProductDetails, applicationUserName: account);
    final bool started;
    if (offer.subscription) {
      started = await _billing.buyNonConsumable(purchaseParam: param);
    } else {
      // A tip can be given again: consumed right after it is delivered.
      started = await _billing.buyConsumable(purchaseParam: param, autoConsume: account == null);
    }
    if (!started) throw StateError('Google Play could not open checkout. Reload the prices and try again.');
  }

  @override
  Future<void> restore() => _billing.restorePurchases();

  /// The person explicitly confirms linking existing account-less subscriptions first.
  Future<int> restoreRemote() async {
    if (delivery == null) throw StateError('Remote purchase benefits are being prepared.');
    if (_remoteRestore != null) throw StateError('Purchase restoration is already running.');
    final result = Completer<int>();
    // Attach the timeout listener before the store may synchronously report an error.
    final waiting = result.future.timeout(const Duration(seconds: 45));
    unawaited(waiting.then<void>((_) {}, onError: (Object _, StackTrace stack) {}));
    _remoteRestore = result;
    try {
      _restoringAccount = await delivery!.restoreAccount();
      await _billing.restorePurchases();
      return await waiting;
    } catch (_) {
      if (!result.isCompleted) result.complete(0);
      throw StateError('Could not restore remote benefits. Check your sign-in and try again.');
    } finally {
      _remoteRestore = null; _restoringAccount = null;
    }
  }

  Future<int> _onPurchases(List<PurchaseDetails> list, {String? restoringAccount}) async {
    var restored = 0;
    var failed = false;
    for (final p in list) {
      final purchased = p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored;
      if (purchased && delivery != null) {
        try {
          final result = await delivery!.deliver(p, restoringAccount: restoringAccount);
          if (result == SupportDelivery.completed) {
            restored++;
            _events.add((p.productID, SupportEvent.thanked, null));
            continue; // the server already consumed/acknowledged it
          }
          if (result == SupportDelivery.ineligible) {
            _events.add((p.productID, SupportEvent.canceled, null));
            continue;
          }
          if (result == SupportDelivery.deferred) {
            failed = true;
            _events.add((p.productID, SupportEvent.needsRestore, 'Your purchase is saved. Restore remote benefits to finish delivery.'));
            continue; // never consume or acknowledge before verified durable delivery
          }
        } catch (_) {
          failed = true;
          _events.add((p.productID, SupportEvent.needsRestore, 'Could not verify your purchase. Restore remote benefits to retry.'));
          continue;
        }
      }
      switch (p.status) {
        case PurchaseStatus.pending:
          _events.add((p.productID, SupportEvent.pending, null));
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _events.add((p.productID, SupportEvent.thanked, null));
        case PurchaseStatus.canceled:
          _events.add((p.productID, SupportEvent.canceled, null));
        case PurchaseStatus.error:
          final error = p.error;
          // Android puts BillingResult.debugMessage in details and only the response-code name in
          // message. Preserve that explanation without serialising receipts or purchase objects.
          final details = error?.details;
          final message = [if (error?.message.isNotEmpty == true) error!.message,
            if (details is String && details.isNotEmpty) details].join('\n');
          _events.add((p.productID, SupportEvent.failed, message.isEmpty ? null : message));
      }
      // Google refunds purchases that are not acknowledged within three days.
      if (purchased && p.pendingCompletePurchase) {
        try {
          await _billing.completePurchase(p);
        } catch (_) {}
      }
    }
    if (restoringAccount != null && failed) throw StateError('Some purchases could not be verified. Restore again to retry.');
    return restored;
  }

  void dispose() {
    _sub.cancel();
    _events.close();
  }
}

/// Keeps the support screen usable on platforms without Google Play Billing.
class UnavailableSupportStore implements SupportStore {
  @override
  Future<bool> available() async => false;
  @override
  Future<List<SupportOffer>> offers() async => const [];
  @override
  Future<void> buy(SupportOffer offer) async => throw StateError('Google Play is not available on this platform.');
  @override
  Stream<(String, SupportEvent, String?)> get events => const Stream.empty();
  @override
  Future<void> restore() async {}
}

/// Remembers that the person supported the app (to thank them, never to unlock anything).
class SupporterBadge extends ChangeNotifier {
  SupporterBadge._();
  static final instance = SupporterBadge._();
  static const _key = 'supporter_since';

  DateTime? since;
  bool get supporter => since != null;

  Future<void> load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getString(_key);
      since = v == null ? null : DateTime.tryParse(v);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> thank() async {
    since ??= DateTime.now();
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, since!.toIso8601String());
    } catch (_) {}
  }
}

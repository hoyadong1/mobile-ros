import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/cloud_session.dart';
import 'package:ros_tester/cloud_robots_page.dart';
import 'package:ros_tester/remote_support.dart';
import 'package:ros_tester/support.dart';
import 'package:ros_tester/support_page.dart';
import 'support/fake_cloud_session.dart';

PurchaseDetails purchase({String product = SupportProducts.monthly, PurchaseStatus status = PurchaseStatus.purchased}) =>
  PurchaseDetails(productID: product, status: status, transactionDate: null,
    verificationData: PurchaseVerificationData(localVerificationData: '', serverVerificationData: 'synthetic-purchase-token', source: 'google_play'))
    ..pendingCompletePurchase = true;

class BenefitBilling implements InAppPurchase {
  final updates = StreamController<List<PurchaseDetails>>.broadcast();
  List<PurchaseDetails> restored = [];
  int acknowledgements = 0;
  bool? autoConsume;
  PurchaseParam? checkout;
  bool remoteProducts = false;
  int subscriptionCheckouts = 0;
  Set<String> queried = {};
  @override
  Stream<List<PurchaseDetails>> get purchaseStream => updates.stream;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> buyConsumable({required PurchaseParam purchaseParam, bool autoConsume = true}) async {
    checkout = purchaseParam; this.autoConsume = autoConsume; return true;
  }
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    checkout = purchaseParam; subscriptionCheckouts++; return true;
  }
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async { acknowledgements++; }
  @override
  Future<void> restorePurchases({String? applicationUserName}) async { updates.add(restored); }
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async {
    queried = identifiers;
    return ProductDetailsResponse(productDetails: [
      ProductDetails(id: SupportProducts.coffee, title: 'Coffee', description: 'Support', price: '1.00', rawPrice: 1, currencyCode: 'USD'),
      if (remoteProducts) ...[
        ProductDetails(id: SupportProducts.remoteMonthly, title: 'Remote Plus', description: 'Remote', price: '9.90', rawPrice: 9.90, currencyCode: 'USD'),
        ProductDetails(id: SupportProducts.dataPack, title: 'Extra data', description: 'Data', price: '1.90', rawPrice: 1.90, currencyCode: 'USD'),
      ],
    ].where((p) => identifiers.contains(p.id)).toList(), notFoundIDs: []);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDelivery implements SupportPurchaseDelivery {
  SupportDelivery result = SupportDelivery.completed;
  bool fail = false;
  Completer<String>? accountReady;
  bool remoteOffers = false;
  final restoredAccounts = <String?>[];
  @override
  Future<SupportBenefits> allowances() async => SupportBenefits({SupportProducts.coffee: 200, SupportProducts.monthly: 1000,
    if (remoteOffers) ...{SupportProducts.remoteMonthly: 10000000000, SupportProducts.dataPack: 1000000000}},
    robots: const {SupportProducts.remoteMonthly: 2});
  @override
  Future<String> restoreAccount() async => accountReady == null ? 'a' * 64 : await accountReady!.future;
  @override
  Future<String?> checkoutAccount(String product, {int? expectedBytes}) async => 'a' * 64;
  @override
  Future<SupportDelivery> deliver(PurchaseDetails purchase, {String? restoringAccount}) async {
    restoredAccounts.add(restoringAccount);
    if (fail) throw StateError('synthetic provider outage');
    return result;
  }
}

class BenefitSession extends FakeCloudSession {
  BenefitSession() : super(signedIn: true);
  bool enabled = true;
  String account = 'a' * 64;
  final submissions = <(String, String, bool)>[];
  @override
  Future<CloudBillingConfig> billingConfig() async => CloudBillingConfig(enabled: enabled, version: 7,
    accountId: account, products: {SupportProducts.monthly: 1000, SupportProducts.coffee: 200}, legacySubscriptions: true);
  @override
  Future<Map<String, dynamic>> verifyPlayPurchase(String product, String purchaseToken,
      {required int version, bool claimLegacy = false, bool refresh = false}) async {
    submissions.add((product, purchaseToken, claimLegacy));
    return {'status': 'verified', 'granted': true, 'completed': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('remote checkout binds an obfuscated account and prevents automatic consumption', () async {
    final billing = BenefitBilling(), delivery = FakeDelivery();
    final store = PlaySupportStore(billing: billing, delivery: delivery);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    final offer = (await store.offers()).single;
    expect(offer.remoteBenefitLabel, '200 bytes remote bonus data');
    await store.buy(offer);
    expect(billing.checkout!.applicationUserName, 'a' * 64);
    expect(billing.autoConsume, false);
    final event = store.events.first;
    billing.updates.add([purchase(product: SupportProducts.coffee)]);
    expect((await event).$2, SupportEvent.thanked);
    expect(billing.acknowledgements, 0, reason: 'server already consumed the durably delivered purchase');
  });
  test('failed or unfinished verification never acknowledges a paid purchase', () async {
    final billing = BenefitBilling(), delivery = FakeDelivery()..fail = true;
    final store = PlaySupportStore(billing: billing, delivery: delivery);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    var event = store.events.first;
    billing.updates.add([purchase()]);
    expect((await event).$2, SupportEvent.needsRestore);
    delivery.fail = false; delivery.result = SupportDelivery.deferred;
    event = store.events.first; billing.updates.add([purchase()]);
    expect((await event).$2, SupportEvent.needsRestore);
    expect(billing.acknowledgements, 0);
  });
  test('pending purchases do not deliver or acknowledge; explicit legacy results retain support behavior', () async {
    final billing = BenefitBilling(), delivery = FakeDelivery()..result = SupportDelivery.legacy;
    final store = PlaySupportStore(billing: billing, delivery: delivery);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    var event = store.events.first;
    billing.updates.add([purchase(status: PurchaseStatus.pending)]);
    expect((await event).$2, SupportEvent.pending);
    expect(delivery.restoredAccounts, isEmpty); expect(billing.acknowledgements, 0);
    event = store.events.first; billing.updates.add([purchase()]);
    expect((await event).$2, SupportEvent.thanked);
    await Future<void>.delayed(Duration.zero);
    expect(billing.acknowledgements, 1);
  });
  test('explicit restore waits for server delivery, including empty results and failures', () async {
    final billing = BenefitBilling()..restored = [purchase(status: PurchaseStatus.restored)];
    final delivery = FakeDelivery();
    final store = PlaySupportStore(billing: billing, delivery: delivery);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    expect(await store.restoreRemote(), 1);
    expect(delivery.restoredAccounts.single, 'a' * 64);
    billing.restored = [];
    expect(await store.restoreRemote(), 0);
    billing.restored = [purchase(status: PurchaseStatus.restored)]; delivery.fail = true;
    await expectLater(store.restoreRemote(), throwsStateError);
    expect(billing.acknowledgements, 0);
  });
  test('cloud bridge explicitly claims legacy subscriptions and rejects account changes during restoration', () async {
    final session = BenefitSession(); addTearDown(session.dispose);
    final bridge = CloudSupportDelivery(session);
    expect(await bridge.deliver(purchase()), SupportDelivery.completed);
    expect(session.submissions.last.$3, false);
    await bridge.deliver(purchase(status: PurchaseStatus.restored), restoringAccount: 'a' * 64);
    expect(session.submissions.last.$3, true);
    session.account = 'b' * 64;
    await expectLater(bridge.deliver(purchase(), restoringAccount: 'a' * 64), throwsA(isA<CloudFailure>()));
    expect(session.submissions.length, 2);
    await expectLater(bridge.checkoutAccount(SupportProducts.monthly, expectedBytes: 2000), throwsA(isA<CloudFailure>()));
    session.enabled = false;
    await expectLater(bridge.checkoutAccount(SupportProducts.monthly), throwsA(isA<CloudFailure>()));
  });
  test('an early Play stream error is handled while restore prepares the account', () async {
    final billing = BenefitBilling(), delivery = FakeDelivery()..accountReady = Completer<String>();
    final store = PlaySupportStore(billing: billing, delivery: delivery);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    final restored = store.restoreRemote();
    final expectation = expectLater(restored, throwsStateError);
    billing.updates.addError(StateError('synthetic stream failure'));
    await Future<void>.delayed(Duration.zero);
    delivery.accountReady!.complete('a' * 64);
    await expectation;
    expect(billing.acknowledgements, 0);
  });
  testWidgets('restoration names the account, requires consent, and refreshes the allowance', (tester) async {
    final session = BenefitSession(); var restores = 0;
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session, restoreBenefits: () async {
      restores++; session.remoteUsage = const CloudUsage(0, 1000, true, plan: 'subscriber'); return 1;
    })));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('cloud-restore-benefits'));
    await tester.ensureVisible(button); await tester.tap(button); await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('owner@example.com')), findsOneWidget);
    expect(restores, 0);
    await tester.tap(find.text('Cancel')); await tester.pumpAndSettle();
    expect(restores, 0);
    await tester.ensureVisible(button); await tester.tap(button); await tester.pumpAndSettle();
    await tester.tap(find.text('Restore')); await tester.pumpAndSettle();
    expect(restores, 1);
    expect(find.text('Subscriber allowance'), findsOneWidget);
    expect(find.text('Remote benefits restored. Your allowance is up to date.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('verification retry is not described as a failed payment', (tester) async {
    final billing = BenefitBilling(), delivery = FakeDelivery()..fail = true;
    final store = PlaySupportStore(billing: billing, delivery: delivery);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    await tester.pumpWidget(MaterialApp(home: SupportPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.00')); await tester.pump();
    billing.updates.add([purchase(product: SupportProducts.coffee)]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Restore remote benefits to retry'), findsOneWidget);
    expect(find.textContaining('Payment failed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('configured remote offers disclose amounts and fit a small phone at large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final billing = BenefitBilling()..remoteProducts = true;
    final delivery = FakeDelivery()..remoteOffers = true;
    final store = PlaySupportStore(billing: billing, delivery: delivery);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!), home: SupportPage(store: store)));
    await tester.pumpAndSettle();
    expect(find.text('10 GB remote data/month'), findsOneWidget);
    expect(find.text('2 remote robots at a time'), findsOneWidget);
    await tester.ensureVisible(find.text('9.90/month')); await tester.pumpAndSettle();
    await tester.tap(find.text('9.90/month')); await tester.pump();
    expect(billing.subscriptionCheckouts, 1);
    expect(billing.checkout!.applicationUserName, 'a' * 64);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('legacy support releases never query or sell the new remote products', () async {
    final billing = BenefitBilling()..remoteProducts = true;
    final store = PlaySupportStore(billing: billing);
    addTearDown(store.dispose); addTearDown(billing.updates.close);
    expect((await store.offers()).map((o) => o.id), [SupportProducts.coffee]);
    expect(billing.queried.intersection(SupportProducts.remote), isEmpty);
  });
}

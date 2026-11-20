import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ros_tester/support.dart';
import 'package:ros_tester/support_page.dart';

class FakeStore implements SupportStore {
  FakeStore({this.isAvailable = true, this.list = const []});
  final bool isAvailable;
  final List<SupportOffer> list;
  final bought = <String>[];
  final _events = StreamController<(String, SupportEvent, String?)>.broadcast();
  void finish(String id, SupportEvent e) => _events.add((id, e, null));
  @override
  Future<bool> available() async => isAvailable;
  @override
  Future<List<SupportOffer>> offers() async => list;
  @override
  Future<void> buy(SupportOffer offer) async => bought.add(offer.id);
  @override
  Stream<(String, SupportEvent, String?)> get events => _events.stream;
  @override
  Future<void> restore() async {}
}

const _offers = [
  SupportOffer(id: SupportProducts.coffee, title: 'Coffee', price: '₩1,500'),
  SupportOffer(id: SupportProducts.lunch, title: 'Lunch', price: '₩5,000'),
  SupportOffer(id: SupportProducts.monthly, title: 'Monthly', price: '₩2,900'),
];

class CheckoutBilling implements InAppPurchase {
  final updates = StreamController<List<PurchaseDetails>>.broadcast();
  bool startsCheckout = false;
  int attempts = 0;
  final product = ProductDetails(id: SupportProducts.coffee, title: 'Coffee', description: 'Support',
    price: '₩1,500', rawPrice: 1500, currencyCode: 'KRW');

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => updates.stream;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async =>
      ProductDetailsResponse(productDetails: [product], notFoundIDs: const []);
  @override
  Future<bool> buyConsumable({required PurchaseParam purchaseParam, bool autoConsume = true}) async {
    attempts++;
    return startsCheckout;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the real support page stays usable without a Play implementation', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SupportPage()));
    await tester.pumpAndSettle();
    expect(find.text('Available in the app from Google Play.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: PlaySupportStore.supported);

  testWidgets('shows the store\'s prices; a tip thanks the person and is remembered', (tester) async {
    final store = FakeStore(list: _offers);
    await tester.pumpWidget(MaterialApp(home: SupportPage(store: store)));
    await tester.pumpAndSettle();
    expect(find.text('₩1,500'), findsOneWidget);
    expect(find.text('₩2,900/month'), findsOneWidget, reason: 'a subscription says per month');
    expect(find.textContaining('every feature'), findsOneWidget);

    await tester.tap(find.text('₩1,500'));
    await tester.pump();
    expect(store.bought, [SupportProducts.coffee]);
    store.finish(SupportProducts.coffee, SupportEvent.thanked);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-thanks')), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(SupporterBadge.instance.supporter, isTrue);
    expect(find.byKey(const Key('support-badge')), findsOneWidget);
  });

  testWidgets('a canceled payment just enables the buttons again; a restored one shows no dialog', (tester) async {
    final store = FakeStore(list: _offers);
    await tester.pumpWidget(MaterialApp(home: SupportPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('₩5,000'));
    await tester.pump();
    store.finish(SupportProducts.lunch, SupportEvent.canceled);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.ancestor(of: find.text('₩5,000'), matching: find.byType(FilledButton))).onPressed,
        isNotNull);
    store.finish(SupportProducts.monthly, SupportEvent.thanked); // restored at start, not bought here
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-thanks')), findsNothing);
  });

  testWidgets('without Google Play billing it says so', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SupportPage(store: FakeStore(isAvailable: false))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-problem')), findsOneWidget);
    expect(find.textContaining('from Google Play'), findsOneWidget);
  });

  testWidgets('a rejected checkout exits the spinner and can reload product details', (tester) async {
    final billing = CheckoutBilling();
    final store = PlaySupportStore(billing: billing);
    addTearDown(store.dispose);
    addTearDown(billing.updates.close);
    await tester.pumpWidget(MaterialApp(home: SupportPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('₩1,500'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-problem')), findsOneWidget);
    expect(find.textContaining('Reload the prices'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('support-thanks')), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-problem')), findsNothing);
  });

  testWidgets('two taps before the next frame start only one checkout', (tester) async {
    final billing = CheckoutBilling()..startsCheckout = true;
    final store = PlaySupportStore(billing: billing);
    addTearDown(store.dispose);
    addTearDown(billing.updates.close);
    await tester.pumpWidget(MaterialApp(home: SupportPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('₩1,500'));
    await tester.tap(find.text('₩1,500'));
    await tester.pump();
    expect(billing.attempts, 1);
  });

  test('a purchase error retains the Billing debug message without serialising receipt objects', () async {
    final billing = CheckoutBilling();
    final store = PlaySupportStore(billing: billing);
    addTearDown(store.dispose);
    addTearDown(billing.updates.close);
    final event = store.events.first;
    billing.updates.add([PurchaseDetails(productID: '', status: PurchaseStatus.error,
      verificationData: PurchaseVerificationData(localVerificationData: '', serverVerificationData: '', source: 'test'),
      transactionDate: null)..error = IAPError(source: 'google_play', code: 'purchase_error',
        message: 'BillingResponse.developerError', details: 'Invalid product configuration.')]);
    expect((await event).$3, 'BillingResponse.developerError\nInvalid product configuration.');
  });
}

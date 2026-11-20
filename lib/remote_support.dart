import 'package:in_app_purchase/in_app_purchase.dart';
import 'cloud_session.dart';
import 'support.dart';

/// Independent beta switch: existing Play releases retain their donation-only behavior.
const remoteBenefitsEnabled = bool.fromEnvironment('PLAY_REMOTE_BENEFITS');

class CloudSupportDelivery implements SupportPurchaseDelivery {
  CloudSupportDelivery(this.session);
  final CloudSession session;
  Future<CloudBillingConfig> _configuration() async {
    if (!session.signedIn) throw const CloudFailure('Sign in to My robots before linking remote benefits.');
    final config = await session.billingConfig();
    if (!config.enabled) throw const CloudFailure('Remote purchase benefits are being prepared.');
    return config;
  }
  @override
  Future<SupportBenefits> allowances() async {
    final config = await _configuration();
    return SupportBenefits(config.products, robots: config.robotLimits);
  }
  @override
  Future<String> restoreAccount() async => (await _configuration()).accountId!;
  @override
  Future<String?> checkoutAccount(String product, {int? expectedBytes}) async {
    final config = await _configuration();
    if (config.products[product] != expectedBytes) throw const CloudFailure('Remote benefits changed. Reload the offers before paying.');
    return config.products.containsKey(product) ? config.accountId : null;
  }
  @override
  Future<SupportDelivery> deliver(PurchaseDetails purchase, {String? restoringAccount}) async {
    final config = await _configuration();
    if (restoringAccount != null && restoringAccount != config.accountId) {
      throw const CloudFailure('Your account changed. Please restore again.');
    }
    if (!config.products.containsKey(purchase.productID)) return SupportDelivery.legacy;
    final result = await session.verifyPlayPurchase(purchase.productID,
      purchase.verificationData.serverVerificationData, version: config.version,
      claimLegacy: restoringAccount != null && config.legacySubscriptions, refresh: restoringAccount != null);
    if (result['status'] == 'legacy') return SupportDelivery.legacy;
    if (result['status'] == 'inactive') return SupportDelivery.ineligible;
    if (result['granted'] == true && result['completed'] == true) return SupportDelivery.completed;
    return SupportDelivery.deferred;
  }
}

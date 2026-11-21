import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/app_language.dart';
import 'package:ros_tester/cloud_session.dart';
import 'package:ros_tester/l10n/generated/app_localizations_en.dart';
import 'package:ros_tester/l10n/generated/app_localizations_ko.dart';
import 'package:ros_tester/relay_messages.dart';
import 'package:ros_tester/remote_setup.dart';

void main() {
  final en = AppLocalizationsEn(), ko = AppLocalizationsKo();

  test('a refused service call is left to its caller', () {
    // The relay answers a blocked /rosapi/get_time lag probe with a status error and a failed response.
    expect(statusErrorIn({'op': 'status', 'level': 'error', 'id': 'request_7',
        'msg': 'This service is unavailable over remote access.'}, ko), isNull);
  });

  test('remote refusals are shown in the app language', () {
    expect(statusErrorIn({'op': 'status', 'level': 'error', 'id': 'publish:/cmd_vel:3',
        'msg': 'Remote speed limit exceeded (0.25 m/s, 0.6 rad/s).'}, ko), ko.remoteSpeedLimit);
    expect(relayMessageIn('This topic is read-only over remote access.', ko), ko.remoteReadOnly);
    expect(relayMessageIn('Invalid velocity command.', en), en.remoteCommandBlocked);
  });

  test('other errors pass through and non-errors show nothing', () {
    expect(statusErrorIn({'op': 'status', 'level': 'error', 'msg': 'Topic type mismatch'}, ko), 'Topic type mismatch');
    expect(statusErrorIn({'op': 'status', 'level': 'warning', 'msg': 'x'}, ko), isNull);
    expect(statusErrorIn({'topic': '/odom', 'msg': {}}, ko), isNull);
  });

  test('server and remote session messages are translated, others pass through', () {
    expect(relayMessageIn('Remote usage limit reached.', ko), ko.rtUsageLimit);
    expect(relayMessageIn('This registration code is invalid or expired.', ko), ko.rtRegistrationExpired);
    expect(relayMessageIn('Robot went offline.', en), en.rtRobotOffline);
    expect(relayMessageIn('robot says: battery low', ko), 'robot says: battery low');
    expect(relayMessageIn('hoyadong cannot use sudo with this password. Use an administrator account.', ko),
        ko.rtSudoRefused('hoyadong'));
  });

  test('account and setup failures show in the chosen language', () {
    final before = appLocale.value;
    addTearDown(() => appLocale.value = before);
    appLocale.value = const Locale('ko');
    expect(const CloudFailure('That password is not correct.').message, ko.rtWrongPassword);
    expect(const RemoteSetupFailure('Setup did not finish. Try again.').message, ko.rtSetupUnfinished);
    expect(const CloudFailure('E: package not found').message, 'E: package not found');
    expect(const CloudUsage(100000000, 100000000, true).summaryIn(ko), '이번 달 100.00 / 100 MB');
  });
}

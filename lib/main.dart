import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'app_theme.dart';
import 'app_language.dart';
import 'l10n/generated/app_localizations.dart';
import 'background_service.dart';
import 'robot_widget.dart';
import 'support.dart';
import 'remote_support.dart';
import 'cloud_session.dart';
import 'connect_page.dart';
import 'relay_access.dart';
import 'cloud_robots_page.dart';
import 'link_robot_page.dart';
import 'app_links.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge to edge on every Android version, as Android 15+ already does (screens keep clear of the bars
  // with SafeArea); without this older phones would show the app inside opaque bars.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  MediaKit.ensureInitialized(); // RTSP camera playback (libmpv)
  await loadThemeMode();
  await loadAppLanguage();
  await RelayAccess.load(); // tokens for robots reached through the relay
  // The background notification's Stop button talks to the app through this port.
  ForegroundPresence.initCommunication();
  // The home screen widget: a tap that opened the app, and its state while no robot is connected.
  await RobotWidget.init();
  // Support purchases (Google Play): acknowledge ones that finished while the app was closed.
  PlaySupportStore.start(delivery: cloudAccountsEnabled && remoteBenefitsEnabled
    ? CloudSupportDelivery(CloudSession.shared) : null); // no-op outside Google Play platforms
  unawaited(SupporterBadge.instance.load());
  unawaited(RobotWidget.disconnected());
  // A robot's approval QR code opens the app (Android App Links): show the approval on top.
  if (cloudAccountsEnabled) await AppLinks.start();
  runApp(const MyApp());
  if (cloudAccountsEnabled) {
    AppLinks.codes.listen(openRobotLink);
    final first = AppLinks.takePending();
    if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => openRobotLink(first));
  }
}

final appNavigator = GlobalKey<NavigatorState>();

/// Opens the approval for the robot showing [code] (from a QR code or link).
void openRobotLink(String code) =>
    appNavigator.currentState?.push(MaterialPageRoute<void>(builder: (_) => LinkRobotPage(code: code)));

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: Listenable.merge([appLocale, appThemeMode]),
      builder: (context, _) => MaterialApp(
      title: 'Mobile ROS',
      navigatorKey: appNavigator,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: appThemeMode.value,
      locale: appLocale.value,
      localizationsDelegates: appLocalizationDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const ConnectPage(),
      onGenerateInitialRoutes: cloudAccountsEnabled && kIsWeb ? (name) => [
        MaterialPageRoute<void>(settings: const RouteSettings(name: '/my-robots'), builder: (_) => const CloudRobotsPage()),
        // A robot's QR code: /app/#/link?code=XXXX-XXXX opens the approval on top of My robots.
        if (Uri.tryParse(name) case final uri? when uri.path == '/link')
          MaterialPageRoute<void>(settings: const RouteSettings(name: '/link'),
            builder: (_) => LinkRobotPage(code: uri.queryParameters['code'] ?? '')),
      ] : null,
      routes: {if (cloudAccountsEnabled) '/my-robots': (_) => const CloudRobotsPage()},
    ));
  }
}

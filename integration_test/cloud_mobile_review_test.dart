// Android-only review: synthetic HTTPS identity/registry, real native vault and live Gazebo.
// The test certificate is trusted only here. Production CloudSession never overrides TLS trust.
// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/cloud_robots_page.dart';
import 'package:ros_tester/cloud_session.dart';
import 'package:ros_tester/relay_access.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/map_page.dart';

class QaTrust extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(
    SecurityContext(withTrustedRoots: true)..setTrustedCertificatesBytes(base64Decode(const String.fromEnvironment('QA_CERT'))));
}

Future<void> waitFor(WidgetTester tester, bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = QaTrust());
  tearDownAll(() => HttpOverrides.global = null);
  testWidgets('Android signup, native vault restore, claim and live remote drive/STOP/lifecycle', (tester) async {
    await RelayAccess.load();
    const vault = SecureSessionVault('android-qa-only');
    await vault.clear();
    var session = CloudSession(server: 'https://10.0.2.2:19443', vault: vault);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: CloudRobotsPage(session: session)));
    await waitFor(tester, () => find.byKey(const Key('cloud-switch-mode')).evaluate().isNotEmpty &&
      find.byKey(const Key('cloud-progress')).evaluate().isEmpty, 'sign in ready');
    debugPrint('QA_SCREEN signin');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.tap(find.byKey(const Key('cloud-switch-mode'))); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cloud-email')), 'qa@example.invalid');
    await tester.enterText(find.byKey(const Key('cloud-password')), 'qa-password-1234');
    await tester.enterText(find.byKey(const Key('cloud-confirm-password')), 'qa-password-1234');
    FocusManager.instance.primaryFocus?.unfocus(); await tester.pumpAndSettle();
    debugPrint('QA_SCREEN signup');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.ensureVisible(find.byKey(const Key('cloud-signin')));
    await tester.tap(find.byKey(const Key('cloud-signin')));
    await waitFor(tester, () => find.text('Check your email').evaluate().isNotEmpty, 'synthetic signup email instruction');
    debugPrint('QA_SCREEN verify-email');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.tap(find.byKey(const Key('cloud-email-confirmed'))); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cloud-password')), 'qa-password-1234');
    FocusManager.instance.primaryFocus?.unfocus(); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cloud-signin')));
    await waitFor(tester, () => find.text('My robots').evaluate().isNotEmpty &&
      find.byKey(const Key('cloud-progress')).evaluate().isEmpty, 'login');
    expect(await vault.read(), 'qa-refresh', reason: 'real Android secure storage');
    await tester.pumpWidget(const SizedBox()); session.dispose();
    session = CloudSession(server: 'https://10.0.2.2:19443', vault: vault);
    await session.restore();
    expect(session.signedIn, true, reason: 'restores from native vault in a new session object');
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: CloudRobotsPage(session: session)));
    await waitFor(tester, () => find.byKey(const Key('cloud-add')).evaluate().isNotEmpty &&
      find.byKey(const Key('cloud-progress')).evaluate().isEmpty, 'restored robot list');
    await tester.tap(find.byKey(const Key('cloud-add'))); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cloud-claim-code')), const String.fromEnvironment('QA_CODE'));
    FocusManager.instance.primaryFocus?.unfocus(); await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('cloud-register')));
    await tester.tap(find.byKey(const Key('cloud-register')));
    await waitFor(tester, () => find.text('Gazebo QA robot').evaluate().isNotEmpty, 'one-use ownership claim');
    debugPrint('QA_SCREEN robots');
    await Future<void>.delayed(const Duration(seconds: 2));

    await tester.tap(find.text('Connect'));
    await waitFor(tester, () => find.byKey(const Key('tool-control')).evaluate().isNotEmpty, 'robot home');
    await tester.pump(const Duration(milliseconds: 400));
    debugPrint('QA_SCREEN robot-home');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.ensureVisible(find.byKey(const Key('tool-control')));
    await tester.tap(find.byKey(const Key('tool-control')));
    await waitFor(tester, () => find.byKey(const Key('profile-continue')).evaluate().isNotEmpty, 'robot type confirmation');
    await tester.ensureVisible(find.byKey(const Key('profile-continue')));
    await tester.tap(find.byKey(const Key('profile-continue'))); await tester.pump();
    await waitFor(tester, () => find.byType(RawImage).evaluate().isNotEmpty, 'live camera image on Drive');
    debugPrint('QA_SCREEN drive-camera');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pageBack(); await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('tool-map')));
    await tester.tap(find.byKey(const Key('tool-map')));
    final mapCanvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MapPainter);
    await waitFor(tester, () {
      if (mapCanvas.evaluate().isEmpty) return false;
      final painter = tester.widget<CustomPaint>(mapCanvas.first).painter! as MapPainter;
      return painter.showRobot && painter.image != null && painter.mapData.isNotEmpty;
    }, 'rasterized map canvas with robot pose');
    expect(find.text('Set pose'), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    debugPrint('QA_SCREEN map');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pageBack(); await tester.pump();

    final robot = (await session.robots()).single;
    final connection = await session.connect(robot);
    final ros = RosClient(connection);
    math.Point<double>? position;
    double speed = 0;
    var camera = false, map = false;
    final subscription = connection.messages.listen((event) {
      if (event['op'] == 'status' || event['op'] == 'relay_end') debugPrint('QA remote status: ${event['msg']}');
      final msg = event['msg'];
      if (event['topic'] == '/odom' && msg is Map) {
        final p = msg['pose']['pose']['position'];
        position = math.Point((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
        speed = (msg['twist']['twist']['linear']['x'] as num).toDouble();
      }
      if (event['topic'] == '/camera/image_raw/compressed' && msg is Map && (msg['data'] as String? ?? '').isNotEmpty) camera = true;
      if (event['topic'] == '/map') map = true;
    });
    connection.send({'op': 'subscribe', 'topic': '/odom', 'throttle_rate': 0});
    connection.send({'op': 'subscribe', 'topic': '/map', 'type': 'nav_msgs/msg/OccupancyGrid'});
    // Discover the simulation's compressed image topic rather than assuming a camera name.
    final topics = await connection.call('/rosapi/topics');
    final names = List<String>.from(topics['topics'] as List);
    final types = List<String>.from(topics['types'] as List);
    final image = names.indexWhere((name) => types[names.indexOf(name)].endsWith('/CompressedImage'));
    if (image >= 0) {
      final cameraTopic = names[image];
      connection.messages.listen((event) { if (event['topic'] == cameraTopic) camera = true; });
      connection.send({'op': 'subscribe', 'topic': cameraTopic, 'type': types[image]});
    }
    await waitFor(tester, () => position != null && map && camera, 'odometry, map and camera over TLS relay');
    final observer = RosConnection('10.0.2.2', '9090');
    addTearDown(observer.close);
    await observer.ready;
    double physicalSpeed = 0;
    observer.messages.listen((event) {
      if (event['topic'] == '/odom') physicalSpeed = (event['msg']['twist']['twist']['linear']['x'] as num).toDouble();
    });
    observer.send({'op': 'subscribe', 'topic': '/odom', 'throttle_rate': 50});
    final start = position!;
    final drive = DriveController(ros);
    drive.configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    await drive.driveFor(const DriveCommand(linearX: 0.15), const Duration(seconds: 2));
    expect(connection.isClosed, false, reason: connection.lastError);
    expect(drive.lastError, isNull);
    drive.stop();
    await waitFor(tester, () => speed.abs() < 0.01, 'STOP');
    final distance = position!.distanceTo(start);
    expect(distance, greaterThan(0.12));
    debugPrint('Android TLS relay drove ${distance.toStringAsFixed(2)}m; STOP confirmed by odometry.');
    final moving = drive.driveFor(const DriveCommand(linearX: 0.15), const Duration(seconds: 5));
    await waitFor(tester, () => speed > 0.05, 'moving before background');
    debugPrint('QA_BACKGROUND_NOW'); // host presses Home on this isolated emulator
    await waitFor(tester, () => connection.isClosed, 'background closes remote connection');
    expect(connection.lastError, contains('paused'));
    await waitFor(tester, () => physicalSpeed.abs() < 0.01, 'independent odometry confirms background STOP');
    debugPrint('Android Home transition closed remote access; independent odometry confirmed STOP.');
    await moving;
    // The host returns the same Activity to the front. Waiting with tester.pump while Android is
    // paused would wait for a VSYNC that Android deliberately does not send to hidden activities.
    final resumeDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      if (DateTime.now().isAfter(resumeDeadline)) fail('Host did not resume the original QA activity.');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    drive.dispose(); await subscription.cancel(); ros.dispose();
    final usage = await session.usage();
    expect(usage.usedBytes, greaterThan(0));
    await session.remove(robot); await session.signOut();
    expect(await vault.read(), isNull);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));
}

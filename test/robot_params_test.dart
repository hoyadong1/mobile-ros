import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/params_page.dart';
import 'package:ros_tester/robot_params.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_client.dart';

import 'support/fake_ros_connection.dart';

/// A ROS 2 robot whose nodes answer the parameter services from [params] (node -> name -> value).
class ParamRobot extends FakeConnection {
  ParamRobot(this.params, {this.refuse = const {}, this.loseFirstReply = const {}, this.mute = const {}});
  /// Nodes whose first reply is lost (as with rosbridge on ROS 2), and nodes that never answer.
  final Set<String> loseFirstReply, mute;
  final _lost = <String>{};
  final Map<String, Map<String, ParamValue>> params;
  /// Parameters the robot refuses to change, with the reason.
  final Map<String, String> refuse;

  @override
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]) async {
    calls.add((service, args));
    if (service == '/rosapi/nodes') return {'nodes': params.keys.toList()};
    if (service == '/rosapi/topics') return {'topics': <String>[], 'types': <String>[]};
    final i = service.lastIndexOf('/');
    final node = service.substring(0, i), op = service.substring(i + 1);
    final p = params[node];
    if (p == null) throw StateError('no node $node');
    if (mute.contains(node) || (loseFirstReply.contains(node) && _lost.add(node))) {
      return Completer<Map<String, dynamic>>().future; // never answers
    }
    switch (op) {
      case 'get_parameters':
        // Like rclcpp: an undeclared name makes the whole answer empty.
        final names = (args['names'] as List).cast<String>();
        if (names.any((n) => !p.containsKey(n))) return {'values': <Object>[]};
        return {'values': [for (final n in names) p[n]!.toRos2()]};
      case 'list_parameters':
        return {'result': {'names': p.keys.toList(), 'prefixes': <String>[]}};
      case 'set_parameters':
        final results = <Map<String, dynamic>>[];
        for (final e in args['parameters'] as List) {
          final name = e['name'] as String;
          final why = refuse[name];
          if (why == null) p[name] = ParamValue.fromRos2(e['value'] as Map);
          results.add({'successful': why == null, 'reason': why ?? ''});
        }
        return {'results': results};
    }
    return serviceResponses[service] ?? {};
  }
}

ParamRobot _nav2({Map<String, String> refuse = const {}}) => ParamRobot({
  '/controller_server': {
    'FollowPath.max_vel_x': const ParamValue(ParamValue.double_, 0.26),
    'FollowPath.max_speed_xy': const ParamValue(ParamValue.double_, 0.26),
    'FollowPath.max_vel_theta': const ParamValue(ParamValue.double_, 1.0),
    'general_goal_checker.xy_goal_tolerance': const ParamValue(ParamValue.double_, 0.25),
    'general_goal_checker.yaw_goal_tolerance': const ParamValue(ParamValue.double_, 0.25),
    'controller_frequency': const ParamValue(ParamValue.double_, 20.0),
    'use_sim_time': const ParamValue(ParamValue.boolean, true),
  },
  '/velocity_smoother': {'max_velocity': const ParamValue(ParamValue.doubleArray, [0.26, 0.0, 1.0])},
  '/local_costmap/local_costmap': {
    'inflation_layer.inflation_radius': const ParamValue(ParamValue.double_, 0.55),
    'robot_radius': const ParamValue(ParamValue.double_, 0.22),
  },
  '/global_costmap/global_costmap': {'inflation_layer.inflation_radius': const ParamValue(ParamValue.double_, 0.55)},
}, refuse: refuse);

void main() {
  test('ParamValue reads and writes rcl_interfaces values and ROS 1 JSON', () {
    final v = ParamValue.fromRos2({'type': 8, 'double_array_value': [0.26, 0, 1]});
    expect(v.number(2), 1.0);
    expect(v.withNumber(1.2, 2).toRos2(), {'type': 8, 'double_array_value': [0.26, 0.0, 1.2]});
    expect(ParamValue.fromRos2({'type': 2, 'integer_value': 7}).withNumber(7.6).value, 8, reason: 'stays a whole number');
    expect(ParamValue.fromJson(true).type, ParamValue.boolean);
    expect(ParamValue.fromJson(0.5).display(), '0.5');
    expect(ParamValue.fromJson([1, 2.5]).display(), '[1.0, 2.5]');
  });

  test('finds the common settings that exist, in shown units', () async {
    final robot = _nav2();
    final client = ParamClient(RosClient(robot), RosVersion.ros2);
    final found = await findCommonSettings(client, robot.params.keys.toList());
    final byKey = {for (final f in found) f.setting.key: f};
    expect(byKey.keys, containsAll(['speed', 'turn', 'clearance', 'radius', 'arrive', 'heading']));
    expect(byKey.containsKey('sight'), isFalse, reason: 'not on this robot');
    expect(byKey['speed']!.values.keys.map((t) => t.id), containsAll([
      '/controller_server:FollowPath.max_vel_x', '/velocity_smoother:max_velocity[0]']));
    expect(byKey['turn']!.shown, closeTo(57.3, 0.1), reason: 'radians shown as degrees');
    expect(robot.calls.where((c) => c.$1 == '/controller_server/get_parameters'), hasLength(1),
        reason: 'one request per node, for the names it has');
    expect(await client.get('/controller_server', ['FollowPath.max_vel_x', 'FollowPath.desired_linear_vel']),
        {'FollowPath.max_vel_x': const ParamValue(ParamValue.double_, 0.26),
         'FollowPath.desired_linear_vel': const ParamValue(0, null)},
        reason: 'an undeclared name does not hide the others');
  });

  test('applying a setting changes every parameter behind it, array elements included', () async {
    final robot = _nav2();
    final client = ParamClient(RosClient(robot), RosVersion.ros2);
    var found = {for (final f in await findCommonSettings(client, robot.params.keys.toList())) f.setting.key: f};
    expect(await applySetting(client, found['speed']!, 0.4), isEmpty);
    // Turning speed shares velocity_smoother max_velocity with top speed: applying it must keep 0.4.
    expect(await applySetting(client, found['turn']!, 90), isEmpty);
    expect(robot.params['/controller_server']!['FollowPath.max_vel_x']!.value, 0.4);
    expect(robot.params['/controller_server']!['FollowPath.max_speed_xy']!.value, 0.4);
    final mv = robot.params['/velocity_smoother']!['max_velocity']!.value as List;
    expect(mv[0], 0.4);
    expect(mv[2], closeTo(1.5708, 1e-3));
    found = {for (final f in await findCommonSettings(client, robot.params.keys.toList())) f.setting.key: f};
    expect(await applySetting(client, found['clearance']!, 0.3), isEmpty);
    expect(robot.params['/global_costmap/global_costmap']!['inflation_layer.inflation_radius']!.value, 0.3);
  });

  test('a lost first reply is asked again; a node that never answers is reported', () async {
    final robot = ParamRobot(_nav2().params, loseFirstReply: {'/controller_server'},
        mute: {'/local_costmap/local_costmap'});
    final client = ParamClient(RosClient(robot), RosVersion.ros2, timeout: const Duration(milliseconds: 50));
    final silent = <String>{};
    final found = {for (final f in await findCommonSettings(client, robot.params.keys.toList(), silent: silent))
      f.setting.key: f};
    expect(found['speed']!.values.keys.map((t) => t.node), contains('/controller_server'), reason: 'retried');
    expect(silent, {'/local_costmap/local_costmap'});
    expect(found['radius'], isNull, reason: 'only the silent costmap holds it');
  });

  test('a refusal comes back with the robot\'s reason', () async {
    final robot = _nav2(refuse: {'robot_radius': 'parameter is read-only'});
    final client = ParamClient(RosClient(robot), RosVersion.ros2);
    final found = {for (final f in await findCommonSettings(client, robot.params.keys.toList())) f.setting.key: f};
    final failed = await applySetting(client, found['radius']!, 0.3);
    expect(failed.values.single, 'parameter is read-only');
  });

  test('ROS 1 goes through rosapi with JSON values', () async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/get_param'] = {'value': jsonEncode(0.5)};
    final client = ParamClient(RosClient(robot), RosVersion.ros1);
    final v = await client.get('', ['/move_base/DWAPlannerROS/max_vel_x']);
    expect(v.values.single.value, 0.5);
    await client.set('', {'/move_base/DWAPlannerROS/max_vel_x': const ParamValue(ParamValue.double_, 0.3)});
    expect(robot.calls.last.$1, '/rosapi/set_param');
    expect(robot.calls.last.$2, {'name': '/move_base/DWAPlannerROS/max_vel_x', 'value': '0.3'});
  });

  testWidgets('Tune the robot: change with the slider buttons, apply, see it on the robot', (tester) async {
    final robot = _nav2();
    final session = RobotSession(connection: robot, ip: 'robot', port: '9090');
    addTearDown(session.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: TuneRobotPage(session: session)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Top speed'), findsOneWidget);
    expect(find.text('0.26 m/s'), findsOneWidget);
    expect(find.byKey(const Key('tune-apply')), findsNothing);

    final card = find.byKey(const Key('tune-speed'));
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.descendant(of: card, matching: find.byTooltip('More')));
      await tester.pump();
    }
    expect(find.text('0.30 m/s'), findsOneWidget);
    expect(find.text('Now 0.26 m/s on the robot'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tune-apply')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(robot.params['/controller_server']!['FollowPath.max_vel_x']!.value, closeTo(0.30, 1e-9));
    expect((robot.params['/velocity_smoother']!['max_velocity']!.value as List)[0], closeTo(0.30, 1e-9));
    expect(find.byKey(const Key('tune-apply')), findsNothing);
    expect(find.byKey(const Key('tune-restore')), findsOneWidget, reason: 'can go back to the first values');
    await tester.pump(const Duration(seconds: 5)); // the "changed" message goes away
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('tune-restore')));
    await tester.tap(find.byKey(const Key('tune-restore')));
    await tester.pump();
    expect(find.text('0.26 m/s'), findsOneWidget);

    await tester.tap(find.text('All parameters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/controller_server'));
    await tester.pumpAndSettle();
    expect(find.text('controller_frequency'), findsOneWidget);
    await tester.tap(find.text('controller_frequency'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('param-value')), '10');
    await tester.tap(find.byKey(const Key('param-value-ok')));
    await tester.pumpAndSettle();
    expect(robot.params['/controller_server']!['controller_frequency']!.value, 10.0);
    expect(find.text('10.0'), findsOneWidget);
  });
}

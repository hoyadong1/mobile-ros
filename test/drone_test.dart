import 'dart:convert';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/drone.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

const setpointTopic = '/mavros/setpoint_velocity/cmd_vel_unstamped';

void main() {
  final drone = RobotProfile.defaults(DriveType.aerial);

  test('mode-2 sticks map to a world-frame setpoint rotated by heading', () {
    // Facing north (+y in ENU, yaw 90°), right stick forward = +y world velocity.
    final north = droneSetpoint(drone, SpeedPreset.fast, const StickInput(rightY: -1), math.pi / 2);
    expect(north.linearX, closeTo(0, 1e-9));
    expect(north.linearY, closeTo(2.0, 1e-9));
    final climbYaw = droneSetpoint(drone, SpeedPreset.slow, const StickInput(leftY: -1, leftX: -1), 0);
    expect(climbYaw.linearZ, closeTo(2.0 * 0.5 * 0.3, 1e-9), reason: 'vertical is half the horizontal max');
    expect(climbYaw.angularZ, closeTo(0.3, 1e-9), reason: 'left = yaw left (positive)');
    final strafe = droneSetpoint(drone, SpeedPreset.fast, const StickInput(rightX: -1), 0);
    expect(strafe.linearY, closeTo(2.0, 1e-9), reason: 'right stick left = fly left');
    expect(droneSetpoint(drone, SpeedPreset.fast, StickInput.zero, 1.0).isStop, isTrue, reason: 'hover');
  });

  test('MAVROS helpers and suggestion', () {
    expect(mavrosNamespace('/uav1/mavros/setpoint_velocity/cmd_vel_unstamped'), '/uav1/mavros');
    expect(mavrosNamespace('/cmd_vel'), '/mavros');
    expect(yawOf({'x': 0.0, 'y': 0.0, 'z': math.sin(math.pi / 4), 'w': math.cos(math.pi / 4)}), closeTo(math.pi / 2, 1e-9));
    final guess = suggestProfile({
      // Real MAVROS order: /mavros/hil/state sorts before /mavros/state.
      'topics': ['/mavros/hil/state', '/mavros/local_position/pose', '/mavros/setpoint_velocity/cmd_vel_unstamped',
        '/mavros/state'],
      'types': ['mavros_msgs/msg/HilStateQuaternion', 'geometry_msgs/msg/PoseStamped', 'geometry_msgs/msg/Twist',
        'mavros_msgs/msg/State'],
    });
    expect(guess.drive, DriveType.aerial);
    expect(guess.commandTopic, setpointTopic, reason: 'namespace /mavros, not /mavros/hil');
    final multi = suggestProfile({'topics': ['/uav2/mavros/setpoint_velocity/cmd_vel_unstamped', '/uav2/mavros/state'],
      'types': ['geometry_msgs/msg/Twist', 'mavros_msgs/msg/State']});
    expect(multi.commandTopic, '/uav2/mavros/setpoint_velocity/cmd_vel_unstamped');
    expect(setModeArgs(FlightMode.land), {'base_mode': 0, 'custom_mode': 'AUTO.LAND'});
  });

  testWidgets('drone: hold-to-take-off arms, sticks take OFFBOARD control, release hovers, HOLD loiters', (tester) async {
    SharedPreferences.setMockInitialValues({'robot_profile:robot:9090': jsonEncode(drone.toJson())});
    final robot = FakeConnection()
      ..serviceResponses['/mavros/set_mode'] = {'mode_sent': true}
      ..serviceResponses['/mavros/cmd/arming'] = {'success': true, 'result': 0};
    addTearDown(robot.close);
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: ControlScreen(
      ip: 'robot', port: '9090', channel: robot, imageConnectionFactory: (_, _) => FakeConnection())));
    await tester.pump();
    await tester.pump();
    expect(find.text('HOLD'), findsOneWidget, reason: 'drones hover instead of a motor stop');
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/mavros/state')));
    expect(find.text('NO FLIGHT CONTROLLER'), findsOneWidget);

    void state(bool armed, String mode) => robot.events.add({'op': 'publish', 'topic': '/mavros/state',
      'msg': {'connected': true, 'armed': armed, 'mode': mode}});
    state(false, 'AUTO.LOITER');
    await tester.pump();
    List<Map> setpoints() => robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == setpointTopic).cast<Map>().toList();
    await tester.pump(const Duration(milliseconds: 300));
    expect(setpoints(), isEmpty, reason: 'nothing is streamed while disarmed');

    List<(String, Map<String, dynamic>)> mavros() => robot.calls.where((c) => c.$1.startsWith('/mavros')).toList();
    await tester.tap(find.byKey(const Key('drone-takeoff')));
    await tester.pump();
    expect(mavros(), isEmpty, reason: 'a short tap does not take off');
    await tester.longPress(find.byKey(const Key('drone-takeoff')));
    await tester.pump();
    expect(mavros().map((c) => (c.$1, c.$2['custom_mode'] ?? c.$2['value'])).toList(),
        [('/mavros/set_mode', 'AUTO.TAKEOFF'), ('/mavros/cmd/arming', true)]);

    // Airborne, holding, facing north.
    state(true, 'AUTO.LOITER');
    robot.events.add({'op': 'publish', 'topic': '/mavros/local_position/pose', 'msg': {'pose': {
      'position': {'x': 0.0, 'y': 0.0, 'z': 0.4}, // local z is not altitude (EKF origin drift)
      'orientation': {'x': 0.0, 'y': 0.0, 'z': math.sin(math.pi / 4), 'w': math.cos(math.pi / 4)}}}});
    robot.events.add({'op': 'publish', 'topic': '/mavros/global_position/rel_alt', 'msg': {'data': 2.5}});
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining('ALT 2.5 m'), findsOneWidget);
    expect(setpoints(), isNotEmpty, reason: 'zero setpoints stream while armed so OFFBOARD can engage');

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('stick-right'))));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 250));
    expect(mavros().last.$1, '/mavros/set_mode');
    expect(mavros().last.$2, {'base_mode': 0, 'custom_mode': 'OFFBOARD'});
    final forward = setpoints().last['msg'];
    expect(forward['linear']['y'], greaterThan(0.1), reason: 'forward while facing north = +y world');
    expect((forward['linear']['x'] as num).abs(), lessThan(0.05));

    state(true, 'OFFBOARD');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 250));
    final hover = setpoints().last['msg'];
    expect([hover['linear']['x'], hover['linear']['y'], hover['linear']['z']], [0, 0, 0], reason: 'release = hover');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700))); // real clock
    await tester.pump(const Duration(milliseconds: 150));
    expect(mavros().last.$2['custom_mode'], 'AUTO.LOITER', reason: 'centred sticks hand over to position hold');
    state(true, 'AUTO.LOITER');
    await tester.pump();

    await tester.tap(find.byKey(const Key('estop')));
    await tester.pump();
    expect(mavros().last.$1, '/mavros/set_mode');
    expect(mavros().last.$2, {'base_mode': 0, 'custom_mode': 'AUTO.LOITER'});
    expect(find.byKey(const Key('drone-land')), findsOneWidget);
    await tester.tap(find.byKey(const Key('drone-land')));
    await tester.pump();
    expect(mavros().last.$2['custom_mode'], 'AUTO.LAND');
    await tester.pumpWidget(const SizedBox());
  });
}

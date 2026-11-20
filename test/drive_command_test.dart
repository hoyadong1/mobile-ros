import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_image.dart';

void main() {
  final diff = RobotProfile.defaults(DriveType.differential);
  final omni = RobotProfile.defaults(DriveType.holonomic);
  final car = RobotProfile.defaults(DriveType.ackermann);

  test('stick up = forward, stick left = left (ROS conventions) for every drive type', () {
    const upLeft = StickInput(leftX: -1, leftY: -1, rightX: -1);
    final d = commandFor(diff, SpeedPreset.fast, upLeft);
    expect([d.linearX, d.linearY, d.angularZ], [0.5, 0, 1.0], reason: 'differential ignores sideways');
    final o = commandFor(omni, SpeedPreset.fast, upLeft);
    expect([o.linearX, o.linearY, o.angularZ], [0.5, 0.5, 1.0]);
    final c = commandFor(car, SpeedPreset.fast, upLeft);
    expect([c.linearX, c.steering, c.angularZ], [1.0, 0.4, 0]);
  });

  test('presets scale speed but not the Ackermann steering angle', () {
    const full = StickInput(leftY: -1, rightX: 1);
    expect(commandFor(diff, SpeedPreset.slow, full).linearX, closeTo(0.15, 1e-9));
    expect(commandFor(diff, SpeedPreset.normal, full).angularZ, closeTo(-0.6, 1e-9));
    final slowCar = commandFor(car, SpeedPreset.slow, full);
    expect(slowCar.linearX, closeTo(0.3, 1e-9));
    expect(slowCar.steering, closeTo(-0.4, 1e-9));
    expect(commandFor(diff, SpeedPreset.fast, const StickInput(leftY: -3)).linearX, 0.5, reason: 'clamped');
    expect(commandFor(diff, SpeedPreset.fast, StickInput.zero).isStop, isTrue);
  });

  test('Twist and AckermannDriveStamped messages per ROS version', () {
    final twist = commandMessage(omni, const DriveCommand(linearX: 0.1, linearY: 0.2, angularZ: 0.3), RosVersion.ros2);
    expect(twist, {'linear': {'x': 0.1, 'y': 0.2, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.3}});
    final ros2 = commandMessage(car, const DriveCommand(linearX: 0.5, steering: -0.2), RosVersion.ros2);
    expect(ros2['header'], {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': 'base_link'});
    expect(ros2['drive']['speed'], 0.5);
    expect(ros2['drive']['steering_angle'], -0.2);
    final ros1 = commandMessage(car, DriveCommand.stop, RosVersion.ros1);
    expect(ros1['header']['stamp'], {'secs': 0, 'nsecs': 0});
    expect(ros1['header']['seq'], 0);
  });

  test('profile suggestion: Ackermann topic, colour camera over depth, Twist fallback', () {
    final carGuess = suggestProfile({
      'topics': ['/vesc/ackermann_cmd', '/camera/depth/image_raw', '/camera/color/image_raw'],
      'types': ['ackermann_msgs/msg/AckermannDriveStamped', 'sensor_msgs/msg/Image', 'sensor_msgs/msg/Image'],
    });
    expect(carGuess.drive, DriveType.ackermann);
    expect(carGuess.commandTopic, '/vesc/ackermann_cmd');
    expect(carGuess.cameraSource, CameraSource.rosImage);
    expect(carGuess.cameraTopic, '/camera/color/image_raw');

    final ros1 = suggestProfile({'topics': ['/robot/cmd_vel'], 'types': ['geometry_msgs/Twist']});
    expect(ros1.drive, DriveType.differential);
    expect(ros1.commandTopic, '/robot/cmd_vel');
    expect(ros1.cameraSource, CameraSource.none);

    final unknown = suggestProfile(null, rtspUrl: 'rtsp://robot:8554/test');
    expect(unknown.commandTopic, '/cmd_vel');
    expect(unknown.cameraSource, CameraSource.none, reason: 'no image topic: do not guess a stream');
    expect(unknown.rtspUrl, 'rtsp://robot:8554/test', reason: 'kept as the settings default');
  });

  test('profiles survive a JSON round trip and bad data is rejected', () {
    final p = RobotProfile.defaults(DriveType.holonomic, cameraTopic: '/cam').copyWith(maxLinear: 1.2);
    final back = RobotProfile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>)!;
    expect(back.toJson(), p.toJson());
    expect(RobotProfile.fromJson({'drive': 'hovercraft'}), isNull);
  });

  test('ROS image decoding handles BGR and row padding', () {
    // 2x1 bgr8 image, step 8 (2 bytes padding): blue pixel then red pixel.
    final data = Uint8List.fromList([255, 0, 0, 0, 0, 255, 9, 9]);
    final frame = decodeRosImage({'encoding': 'bgr8', 'width': 2, 'height': 1, 'step': 8, 'data': base64Encode(data)});
    expect(frame.pixels, [0, 0, 255, 255, 255, 0, 0, 255]);
    expect(() => decodeRosImage({'encoding': '16UC1', 'width': 1, 'height': 1, 'data': ''}), throwsFormatException);
  });

  test('camera suggestion prefers a colour CompressedImage over raw and never depth', () {
    final guess = suggestProfile({
      'topics': ['/cmd_vel', '/camera/image_raw', '/camera/image_raw/compressed', '/camera/depth/image_raw/compressed'],
      'types': ['geometry_msgs/msg/Twist', 'sensor_msgs/msg/Image', 'sensor_msgs/msg/CompressedImage',
        'sensor_msgs/msg/CompressedImage'],
    });
    expect(guess.cameraTopic, '/camera/image_raw/compressed');
    final depthOnly = suggestProfile({
      'topics': ['/camera/image_raw', '/camera/depth/compressed'],
      'types': ['sensor_msgs/msg/Image', 'sensor_msgs/msg/CompressedImage'],
    });
    expect(depthOnly.cameraTopic, '/camera/image_raw', reason: 'a depth stream is not a camera view');
  });

  testWidgets('CompressedImage messages decode with the platform codec', (tester) async {
    const png1x1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';
    final msg = {'header': {}, 'format': 'png', 'data': png1x1};
    expect(isCompressedImage(msg), isTrue);
    expect(isCompressedImage({'encoding': 'rgb8', 'width': 1, 'height': 1, 'data': ''}), isFalse);
    final image = (await tester.runAsync(() => decodeCompressedImage(msg)))!;
    expect([image.width, image.height], [1, 1]);
    image.dispose();
    await expectLater(decodeCompressedImage({'format': '16UC1; compressedDepth', 'data': png1x1}),
        throwsFormatException);
  });
}

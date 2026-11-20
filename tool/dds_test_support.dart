// Shared by the live checks in tool/: the bundled ROS 2 message definitions, read from the asset file
// (live checks run with `flutter test`, where rootBundle has no app assets).
import 'dart:convert';
import 'dart:io';
import 'package:ros_tester/dds/ros_interfaces.dart';

RosInterfaces bundledInterfaces() =>
    RosInterfaces(Map<String, String>.from(jsonDecode(File('assets/ros2_interfaces.json').readAsStringSync()) as Map));

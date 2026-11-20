import 'dart:async';
import 'package:ros_tester/ros_connection.dart';

class FakeConnection implements RosConnection {
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];
  /// Canned `values` per service name; unknown services answer `{}`.
  final serviceResponses = <String, Map<String, dynamic>>{};
  /// Every service call made, in order: (service, args).
  final calls = <(String, Map<String, dynamic>)>[];
  @override
  bool isClosed = false;
  @override
  String? lastError;
  @override
  Duration get timeout => const Duration(seconds: 8);
  @override
  Stream<Map<String, dynamic>> get messages => events.stream;
  @override
  Future<void> get ready async {}
  @override
  void send(Map<String, dynamic> message) => sent.add(message);
  @override
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]) async {
    calls.add((service, args));
    return serviceResponses[service] ?? {};
  }
  @override
  void close() { isClosed = true; events.close(); }
}


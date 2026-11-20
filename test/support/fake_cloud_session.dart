import 'package:ros_tester/cloud_session.dart';

class FakeCloudSession extends CloudSession {
  FakeCloudSession({this.signedIn = false}) : super(server: 'https://relay.example', vault: MemorySessionVault()) { email = 'owner@example.com'; }
  bool claimed = false;
  CloudUsage remoteUsage = const CloudUsage(1_000_000_000, 5_000_000_000, true);
  @override
  Future<CloudUsage> usage() async => remoteUsage;
  @override
  bool signedIn;
  @override
  Future<void> restore() async {}
  @override
  Future<void> signIn(String email, String password) async { signedIn = true; this.email = email; }
  @override
  Future<void> signUp(String email, String password) async {}
  @override
  Future<void> signOut() async { signedIn = false; }
  @override
  Future<List<CloudRobot>> robots() async => [const CloudRobot('r-existing', 'Warehouse robot', false),
    if (claimed) const CloudRobot('r-new', 'New robot', true), ...sharedWithMe];
  @override
  Future<void> claim(String code) async { claimed = true; claimedCode = code; }
  final sharedWithMe = <CloudRobot>[];
  final invites = <(String, String)>[]; // robot id, role
  final memberLists = <String, List<CloudMember>>{};
  final removed = <(String, String?)>[];
  @override
  Future<({String code, DateTime expires})> invite(CloudRobot robot, String role) async {
    invites.add((robot.id, role));
    return (code: 'K7QM-4XTD', expires: DateTime(2026, 11, 27));
  }
  @override
  Future<CloudRobot> join(String code) async {
    if (code.trim().toUpperCase() != 'JOIN-CODE') throw const CloudFailure('This invitation code is invalid or expired.');
    final robot = const CloudRobot('r-shared', 'Lab robot', true, role: 'viewer');
    sharedWithMe.add(robot);
    return robot;
  }
  @override
  Future<({List<CloudMember> members, int openInvites})> members(CloudRobot robot) async =>
      (members: memberLists[robot.id] ?? const <CloudMember>[], openInvites: 0);
  @override
  Future<void> removeMember(CloudRobot robot, [String? user]) async {
    removed.add((robot.id, user));
    if (user == null) sharedWithMe.removeWhere((r) => r.id == robot.id);
    memberLists[robot.id]?.removeWhere((m) => m.user == user);
  }
  String? claimedCode;
  /// Codes the fake knows, as the server would answer a preview.
  Map<String, ({String name, bool online})> pendingRobots = {};
  @override
  Future<({String name, bool online})> previewClaim(String code) async {
    final robot = pendingRobots[code.trim().toUpperCase()];
    if (robot == null) throw const CloudFailure('This registration code is invalid or expired.');
    return robot;
  }
  final resetRequests = <String>[];
  final newPasswords = <(String, String)>[];
  bool passwordChangeFails = false;
  String? deletedWith;
  @override
  Future<void> requestPasswordReset(String email) async { resetRequests.add(email); }
  @override
  Future<void> setNewPassword(String resetToken, String password) async {
    if (passwordChangeFails) throw const CloudFailure('Provider unavailable.');
    newPasswords.add((resetToken, password));
  }
  @override
  Future<bool> deleteAccount(String password) async { deletedWith = password; signedIn = false; return true; }
}

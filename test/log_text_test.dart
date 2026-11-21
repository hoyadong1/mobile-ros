import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/agent/audit_log.dart';
import 'package:ros_tester/agent/log_text.dart';
import 'package:ros_tester/l10n/generated/app_localizations.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_summary.dart';

void main() {
  final ko = lookupAppLocalizations(const Locale('ko'));
  final en = lookupAppLocalizations(const Locale('en'));

  test("the assistant's history reads in the app language; anything unknown stays as recorded", () {
    expect(logLineIn(AuditKind.instruction, 'Run routine "patrol" 3 times', ko), '루틴 "patrol" 3번 실행');
    expect(logLineIn(AuditKind.note, 'Routine "patrol": 1 steps.', ko), '루틴 "patrol": 1단계');
    expect(logLineIn(AuditKind.call, 'move(distance_m: 0.2, speed: slow)', ko), '앞뒤로 이동 · 0.2 m · 느림');
    expect(logLineIn(AuditKind.call, 'rotate(angle_deg: 90) (speed capped)', ko), '제자리 회전 · 90° (speed capped)');
    expect(logLineIn(AuditKind.result, 'Moved 0.21 m forward.', ko), '앞으로 0.21 m 이동했어요.');
    expect(logLineIn(AuditKind.result, 'Turned 89° left.', ko), '왼쪽으로 89° 돌았어요.');
    expect(logLineIn(AuditKind.result, 'Stopped.', ko), '정지했어요.');
    expect(logLineIn(AuditKind.result, 'Arrived at kitchen.', ko), 'kitchen에 도착했어요.');
    expect(logLineIn(AuditKind.result,
        'Stopped after 0.05 m of 0.2 m: the robot did not get there in time (blocked or slipping?).', ko),
        '0.2 m 중 0.05 m 가고 멈췄어요. 제시간에 도착하지 못했어요(막혔거나 미끄러졌을 수 있어요).');
    expect(logLineIn(AuditKind.result, 'Something new happened.', ko), 'Something new happened.');
    expect(logLineIn(AuditKind.instruction, '앞으로 가', ko), '앞으로 가', reason: 'what the person typed');
    expect(logLineIn(AuditKind.result, 'Moved 0.21 m forward.', en), 'Moved 0.21 m forward.');
  });

  test('the robot kind and its features read in the app language; the assistant keeps English', () {
    const s = RobotSummary(robotKind: RobotKind.turnsInPlace, rosVersion: RosVersion.ros2, features: [
      RobotFeature('lidar', 'LiDAR', ['/scan']),
      RobotFeature('camera', 'Camera', ['/image']),
    ]);
    expect(s.kind, 'Mobile robot (turns in place)');
    expect(s.kindIn(ko), '이동 로봇(제자리 회전)');
    expect(s.features[1].labelIn(ko), '카메라');
    expect(s.assistantCan(ko), contains('카메라로 보기'));
    expect(s.assistantCan(en), contains('look through the camera'));
  });
}

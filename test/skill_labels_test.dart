import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent/skill_labels.dart';
import 'package:ros_tester/l10n/generated/app_localizations.dart';

void main() {
  test('steps read in the app language; a learned tool keeps its own name', () {
    final ko = lookupAppLocalizations(const Locale('ko'));
    final en = lookupAppLocalizations(const Locale('en'));
    const step = SkillCall('move', {'distance_m': 0.2, 'speed': 'slow'});
    expect(describeCall(step, en), 'Drive forward or back · 0.2 m · Slow');
    expect(describeCall(step, ko), '앞뒤로 이동 · 0.2 m · 느림');
    expect(skillLabel('patrol_twice', ko).title, 'patrol_twice');
    const speed = SkillParam('speed', ParamType.string, 'd', required: false);
    expect(paramLabel(speed, ko), '속도(선택)');
    expect(paramLabel(const SkillParam('distance_m', ParamType.number, 'd'), en), 'Distance (m)');
  });
}

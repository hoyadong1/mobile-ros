# Deserializes the app's CDR output (test/fixtures/ros2_cdr_ours.json) with ROS 2 and compares it with
# the original message.  Run in a ROS 2 Humble shell from the repo root: python3 tool/dds_cdr_check.py
import importlib, json, re
from rclpy.serialization import deserialize_message

def cls(t):
    pkg, kind, name = t.split('/')
    mod = importlib.import_module(f'{pkg}.{kind}')
    if kind == 'action':
        for suffix, path in [('_SendGoal_Request', 'SendGoalService.Request'), ('_FeedbackMessage', 'FeedbackMessage')]:
            if name.endswith(suffix):
                obj = getattr(mod, name[:-len(suffix)]).Impl
                for p in path.split('.'): obj = getattr(obj, p)
                return obj
    if kind == 'srv':
        base, part = name.rsplit('_', 1)
        return getattr(getattr(mod, base), part)
    return getattr(mod, name)

bad = 0
for f in json.load(open('test/fixtures/ros2_cdr_ours.json')):
    c = cls(f['type'])
    original = deserialize_message(bytes.fromhex(f['original']), c)
    ours = deserialize_message(bytes.fromhex(f['ours']), c)
    # non-finite floats travel as null (as in rosbridge's JSON) and come back as nan
    same = re.sub(r'\binf\b', 'nan', repr(original)) == repr(ours)
    bad += not same
    print('ok  ' if same else 'DIFF', f['type'])
raise SystemExit(bad)

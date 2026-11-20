"""Fake ROS 2 (or ROS 1) robot speaking the rosbridge v2 protocol, for testing Mobile ROS without hardware.

Simulates rosbridge_websocket + rosapi + a differential-drive robot:
  - rosapi services: nodes, topics, services, node_details, topic_type
  - /map (OccupancyGrid), /odom, /tf (map->odom, odom->base_link), /tf_static
  - /camera/color/image_raw (sensor_msgs/Image, color quadrants to catch RGB/BGR swaps)
  - /chatter (std_msgs/String)
  - consumes /cmd_vel (moves the robot, 0.5 s watchdog) and /goal_pose (ROS 2) or /move_base/goal (ROS 1)
  - optional RTSP test stream (MediaMTX + ffmpeg) at rtsp://<host>:8554/test

Usage:  python scripts/fake_robot.py [--port 9091] [--ros 2|1] [--rtsp] [--map-yaw 30] [--image-encoding bgr8] [--image-pad 4]
Requires: pip install websockets
"""
import argparse
import asyncio
import base64
import json
import math
import os
import shutil
import socket
import subprocess
import threading
import time

from websockets.asyncio.server import serve

ARGS = None
CLIENTS = set()

TOPIC_TYPES = {
    '/map': 'nav_msgs/OccupancyGrid',
    '/odom': 'nav_msgs/Odometry',
    '/tf': 'tf2_msgs/TFMessage',
    '/tf_static': 'tf2_msgs/TFMessage',
    '/camera/color/image_raw': 'sensor_msgs/Image',
    '/chatter': 'std_msgs/String',
    '/cmd_vel': 'geometry_msgs/Twist',
    '/move_base/goal': 'move_base_msgs/MoveBaseActionGoal',
    '/rosout': 'rosgraph_msgs/Log',
}
NODES = {
    '/fake_robot': {'publishing': ['/odom', '/tf', '/camera/color/image_raw', '/chatter'],
                    'subscribing': ['/cmd_vel'], 'services': ['/fake_robot/get_loggers']},
    '/map_server': {'publishing': ['/map'], 'subscribing': [], 'services': ['/static_map']},
    '/move_base': {'publishing': [], 'subscribing': ['/move_base/goal', '/odom', '/map'],
                   'services': ['/move_base/make_plan']},
    '/rosapi': {'publishing': [], 'subscribing': [],
                'services': ['/rosapi/nodes', '/rosapi/topics', '/rosapi/services',
                             '/rosapi/node_details', '/rosapi/topic_type']},
    '/rosbridge_websocket': {'publishing': ['/rosout'], 'subscribing': [], 'services': []},
}

# --- map geometry -----------------------------------------------------------
MAP_W, MAP_H, MAP_RES = 200, 160, 0.05          # 10 m x 8 m
MAP_ORIGIN = (-5.0, -4.0)
MAP_TO_ODOM = (1.0, 0.5, 0.3)                   # x, y, yaw: non-identity on purpose


def log(tag, text):
    print(f'{time.strftime("%H:%M:%S")} [{tag}] {text}', flush=True)


def quat(yaw):
    return {'x': 0.0, 'y': 0.0, 'z': math.sin(yaw / 2), 'w': math.cos(yaw / 2)}


def compose(a, b):
    ax, ay, at = a
    bx, by, bt = b
    return (ax + bx * math.cos(at) - by * math.sin(at), ay + bx * math.sin(at) + by * math.cos(at), at + bt)


def inverse(a):
    x, y, t = a
    return (-x * math.cos(t) - y * math.sin(t), x * math.sin(t) - y * math.cos(t), -t)


def header(frame, seq=0):
    now = time.time()
    if ARGS.ros == 2:
        return {'stamp': {'sec': int(now), 'nanosec': int((now % 1) * 1e9)}, 'frame_id': frame}
    return {'seq': seq, 'stamp': {'secs': int(now), 'nsecs': int((now % 1) * 1e9)}, 'frame_id': frame}


def ros_type(name):
    """ROS 2 rosapi reports pkg/msg/Type; ROS 1 reports pkg/Type."""
    return name.replace('/', '/msg/', 1) if ARGS.ros == 2 and '/msg/' not in name else name


def same_type(a, b):
    return (a or '').replace('/msg/', '/') == (b or '').replace('/msg/', '/')


def configure_ros_version():
    if ARGS.ros == 2:   # Nav2 takes a PoseStamped on /goal_pose instead of the move_base action
        del TOPIC_TYPES['/move_base/goal']
        TOPIC_TYPES['/goal_pose'] = 'geometry_msgs/PoseStamped'
        TOPIC_TYPES['/rosout'] = 'rcl_interfaces/Log'
        NODES['/bt_navigator'] = NODES.pop('/move_base')
        NODES['/bt_navigator']['subscribing'] = ['/goal_pose', '/odom', '/map']
        NODES['/bt_navigator']['services'] = ['/bt_navigator/get_parameters']


def build_map():
    cells = [0] * (MAP_W * MAP_H)

    def fill(x0, y0, x1, y1, value):
        for y in range(max(0, y0), min(MAP_H, y1)):
            for x in range(max(0, x0), min(MAP_W, x1)):
                cells[y * MAP_W + x] = value

    fill(0, 0, MAP_W, 3, 100); fill(0, MAP_H - 3, MAP_W, MAP_H, 100)
    fill(0, 0, 3, MAP_H, 100); fill(MAP_W - 3, 0, MAP_W, MAP_H, 100)
    fill(60, 40, 75, 120, 100)                   # pillar left of centre
    fill(130, 20, 180, 35, 100)                  # shelf near the bottom-right (map +x, low y)
    fill(150, 110, 197, 157, -1)                 # unknown area in the top-right corner
    return cells


MAP_CELLS = build_map()


def map_origin_pose():
    return (MAP_ORIGIN[0], MAP_ORIGIN[1], math.radians(ARGS.map_yaw))


class Robot:
    def __init__(self):
        centre = compose(map_origin_pose(), (MAP_W * MAP_RES / 2, MAP_H * MAP_RES / 2, 0))
        self.pose = compose(inverse(MAP_TO_ODOM), (centre[0] + 1.0, centre[1], 0.0))   # odom frame
        self.v = self.w = 0.0
        self.last_cmd = 0.0
        self.manual = False
        self.goal = None                                                            # map frame (x, y)
        self.seq = 0

    def map_pose(self):
        return compose(MAP_TO_ODOM, self.pose)

    def step(self, dt):
        now = time.time()
        if self.manual and now - self.last_cmd > 0.5:
            if self.v or self.w:
                log('WATCHDOG', 'no /cmd_vel for 0.5 s -> robot stopped')
            self.v = self.w = 0.0
            self.manual = False
        if self.goal and not self.manual:
            mx, my, mt = self.map_pose()
            dx, dy = self.goal[0] - mx, self.goal[1] - my
            dist = math.hypot(dx, dy)
            if dist < 0.08:
                log('GOAL', f'reached map ({self.goal[0]:.2f}, {self.goal[1]:.2f})')
                self.goal = None
                self.v = self.w = 0.0
            else:
                err = math.atan2(math.sin(math.atan2(dy, dx) - mt), math.cos(math.atan2(dy, dx) - mt))
                self.w = max(-1.5, min(1.5, 2.5 * err))
                self.v = 0.0 if abs(err) > 0.6 else min(0.6, dist)
        x, y, t = self.pose
        self.pose = (x + self.v * math.cos(t) * dt, y + self.v * math.sin(t) * dt, t + self.w * dt)
        self.seq += 1


ROBOT = None


# --- message builders ---------------------------------------------------------
def msg_map():
    ox, oy, ot = map_origin_pose()
    return {'header': header('map'), 'info': {
        'map_load_time': header('map')['stamp'], 'resolution': MAP_RES, 'width': MAP_W, 'height': MAP_H,
        'origin': {'position': {'x': ox, 'y': oy, 'z': 0.0}, 'orientation': quat(ot)}}, 'data': MAP_CELLS}


def msg_odom():
    x, y, t = ROBOT.pose
    return {'header': header('odom', ROBOT.seq), 'child_frame_id': 'base_link',
            'pose': {'pose': {'position': {'x': x, 'y': y, 'z': 0.0}, 'orientation': quat(t)}, 'covariance': [0.0] * 36},
            'twist': {'twist': {'linear': {'x': ROBOT.v, 'y': 0.0, 'z': 0.0},
                                'angular': {'x': 0.0, 'y': 0.0, 'z': ROBOT.w}}, 'covariance': [0.0] * 36}}


def tf(parent, child, pose):
    return {'header': header(parent), 'child_frame_id': child, 'transform': {
        'translation': {'x': pose[0], 'y': pose[1], 'z': 0.0}, 'rotation': quat(pose[2])}}


def msg_tf():
    return {'transforms': [tf('map', 'odom', MAP_TO_ODOM), tf('odom', 'base_link', ROBOT.pose)]}


def msg_tf_static():
    return {'transforms': [tf('base_link', 'camera_link', (0.2, 0.0, 0.0))]}


def msg_image(frame):
    w, h, enc = 160, 120, ARGS.image_encoding
    ch = {'mono8': 1, 'rgba8': 4, 'bgra8': 4}.get(enc, 3)
    step = w * ch + ARGS.image_pad
    buf = bytearray(step * h)
    bar = (frame * 4) % w
    for y in range(h):
        for x in range(w):
            if abs(x - bar) < 3:
                rgb = (255, 255, 0)                                   # moving yellow bar
            elif y < h // 2:
                rgb = (255, 0, 0) if x < w // 2 else (0, 255, 0)      # top: RED | GREEN
            else:
                rgb = (0, 0, 255) if x < w // 2 else (255, 255, 255)  # bottom: BLUE | WHITE
            i = y * step + x * ch
            if ch == 1:
                buf[i] = (rgb[0] + rgb[1] + rgb[2]) // 3
            else:
                px = rgb[::-1] if enc.startswith('bgr') else rgb
                buf[i:i + 3] = bytes(px)
                if ch == 4:
                    buf[i + 3] = 255
    return {'header': header('camera_link', frame), 'height': h, 'width': w, 'encoding': enc,
            'is_bigendian': 0, 'step': step, 'data': base64.b64encode(bytes(buf)).decode()}


# --- rosbridge protocol -------------------------------------------------------
class Client:
    def __init__(self, ws):
        self.ws = ws
        self.subs = {}          # topic -> [throttle_s, last_sent]
        self.advertised = {}    # topic -> type
        self.peer = f'{ws.remote_address[0]}:{ws.remote_address[1]}'

    async def send(self, data):
        try:
            await self.ws.send(json.dumps(data))
        except Exception:
            pass

    async def status(self, level, text, op_id=None):
        log('STATUS->' + level.upper(), text)
        await self.send({'op': 'status', 'level': level, 'msg': text, **({'id': op_id} if op_id else {})})

    async def publish(self, topic, msg, force=False):
        sub = self.subs.get(topic)
        if not sub:
            return
        now = time.time()
        if not force and now - sub[1] < sub[0]:
            return
        sub[1] = now
        await self.send({'op': 'publish', 'topic': topic, 'msg': msg})


def rosapi(service, args):
    if service == '/rosapi/nodes':
        return {'nodes': sorted(NODES)}
    if service == '/rosapi/topics':
        topics = sorted(TOPIC_TYPES)
        return {'topics': topics, 'types': [ros_type(TOPIC_TYPES[t]) for t in topics]}
    if service == '/rosapi/services':
        return {'services': sorted({s for n in NODES.values() for s in n['services']})}
    if service == '/rosapi/node_details':
        node = NODES.get(args.get('node'))
        if node is None:
            raise KeyError(f"Unknown node {args.get('node')!r}")
        return node
    if service == '/rosapi/topic_type':
        return {'type': ros_type(TOPIC_TYPES.get(args.get('topic'), ''))}
    return None


def check_number(value, path):
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
        raise ValueError(f'{path} must be a finite number, got {value!r}')
    return float(value)


_last_cmd_log = [0.0, None]


def handle_cmd_vel(msg):
    v = check_number(msg['linear']['x'], 'linear.x')
    w = check_number(msg['angular']['z'], 'angular.z')
    ROBOT.v, ROBOT.w, ROBOT.last_cmd = v, w, time.time()
    ROBOT.manual = True
    if v or w:
        if ROBOT.goal:
            log('GOAL', 'manual /cmd_vel overrides the active goal -> goal cancelled')
            ROBOT.goal = None
        if time.time() - _last_cmd_log[0] > 0.5:
            log('CMD_VEL', f'linear.x={v:+.2f} m/s  angular.z={w:+.2f} rad/s')
            _last_cmd_log[0] = time.time()
    elif _last_cmd_log[1] != (0, 0):
        log('CMD_VEL', 'STOP (zero twist) received')
    _last_cmd_log[1] = (v, w) if (v or w) else (0, 0)


def handle_goal(msg):
    target = msg if ARGS.ros == 2 else msg['goal']['target_pose']
    stamp = target['header']['stamp']
    expected = {'sec', 'nanosec'} if ARGS.ros == 2 else {'secs', 'nsecs'}
    if set(stamp) != expected:
        raise ValueError(f'stamp fields {sorted(stamp)} do not match ROS {ARGS.ros} ({sorted(expected)})')
    frame = target['header']['frame_id']
    p = target['pose']['position']
    x, y = check_number(p['x'], 'position.x'), check_number(p['y'], 'position.y')
    q = target['pose']['orientation']
    if abs(math.sqrt(sum(check_number(q[k], k) ** 2 for k in 'xyzw')) - 1) > 1e-3:
        raise ValueError('orientation quaternion is not normalized')
    if frame.lstrip('/') != 'map':
        raise ValueError(f"goal frame_id is {frame!r}, expected 'map'")
    if ARGS.ros == 1 and not msg.get('goal_id', {}).get('id'):
        log('GOAL', 'warning: empty goal_id.id')
    ox, oy, ot = map_origin_pose()
    lx = (x - ox) * math.cos(-ot) - (y - oy) * math.sin(-ot)
    ly = (x - ox) * math.sin(-ot) + (y - oy) * math.cos(-ot)
    col, row = int(lx / MAP_RES), int(ly / MAP_RES)
    cell = MAP_CELLS[row * MAP_W + col] if 0 <= col < MAP_W and 0 <= row < MAP_H else None
    where = 'OUTSIDE map' if cell is None else {100: 'occupied', -1: 'unknown', 0: 'free'}[cell]
    log('GOAL', f'received map ({x:.2f}, {y:.2f}) -> grid cell (col {col}, row {row}) = {where}; driving there')
    ROBOT.goal = (x, y)
    ROBOT.manual = False


async def handle(ws):
    client = Client(ws)
    CLIENTS.add(client)
    log('CONNECT', f'{client.peer} connected ({len(CLIENTS)} client(s))')
    try:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                await client.status('error', f'Invalid JSON: {raw[:80]}')
                continue
            op, op_id, topic = data.get('op'), data.get('id'), data.get('topic')
            if op == 'advertise':
                client.advertised[topic] = data.get('type')
                expected = TOPIC_TYPES.get(topic)
                if expected and not same_type(data.get('type'), expected):
                    await client.status('error', f'advertise: {topic} already established with type {expected}', op_id)
                else:
                    log('ADVERTISE', f'{topic} [{data.get("type")}]')
            elif op == 'unadvertise':
                client.advertised.pop(topic, None)
                log('UNADVERTISE', topic)
            elif op == 'subscribe':
                client.subs[topic] = [max(0, data.get('throttle_rate', 0)) / 1000.0, 0.0]
                log('SUBSCRIBE', f'{topic} throttle={data.get("throttle_rate", 0)}ms')
                latched = {'/map': msg_map, '/tf_static': msg_tf_static}.get(topic)
                if latched:
                    await client.publish(topic, latched(), force=True)
            elif op == 'unsubscribe':
                client.subs.pop(topic, None)
                log('UNSUBSCRIBE', topic)
            elif op == 'publish':
                if topic not in client.advertised and topic not in TOPIC_TYPES:
                    await client.status('error', f'publish: Cannot infer topic type for topic {topic} '
                                                 f'as it is not yet advertised', op_id)
                    continue
                msg = data.get('msg', {})
                try:
                    if topic == '/cmd_vel':
                        handle_cmd_vel(msg)
                    elif topic in ('/move_base/goal', '/goal_pose'):
                        handle_goal(msg)
                    else:
                        log('PUBLISH', f'{topic} [{client.advertised.get(topic)}] {json.dumps(msg)[:300]}')
                    for other in list(CLIENTS):                       # echo to subscribers
                        await other.publish(topic, msg, force=True)
                except (KeyError, TypeError, ValueError) as e:
                    await client.status('error', f'publish: {topic}: malformed message ({e!r})', op_id)
            elif op == 'call_service':
                service = data.get('service')
                try:
                    values = rosapi(service, data.get('args') or {})
                    ok = values is not None
                    values = values if ok else 'Service does not exist'
                except Exception as e:
                    ok, values = False, str(e)
                log('SERVICE', f'{service} -> {"ok" if ok else "FAILED: " + values}')
                await client.send({'op': 'service_response', 'id': op_id, 'service': service,
                                   'values': values, 'result': ok})
            else:
                await client.status('error', f'Unknown operation {op!r}', op_id)
    except Exception as e:
        log('ERROR', f'{client.peer}: {e!r}')
    finally:
        CLIENTS.discard(client)
        log('DISCONNECT', f'{client.peer} disconnected ({len(CLIENTS)} client(s))')


async def sim_loop():
    frame, last, next_slow, next_cam = 0, time.time(), 0.0, 0.0
    while True:
        await asyncio.sleep(0.05)
        now = time.time()
        ROBOT.step(now - last)
        last = now
        for c in list(CLIENTS):
            await c.publish('/odom', msg_odom())
            await c.publish('/tf', msg_tf())
        if now >= next_cam:
            next_cam = now + 0.1
            frame += 1
            if any('/camera/color/image_raw' in c.subs for c in CLIENTS):
                image = msg_image(frame)
                for c in list(CLIENTS):
                    await c.publish('/camera/color/image_raw', image)
        if now >= next_slow:
            next_slow = now + 1.0
            for c in list(CLIENTS):
                await c.publish('/chatter', {'data': f'hello from fake robot {int(now)}'})


CHILDREN = []


def find_mediamtx():
    local = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.tools', 'mediamtx', 'mediamtx.exe')
    return ARGS.mediamtx or (local if os.path.exists(local) else shutil.which('mediamtx'))


def rtsp_loop():
    """MediaMTX serves RTSP on :8554; ffmpeg publishes a test pattern to it (ffmpeg alone cannot serve RTSP)."""
    ffmpeg, mediamtx = shutil.which('ffmpeg'), find_mediamtx()
    if not ffmpeg or not mediamtx:
        log('RTSP', f'disabled: ffmpeg={ffmpeg or "missing"} mediamtx={mediamtx or "missing (see scripts/README_fake_robot.md)"}')
        return
    env = dict(os.environ, MTX_RTMP='no', MTX_HLS='no', MTX_WEBRTC='no', MTX_SRT='no', MTX_LOGLEVEL='warn')
    server = subprocess.Popen([mediamtx], env=env, cwd=os.path.dirname(mediamtx))
    CHILDREN.append(server)
    time.sleep(1.0)
    cmd = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-re', '-f', 'lavfi',
           '-i', 'testsrc2=size=640x360:rate=15', '-c:v', 'libx264', '-preset', 'ultrafast',
           '-tune', 'zerolatency', '-pix_fmt', 'yuv420p', '-g', '15',
           '-f', 'rtsp', '-rtsp_transport', 'tcp', 'rtsp://127.0.0.1:8554/test']
    log('RTSP', 'streaming test pattern at rtsp://<host>:8554/test')
    while server.poll() is None:
        publisher = subprocess.Popen(cmd)
        CHILDREN.append(publisher)
        publisher.wait()
        CHILDREN.remove(publisher)
        time.sleep(1.0)
    log('RTSP', f'mediamtx exited with code {server.returncode}')


def stop_children():
    for child in CHILDREN:
        if child.poll() is None:
            child.terminate()


def lan_addresses():
    addrs = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except OSError:
        pass
    return sorted(a for a in addrs if not a.startswith('127.')) or ['127.0.0.1']


async def main():
    global ROBOT
    ROBOT = Robot()
    async with serve(handle, '0.0.0.0', ARGS.port, max_size=None):
        log('READY', f'rosbridge on port {ARGS.port}; connect the app to one of: {", ".join(lan_addresses())}')
        log('READY', f'imitating ROS {ARGS.ros}; navigation goals on '
                     f'{"/goal_pose (Nav2)" if ARGS.ros == 2 else "/move_base/goal (move_base)"}')
        log('READY', f'image encoding={ARGS.image_encoding} pad={ARGS.image_pad}; map yaw={ARGS.map_yaw} deg; '
                     f'map->odom={MAP_TO_ODOM}')
        log('READY', 'camera: top-left RED, top-right GREEN, bottom-left BLUE, bottom-right WHITE')
        if ARGS.rtsp:   # started after the event loop exists, so ffmpeg spawning can't race its setup
            threading.Thread(target=rtsp_loop, daemon=True).start()
        await sim_loop()


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', type=int, default=9090)
    p.add_argument('--ros', type=int, choices=[1, 2], default=2, help='ROS version to imitate (default 2)')
    p.add_argument('--rtsp', action='store_true', help='serve an ffmpeg test pattern at rtsp://<host>:8554/test')
    p.add_argument('--map-yaw', type=float, default=0.0, help='map origin rotation in degrees')
    p.add_argument('--image-encoding', default='rgb8', choices=['rgb8', 'bgr8', 'rgba8', 'bgra8', 'mono8'])
    p.add_argument('--image-pad', type=int, default=0, help='extra bytes per image row (tests step handling)')
    p.add_argument('--mediamtx', help='path to mediamtx.exe (default: .tools/mediamtx or PATH)')
    ARGS = p.parse_args()
    configure_ros_version()
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    finally:
        stop_children()

#!/usr/bin/env bash
# Several TurtleBot3s (namespaces robot1, robot2, ...) sharing one Gazebo Harmonic world, each with its
# own Nav2, plus rosbridge: the multi-robot test bed for Mobile ROS.
#   ROBOTS=2 (default): Nav2's unique_multi_tb3_simulation_launch.py, robot1 at (0, 0.5), robot2 at (0, -0.5).
#   ROBOTS=3 or 4: Nav2's cloned_multi_tb3_simulation_launch.py, adding robot3 at (-2, -0.5), robot4 at (-2, 0.5).
#   RMW_IMPLEMENTATION=rmw_zenoh_cpp: the whole fleet on Zenoh (a Zenoh router is started for it).
# Run inside the ros-jazzy WSL distro:  HEADLESS=1 [ROBOTS=3] bash scripts/ros2_jazzy_multi_sim.sh
# (sim_live_test.sh runs it with MULTI=1.)
set -eo pipefail

source /opt/ros/jazzy/setup.bash
export TURTLEBOT3_MODEL=waffle
PORT="${PORT:-9090}"
ROBOTS="${ROBOTS:-2}"
[[ "$ROBOTS" =~ ^[2-4]$ ]] || { echo "ERROR: ROBOTS must be 2, 3 or 4"; exit 1; }
names=(); for i in $(seq 1 "$ROBOTS"); do names+=("robot$i"); done
declare -A start_x=([robot1]=0.0 [robot2]=0.0 [robot3]=-2.0 [robot4]=-2.0)
declare -A start_y=([robot1]=0.5 [robot2]=-0.5 [robot3]=-0.5 [robot4]=0.5)

pids=()
cleanup() { echo "Stopping simulation..."; kill "${pids[@]}" 2>/dev/null || true; pkill -f "gz sim" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# On Zenoh the ros2 CLI daemon stalls, so the CLI checks below query the graph directly there.
NO_DAEMON=""
if [ "${RMW_IMPLEMENTATION:-}" = "rmw_zenoh_cpp" ]; then
  ros2 run rmw_zenoh_cpp rmw_zenohd &
  pids+=($!)
  sleep 2
  NO_DAEMON="--no-daemon"
else
  timeout 10 ros2 daemon stop >/dev/null 2>&1 || true
  timeout 10 ros2 daemon start >/dev/null 2>&1 || true
fi

if [ "$ROBOTS" = 2 ]; then
  ros2 launch nav2_bringup unique_multi_tb3_simulation_launch.py use_rviz:=False autostart:=True &
else
  poses=""
  for r in "${names[@]}"; do poses+="$r={x: ${start_x[$r]}, y: ${start_y[$r]}, yaw: 0.0}; "; done
  ros2 launch nav2_bringup cloned_multi_tb3_simulation_launch.py use_rviz:=False autostart:=True robots:="${poses%; }" &
fi
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" &
pids+=($!)

# The upstream launch starts one ros_gz_bridge per robot, and each publishes the same global /clock.
# Their messages arrive out of order, so Nav2 clears its TF buffer and aborts goals. Replace every
# bridge but robot1's with the same topic config minus /clock; robot1 keeps the shared clock.
for r in "${names[@]:1}"; do
  bridge_pid=""
  for i in $(seq 1 90); do
    bridge_pid="$(pgrep -f "^/opt/ros/jazzy/lib/ros_gz_bridge/parameter_bridge .*__ns:=/$r( |$)" | head -n1 || true)"
    [ -n "$bridge_pid" ] && break
    sleep 1
  done
  [ -n "$bridge_pid" ] || { echo "ERROR: $r bridge did not start"; exit 1; }
  kill "$bridge_pid"
  for i in $(seq 1 20); do
    kill -0 "$bridge_pid" 2>/dev/null || break
    sleep 0.2
  done
  ros2 run ros_gz_bridge parameter_bridge --ros-args -r __ns:=/$r \
    -p config_file:="$(dirname "$0")/dev-env/turtlebot3_bridge_no_clock.yaml" \
    -p expand_gz_topic_names:=true -p use_sim_time:=true &
  pids+=($!)
done

for robot in "${names[@]}"; do
  echo "Waiting for $robot (/$robot/odom publisher and AMCL)..."
  for i in $(seq 1 120); do
    odom_info="$(timeout 20 ros2 topic info /$robot/odom $NO_DAEMON 2>/dev/null || true)"
    nodes="$(timeout 20 ros2 node list $NO_DAEMON 2>/dev/null || true)"
    [[ "$odom_info" =~ Publisher\ count:\ [1-9] && "$nodes" == *"/$robot/amcl"* ]] && break
    [ "$i" = 120 ] && { echo "ERROR: $robot did not appear within 4 minutes"; exit 1; }
    sleep 2
  done
  for attempt in 1 2 3 4 5; do
    timeout 20 ros2 topic pub --times 3 --wait-matching-subscriptions 1 /$robot/initialpose \
      geometry_msgs/msg/PoseWithCovarianceStamped \
      "{header: {frame_id: map}, pose: {pose: {position: {x: ${start_x[$robot]}, y: ${start_y[$robot]}, z: 0.0}, orientation: {w: 1.0}},
        covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.07]}}" \
      >/dev/null 2>&1 || true
    pose="$(timeout 10 ros2 topic echo --once /$robot/amcl_pose geometry_msgs/msg/PoseWithCovarianceStamped 2>/dev/null || true)"
    [ -n "$pose" ] && break
    [ "$attempt" = 5 ] && { echo "ERROR: $robot AMCL did not accept the initial pose"; exit 1; }
    sleep 3
  done
done

echo
echo "=== Ready ==="
for r in "${names[@]}"; do echo "robot     : /$r at (${start_x[$r]}, ${start_y[$r]}), with Nav2"; done
echo "middleware: ${RMW_IMPLEMENTATION:-default DDS}"
echo "rosbridge : ws://$(hostname -I | awk '{print $1}'):$PORT"
echo "Press Ctrl+C to stop."
wait

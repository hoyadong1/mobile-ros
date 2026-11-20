#!/usr/bin/env bash
# ROS 2 Jazzy test robot for Mobile ROS: TurtleBot4 in Gazebo Harmonic (depot world) + Nav2 + rosbridge.
# Same as ros2_jazzy_sim.sh but with Nav2's tb4_simulation_launch.py: another robot model, its own
# camera and a different map, to check the app is not tied to the TurtleBot3.
# The Jazzy counterpart of ros2_sim.sh (Humble + Gazebo Classic), so the app can be checked on both.
# Run inside a WSL Ubuntu 24.04:   bash scripts/ros2_jazzy_tb4_sim.sh            (Gazebo GUI via WSLg)
#                                   HEADLESS=1 bash scripts/ros2_jazzy_tb4_sim.sh (no windows)
# Middleware: RMW_IMPLEMENTATION=rmw_zenoh_cpp runs the whole robot on Zenoh instead of DDS (a Zenoh
# router, `ros2 run rmw_zenoh_cpp rmw_zenohd`, is started for it).
# One-time install (needs sudo):
#   sudo apt install -y ros-jazzy-desktop ros-jazzy-navigation2 ros-jazzy-nav2-bringup \
#        ros-jazzy-nav2-minimal-tb3-sim ros-jazzy-ros-gz ros-jazzy-rosbridge-suite ros-jazzy-rmw-zenoh-cpp
set -eo pipefail

source /opt/ros/jazzy/setup.bash
timeout 10 ros2 daemon stop >/dev/null 2>&1 || true
export TURTLEBOT3_MODEL=waffle
PORT="${PORT:-9090}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for pkg in nav2_bringup nav2_minimal_tb3_sim ros_gz_sim ros_gz_bridge rosbridge_server rosapi; do
  ros2 pkg prefix "$pkg" >/dev/null 2>&1 || { echo "Missing ROS package: $pkg (see install line at the top)"; exit 1; }
done

pids=()
cleanup() { echo "Stopping simulation..."; kill "${pids[@]}" 2>/dev/null || true; pkill -f "gz sim" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# On Zenoh the ros2 CLI daemon stalls (it stops answering and the router keeps reporting it cannot push
# to it), so the CLI checks below query the graph directly there.
NO_DAEMON=""
if [ "${RMW_IMPLEMENTATION:-}" = "rmw_zenoh_cpp" ]; then
  ros2 run rmw_zenoh_cpp rmw_zenohd &
  pids+=($!)
  sleep 2
  NO_DAEMON="--no-daemon"
else
  timeout 10 ros2 daemon start >/dev/null 2>&1 || true
fi

headless=False; [ "${HEADLESS:-0}" = "1" ] && headless=True
# Upstream spawns at x = -8, outside the depot map (which starts at x = -7.14): Nav2 then cannot plan.
ros2 launch nav2_bringup tb4_simulation_launch.py headless:="$headless" x_pose:=-5.0 y_pose:=0.0 use_rviz:="$([ "$headless" = True ] && echo False || echo True)" &
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" &
pids+=($!)

echo "Waiting for the robot in Gazebo (/odom publisher) and AMCL..."
for i in $(seq 1 90); do
  odom_info="$(timeout 20 ros2 topic info /odom $NO_DAEMON 2>/dev/null || true)"
  nodes="$(timeout 20 ros2 node list $NO_DAEMON 2>/dev/null || true)"
  [[ "$odom_info" =~ Publisher\ count:\ [1-9] && "$nodes" == *"/amcl"* ]] && break
  [ "$i" = 90 ] && { echo "ERROR: robot did not appear in Gazebo within 3 minutes"; exit 1; }
  sleep 2
done
# The launch file spawns the robot at (-5.0, 0.0); give AMCL that pose so map->odom exists.
for attempt in 1 2 3 4 5; do
  timeout 20 ros2 topic pub --times 3 --wait-matching-subscriptions 1 /initialpose \
    geometry_msgs/msg/PoseWithCovarianceStamped \
    "{header: {frame_id: map}, pose: {pose: {position: {x: -5.0, y: 0.0, z: 0.0}, orientation: {w: 1.0}},
      covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.07]}}" \
    >/dev/null 2>&1 || true
  amcl_pose="$(timeout 10 ros2 topic echo --once /amcl_pose geometry_msgs/msg/PoseWithCovarianceStamped 2>/dev/null || true)"
  [ -n "$amcl_pose" ] && break
  [ "$attempt" = 5 ] && { echo "ERROR: AMCL did not accept the initial pose"; exit 1; }
  sleep 3
done


echo
echo "=== Ready ==="
echo "distro    : ROS 2 Jazzy (${RMW_IMPLEMENTATION:-default DDS})"
echo "rosbridge : ws://$(hostname -I | awk '{print $1}'):$PORT  (WSL mirrored networking: same as the Windows PC IP)"
echo "Press Ctrl+C to stop."
wait

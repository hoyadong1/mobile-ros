#!/usr/bin/env bash
# Real ROS 2 Humble test robot for Mobile ROS: TurtleBot3 (waffle) in Gazebo + Nav2 + rosbridge.
# Run inside WSL Ubuntu 22.04:   bash scripts/ros2_sim.sh            (Gazebo + RViz windows via WSLg)
#                                 HEADLESS=1 bash scripts/ros2_sim.sh (no windows, lighter)
#                                 SLAM=1 ... mapping mode: slam_toolbox builds /map as the robot drives
#                                 (no AMCL, no saved map), for the app's "Make a map" flow
# One-time install (needs sudo):
#   sudo apt update && sudo apt install -y ros-humble-navigation2 ros-humble-nav2-bringup \
#        ros-humble-turtlebot3-gazebo ros-humble-rosbridge-suite
set -eo pipefail

source /opt/ros/humble/setup.bash
# With WSL mirrored networking the ros2 CLI fails to auto-start its daemon, so `ros2 topic info` /
# `ros2 node list` below would hang; start it explicitly.
timeout 10 ros2 daemon stop >/dev/null 2>&1 || true
timeout 10 ros2 daemon start >/dev/null 2>&1 || true
# Gazebo's own setup adds /usr/share/gazebo-11/models (ground_plane, sun). Without it — and with the
# online database disabled below — the world has no floor and the robot falls forever.
source /usr/share/gazebo/setup.sh
export TURTLEBOT3_MODEL=waffle
export GAZEBO_MODEL_PATH="${GAZEBO_MODEL_PATH}:/opt/ros/humble/share/turtlebot3_gazebo/models"
# All needed models are installed locally; querying the online model database stalls world loading
# past spawn_entity's 30 s timeout, so the robot never appears (no /odom, no TF).
export GAZEBO_MODEL_DATABASE_URI=""
PORT="${PORT:-9090}"

for pkg in nav2_bringup turtlebot3_gazebo rosbridge_server rosapi; do
  ros2 pkg prefix "$pkg" >/dev/null 2>&1 || { echo "Missing ROS package: $pkg (see install line at the top)"; exit 1; }
done

pids=()
cleanup() { echo "Stopping simulation..."; kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

headless=False; [ "${HEADLESS:-0}" = "1" ] && headless=True
slam=False; [ "${SLAM:-0}" = "1" ] && slam=True
ros2 launch nav2_bringup tb3_simulation_launch.py headless:="$headless" slam:="$slam"   use_rviz:="$([ "$headless" = True ] && echo False || echo True)" &
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" &
pids+=($!)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# AMCL in Humble starts without a pose, so there is no map->odom transform (no robot on the app map,
# goals rejected) until one is given. The launch file spawns the robot at (-2.0, -0.5).
localizer=/amcl; [ "$slam" = True ] && localizer=/slam_toolbox
echo "Waiting for the robot in Gazebo (/odom publisher) and $localizer..."
for i in $(seq 1 90); do
  # Capture first: `ros2 ... | grep -q` breaks the pipe early, which pipefail reports as failure.
  odom_info="$(ros2 topic info /odom 2>/dev/null || true)"
  nodes="$(ros2 node list 2>/dev/null || true)"
  [[ "$odom_info" =~ Publisher\ count:\ [1-9] && "$nodes" == *"$localizer"* ]] && break
  [ "$i" = 90 ] && { echo "ERROR: robot did not appear in Gazebo within 3 minutes"; exit 1; }
  sleep 2
done
# A robot below the floor means the world loaded without ground_plane (model path problem).
z="$(timeout 10 ros2 topic echo --once /odom 2>/dev/null | awk '/position:/{p=1} p&&/z:/{print $2; exit}')"
if [ -n "$z" ] && awk -v z="$z" 'BEGIN{exit !(z < -0.5)}'; then
  echo "ERROR: robot is falling (odom z=$z); Gazebo could not load ground_plane"; exit 1
fi
# `pub --once` can fire before AMCL's subscription is discovered, so wait for a match, publish a few
# times, and confirm AMCL answers with /amcl_pose (which means map->odom is being broadcast).
# (Mapping mode has no AMCL: slam_toolbox starts the map at the robot.)
for attempt in 1 2 3 4 5; do
  [ "$slam" = True ] && break
  timeout 20 ros2 topic pub --times 3 --wait-matching-subscriptions 1 /initialpose \
    geometry_msgs/msg/PoseWithCovarianceStamped \
    "{header: {frame_id: map}, pose: {pose: {position: {x: -2.0, y: -0.5, z: 0.0}, orientation: {w: 1.0}},
      covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.07]}}" \
    >/dev/null 2>&1 || true
  amcl_pose="$(timeout 10 ros2 topic echo --once /amcl_pose 2>/dev/null || true)"
  [ -n "$amcl_pose" ] && break
  [ "$attempt" = 5 ] && { echo "ERROR: AMCL did not accept the initial pose"; exit 1; }
  sleep 3
done
# Nav2's waffle model has only a depth camera; add a fixed rendered camera aimed at the robot's start
# pose (-2.0, -0.5) from ~1.6 m, so driving from the app is clearly visible (topic /demo_camera/image_raw).
ros2 run gazebo_ros spawn_entity.py -entity demo_camera -file "$SCRIPT_DIR/sim_camera.sdf" \
  -x -0.9 -y -1.7 -z 1.3 -R 0 -P 0.67 -Y 2.33 >/dev/null 2>&1 || echo "WARNING: demo camera not spawned"
# Real robots usually offer a JPEG /compressed image (image_transport); raw RGB over rosbridge is ~9 MB/s
# at 10 fps, too much for a phone to keep up with. Publish the same for the demo camera.
python3 "$SCRIPT_DIR/compress_republisher.py" /demo_camera/image_raw >/dev/null 2>&1 &
pids+=($!)
python3 "$SCRIPT_DIR/follow_camera.py" &
pids+=($!)
echo
echo "=== Ready ==="
echo "rosbridge : ws://$(hostname -I | awk '{print $1}'):$PORT  (WSL mirrored networking: same as the Windows PC IP)"
echo "camera    : /demo_camera/image_raw (+ /compressed JPEG, which the app picks)"
echo "goal      : the app should report 'ROS 2 Nav2 (/goal_pose)'"
echo "Press Ctrl+C to stop."
wait

#!/usr/bin/env bash
# Namespaced variant of ros2_sim.sh for compatibility checks: the same TurtleBot3 + Nav2 world, but the
# navigation stack (and the robot's topics) live under NS (default robot1), e.g. /robot1/map,
# /robot1/odom, /robot1/navigate_to_pose, /robot1/tf. Run inside WSL:  bash scripts/ros2_ns_sim.sh
set -eo pipefail
source /opt/ros/humble/setup.bash
# With WSL mirrored networking the ros2 CLI fails to auto-start its daemon, so `ros2 topic info` /
# `ros2 node list` below would hang; start it explicitly.
ros2 daemon stop >/dev/null 2>&1; ros2 daemon start >/dev/null 2>&1 || true
source /usr/share/gazebo/setup.sh
export TURTLEBOT3_MODEL=waffle
export GAZEBO_MODEL_PATH="${GAZEBO_MODEL_PATH}:/opt/ros/humble/share/turtlebot3_gazebo/models"
export GAZEBO_MODEL_DATABASE_URI=""
PORT="${PORT:-9090}"
NS="${NS:-robot1}"

pids=()
cleanup() { echo "Stopping simulation..."; kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

ros2 launch nav2_bringup tb3_simulation_launch.py headless:=True use_rviz:=False \
  namespace:="$NS" use_namespace:=True &
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" &
pids+=($!)

echo "Waiting for the robot and AMCL under /$NS..."
for i in $(seq 1 90); do
  nodes="$(ros2 node list 2>/dev/null || true)"
  [[ "$nodes" == *"/$NS/amcl"* ]] && break
  [ "$i" = 90 ] && { echo "ERROR: /$NS/amcl did not start"; exit 1; }
  sleep 2
done
for attempt in 1 2 3 4 5; do
  timeout 20 ros2 topic pub --times 3 --wait-matching-subscriptions 1 "/$NS/initialpose" \
    geometry_msgs/msg/PoseWithCovarianceStamped \
    "{header: {frame_id: map}, pose: {pose: {position: {x: -2.0, y: -0.5, z: 0.0}, orientation: {w: 1.0}},
      covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.07]}}" \
    >/dev/null 2>&1 || true
  [ -n "$(timeout 10 ros2 topic echo --once "/$NS/amcl_pose" 2>/dev/null || true)" ] && break
  [ "$attempt" = 5 ] && echo "WARNING: AMCL did not answer the initial pose"
  sleep 3
done
echo "=== Ready (namespace /$NS) ==="
ros2 topic list | grep -E "map|odom|scan|tf|plan|cmd_vel|initialpose|goal_pose" | sort
wait

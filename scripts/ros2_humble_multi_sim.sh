#!/usr/bin/env bash
# Two TurtleBot3s (namespaces robot1, robot2) sharing one Gazebo Classic world, each with its own Nav2,
# plus rosbridge: the multi-robot test bed on ROS 2 Humble. Nav2's unique_multi_tb3_simulation_launch.py
# spawns robot1 at (0, 0.5) and robot2 at (0, -0.5). Gazebo Classic has one /clock, so unlike the Jazzy
# script nothing needs replacing.
# Run inside a Humble WSL distro:  HEADLESS=1 bash scripts/ros2_humble_multi_sim.sh
# (sim_live_test.sh runs it with MULTI=1 DISTRO=humble.)
set -eo pipefail

source /opt/ros/humble/setup.bash
timeout 10 ros2 daemon stop >/dev/null 2>&1 || true
timeout 10 ros2 daemon start >/dev/null 2>&1 || true
# As in ros2_sim.sh: Gazebo's local models (ground, sun), and no online model database, which stalls
# world loading past spawn_entity's 30 s timeout so the robots never appear.
source /usr/share/gazebo/setup.sh
export TURTLEBOT3_MODEL=waffle
export GAZEBO_MODEL_PATH="${GAZEBO_MODEL_PATH:-}:/opt/ros/humble/share/turtlebot3_gazebo/models"
export GAZEBO_MODEL_DATABASE_URI=""
PORT="${PORT:-9090}"

pids=()
cleanup() { echo "Stopping simulation..."; kill "${pids[@]}" 2>/dev/null || true; pkill -f gzserver 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

ros2 launch nav2_bringup unique_multi_tb3_simulation_launch.py use_rviz:=False autostart:=True simulator:=gzserver &
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" &
pids+=($!)

declare -A start_y=([robot1]=0.5 [robot2]=-0.5)
for robot in robot1 robot2; do
  echo "Waiting for $robot (/$robot/odom publisher and AMCL)..."
  for i in $(seq 1 120); do
    odom_info="$(timeout 20 ros2 topic info /$robot/odom 2>/dev/null || true)"
    nodes="$(timeout 20 ros2 node list 2>/dev/null || true)"
    [[ "$odom_info" =~ Publisher\ count:\ [1-9] && "$nodes" == *"/$robot/amcl"* ]] && break
    [ "$i" = 120 ] && { echo "ERROR: $robot did not appear within 4 minutes"; exit 1; }
    sleep 2
  done
  for attempt in 1 2 3 4 5; do
    timeout 20 ros2 topic pub --times 3 --wait-matching-subscriptions 1 /$robot/initialpose \
      geometry_msgs/msg/PoseWithCovarianceStamped \
      "{header: {frame_id: map}, pose: {pose: {position: {x: 0.0, y: ${start_y[$robot]}, z: 0.0}, orientation: {w: 1.0}},
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
echo "robots    : /robot1 at (0, 0.5), /robot2 at (0, -0.5), each with Nav2"
echo "rosbridge : ws://$(hostname -I | awk '{print $1}'):$PORT"
echo "Press Ctrl+C to stop."
wait

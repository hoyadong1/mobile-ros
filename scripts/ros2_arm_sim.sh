#!/usr/bin/env bash
# Real ros2_control arm for testing the app's arm controls: TurtleBot3 Waffle Pi + OpenMANIPULATOR-X in
# Gazebo (arm_controller = JointTrajectoryController, gripper_controller = GripperActionController) +
# rosbridge, inside WSL Ubuntu 22.04. Headless (gzserver only).
#
# One-time setup (sudo):
#   sudo apt install -y ros-humble-turtlebot3-manipulation-gazebo ros-humble-gazebo-ros2-control
#
# Run:  bash scripts/ros2_arm_sim.sh      (rosbridge on port 9090 — run one simulation at a time)
set -eo pipefail
source /opt/ros/humble/setup.bash
# With WSL mirrored networking the ros2 CLI fails to auto-start its daemon, so `ros2 topic info` /
# `ros2 node list` below would hang; start it explicitly.
ros2 daemon stop >/dev/null 2>&1; ros2 daemon start >/dev/null 2>&1 || true
source /usr/share/gazebo/setup.sh            # ground_plane, sun (see ros2_sim.sh)
export GAZEBO_MODEL_DATABASE_URI=""          # never stall on the online model database
export GAZEBO_MODEL_PATH="${GAZEBO_MODEL_PATH}:/opt/ros/humble/share/turtlebot3_gazebo/models"
PORT="${PORT:-9090}"

for pkg in turtlebot3_manipulation_gazebo gazebo_ros2_control rosbridge_server; do
  ros2 pkg prefix "$pkg" >/dev/null 2>&1 || { echo "Missing ROS package: $pkg (see setup line at the top)"; exit 1; }
done

pids=()
cleanup() { echo "Stopping arm simulation..."; kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

WORLD=/opt/ros/humble/share/turtlebot3_gazebo/worlds/empty_world.world
# robot_state_publisher + controller spawners (they wait for Gazebo's controller_manager)
ros2 launch turtlebot3_manipulation_gazebo base.launch.py start_rviz:=false use_sim:=true > /tmp/arm_base.log 2>&1 &
pids+=($!)
ros2 launch gazebo_ros gzserver.launch.py world:="$WORLD" verbose:=false > /tmp/arm_gzserver.log 2>&1 &
pids+=($!)
ros2 run gazebo_ros spawn_entity.py -topic robot_description -entity turtlebot3_manipulation_system \
  -x 0 -y 0 -z 0.01 > /tmp/arm_spawn.log 2>&1 &
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" > /tmp/rosbridge_arm.log 2>&1 &
pids+=($!)

echo "Waiting for arm_controller and joint_states..."
for i in $(seq 1 90); do
  traj="$(ros2 topic info /arm_controller/joint_trajectory 2>/dev/null || true)"
  states="$(ros2 topic info /joint_states 2>/dev/null || true)"
  [[ "$traj" =~ Subscription\ count:\ [1-9] && "$states" =~ Publisher\ count:\ [1-9] ]] && break
  [ "$i" = 90 ] && { echo "ERROR: controllers did not come up (see /tmp/arm_base.log, /tmp/arm_gzserver.log)"; exit 1; }
  sleep 2
done
# The gripper controller's spawner often finishes a few seconds after the arm's.
for i in $(seq 1 10); do
  actions="$(ros2 action list 2>/dev/null || true)"
  [[ "$actions" == *"/gripper_controller/gripper_cmd"* ]] && break
  [ "$i" = 10 ] && echo "WARNING: gripper action server not found"
  sleep 2
done
echo
echo "=== Ready ==="
echo "rosbridge : port $PORT   (app: Windows PC IP; WSL mirrored networking)"
echo "robot     : OpenMANIPULATOR-X on /arm_controller/joint_trajectory, gripper /gripper_controller/gripper_cmd"
echo "Press Ctrl+C to stop."
wait

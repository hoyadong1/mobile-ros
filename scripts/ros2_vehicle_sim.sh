#!/usr/bin/env bash
# Omnidirectional or car-like vehicle in Gazebo (headless) + rosbridge, for testing the app's
# holonomic and Ackermann controllers. Uses the gazebo_plugins demo worlds (no extra install):
#   omni : box with gazebo_ros_planar_move (Twist x, y, yaw on /demo/cmd_demo)
#   car  : Prius with gazebo_ros_ackermann_drive; scripts/vehicle_bridge.py turns the app's
#          AckermannDriveStamped on /ackermann_cmd into the plugin's Twist
# Both publish odometry, relayed to /odom.
#
# Run:  bash scripts/ros2_vehicle_sim.sh omni|car      (rosbridge on port 9090 — one simulation at a time)
set -eo pipefail
VEHICLE="${1:-omni}"
source /opt/ros/humble/setup.bash
# With WSL mirrored networking the ros2 CLI fails to auto-start its daemon, so `ros2 topic info` /
# `ros2 node list` below would hang; start it explicitly.
ros2 daemon stop >/dev/null 2>&1; ros2 daemon start >/dev/null 2>&1 || true
source /usr/share/gazebo/setup.sh
export GAZEBO_MODEL_DATABASE_URI=""
PORT="${PORT:-9090}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORLDS=/opt/ros/humble/share/gazebo_plugins/worlds
case "$VEHICLE" in
  omni) WORLD="$WORLDS/gazebo_ros_planar_move_demo.world"; MODE=relay ;;
  car)  WORLD="$WORLDS/gazebo_ros_ackermann_drive_demo.world"; MODE=ackermann ;;
  *) echo "usage: $0 omni|car"; exit 1 ;;
esac

pids=()
cleanup() { echo "Stopping vehicle simulation..."; kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

ros2 launch gazebo_ros gzserver.launch.py world:="$WORLD" verbose:=false > /tmp/vehicle_gzserver.log 2>&1 &
pids+=($!)
python3 "$DIR/vehicle_bridge.py" --mode "$MODE" > /tmp/vehicle_bridge.log 2>&1 &
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" > /tmp/rosbridge_vehicle.log 2>&1 &
pids+=($!)

echo "Waiting for the $VEHICLE vehicle..."
for i in $(seq 1 60); do
  odom="$(ros2 topic info /demo/odom_demo 2>/dev/null || true)"
  [[ "$odom" =~ Publisher\ count:\ [1-9] ]] && break
  [ "$i" = 60 ] && { echo "ERROR: vehicle did not appear (see /tmp/vehicle_gzserver.log)"; exit 1; }
  sleep 2
done
echo
echo "=== Ready ==="
echo "rosbridge : port $PORT"
if [ "$VEHICLE" = omni ]; then
  echo "vehicle   : omnidirectional box, Twist on /demo/cmd_demo (pick 'Omnidirectional' in the app)"
else
  echo "vehicle   : Prius, AckermannDriveStamped on /ackermann_cmd (the app should suggest 'Car-like')"
fi
echo "Press Ctrl+C to stop."
wait

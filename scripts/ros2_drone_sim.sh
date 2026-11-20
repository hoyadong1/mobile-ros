#!/usr/bin/env bash
# Real flight stack for testing the app's drone controls without hardware:
# PX4 SITL with its built-in SIH physics (no Gazebo) + MAVROS + rosbridge, inside WSL Ubuntu 22.04.
#
# One-time setup:
#   sudo apt install -y ros-humble-mavros ros-humble-mavros-extras
#   sudo /opt/ros/humble/lib/mavros/install_geographiclib_datasets.sh
#   PX4 v1.15.2 built at ~/PX4-Autopilot (build/px4_sitl_default/bin/px4); see scripts/README_fake_robot.md
#
# Run:  bash scripts/ros2_drone_sim.sh        (rosbridge on port 9090, like ros2_sim.sh — run one at a time)
set -eo pipefail
source /opt/ros/humble/setup.bash
# With WSL mirrored networking the ros2 CLI fails to auto-start its daemon, so `ros2 topic info` /
# `ros2 node list` below would hang; start it explicitly.
ros2 daemon stop >/dev/null 2>&1; ros2 daemon start >/dev/null 2>&1 || true
PX4_DIR="${PX4_DIR:-$HOME/PX4-Autopilot}"
PX4_BIN="$PX4_DIR/build/px4_sitl_default/bin/px4"
PORT="${PORT:-9090}"

[ -x "$PX4_BIN" ] || { echo "PX4 SITL not built at $PX4_BIN"; exit 1; }
# MAVROS aborts without the EGM96 geoid. Without sudo it can live in the user's data directory:
#   ~/.local/share/GeographicLib/geoids/egm96-5.pgm  (from geographiclib geoids-distrib/egm96-5.tar.bz2)
if [ ! -r /usr/share/GeographicLib/geoids/egm96-5.pgm ]; then
  export GEOGRAPHICLIB_GEOID_PATH="$HOME/.local/share/GeographicLib/geoids"
  [ -r "$GEOGRAPHICLIB_GEOID_PATH/egm96-5.pgm" ] || {
    echo "Geoid dataset missing: sudo /opt/ros/humble/lib/mavros/install_geographiclib_datasets.sh"; exit 1; }
fi
ros2 pkg prefix mavros >/dev/null 2>&1 || { echo "MAVROS missing: sudo apt install -y ros-humble-mavros ros-humble-mavros-extras"; exit 1; }

pids=()
cleanup() { echo "Stopping drone simulation..."; kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM

ROOTFS="$(mktemp -d /tmp/px4_rootfs.XXXX)"
( cd "$ROOTFS" && PX4_SIM_MODEL=sihsim_quadx PX4_SYS_AUTOSTART=10040 HEADLESS=1 \
    "$PX4_BIN" -d "$PX4_DIR/build/px4_sitl_default/etc" -w "$ROOTFS" > /tmp/px4_sitl.log 2>&1 ) &
pids+=($!)
echo "Waiting for PX4..."
for i in $(seq 1 60); do grep -q "Ready for takeoff" /tmp/px4_sitl.log 2>/dev/null && break; sleep 1; done
grep -q "Ready for takeoff" /tmp/px4_sitl.log || { echo "ERROR: PX4 did not start (see /tmp/px4_sitl.log)"; exit 1; }

# PX4's onboard MAVLink link listens on 14580 and sends to 14540.
ros2 launch mavros px4.launch fcu_url:=udp://:14540@127.0.0.1:14580 > /tmp/mavros.log 2>&1 &
pids+=($!)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:="$PORT" > /tmp/rosbridge_drone.log 2>&1 &
pids+=($!)

echo "Waiting for MAVROS to connect to PX4..."
for i in $(seq 1 60); do
  state="$(timeout 5 ros2 topic echo --once /mavros/state 2>/dev/null || true)"
  [[ "$state" == *"connected: true"* ]] && break
  [ "$i" = 60 ] && { echo "ERROR: MAVROS never connected (see /tmp/mavros.log)"; exit 1; }
  sleep 1
done
# Right after boot the EKF is still converging ("Preflight Fail: Yaw estimate error ..."); taking off
# then gives a drifting altitude reference. Wait until no new preflight failure for 10 s.
echo "Waiting for the estimator to settle..."
for i in $(seq 1 90); do
  last_fail="$(grep -c 'Preflight Fail' /tmp/px4_sitl.log || true)"
  sleep 10
  [ "$(grep -c 'Preflight Fail' /tmp/px4_sitl.log || true)" = "$last_fail" ] && break
done
echo
echo "=== Ready ==="
echo "rosbridge : port $PORT   (app: Windows PC IP; WSL mirrored networking)"
echo "vehicle   : PX4 SIH quadrotor, MAVROS on /mavros; the app should suggest 'Drone'"
echo "Press Ctrl+C to stop."
wait

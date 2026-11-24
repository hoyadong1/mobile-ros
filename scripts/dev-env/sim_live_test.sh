#!/usr/bin/env bash
# Restarts the TurtleBot3 + Nav2 simulation from a fresh state in a ROS WSL distro, waits until it is
# ready, then runs one of the app's live end-to-end tests against it (rosbridge on localhost:9090).
# The robot is not reset between runs otherwise, and a second run can start it next to a pillar where
# Nav2 cannot plan, so always go through this script. Run from Git Bash on Windows:
#   bash scripts/dev-env/sim_live_test.sh [test file]      (default tool/live_robot_test.dart)
#   DISTRO=jazzy        ros-jazzy distro (Gazebo Harmonic) instead of ros-humble (Gazebo Classic)
#   DISTRO=lyrical      ros-lyrical distro (ROS 2 Lyrical Luth, Ubuntu 26.04; create_ros_wsl.sh lyrical)
#   RMW=rmw_zenoh_cpp   Jazzy robot on Zenoh (add DEFINES="--dart-define=VIA=zenoh" to connect the app over Zenoh too)
#   FLUTTER=<path>      Flutter executable if `flutter` is not on PATH
#   DEFINES="..."       extra flutter test flags, e.g. DEFINES="--dart-define=PROXY_TOKEN=secret"
#   MULTI=1             two TurtleBot3s in namespaces robot1/robot2 (Jazzy: ros2_jazzy_multi_sim.sh, Humble: ros2_humble_multi_sim.sh)
#   ROBOTS=3            with MULTI=1 on Jazzy: that many TurtleBot3s, 2 to 4 (robot1..robot4)
#   READY_S=480         how long to wait for the simulation to be ready (default 300 s; 4 robots on Zenoh need more)
#   SIM_SCRIPT="..."    another simulation script and its arguments, e.g. "scripts/ros2_vehicle_sim.sh car" (DISTRO=humble)
#   Several test files may be given: they run one after another on the same simulation (only for tests
#   that leave the robot where it was, or whose order you chose with that in mind).
#   LOGS=<dir>          where sim.log and live-test.log go (default: build/sim-logs)
#   WSL_DISTRO=<name>   installed WSL distro override (e.g. Ubuntu-22.04 with DISTRO=humble).
#                      This distro is restarted too; all its existing processes will stop.
# The simulation keeps running afterwards; stop it with:  wsl --terminate ros-humble   (or ros-jazzy)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST="${1:-tool/live_robot_test.dart}"
FLUTTER="${FLUTTER:-flutter}"
LOGS="${LOGS:-$REPO/build/sim-logs}"
mkdir -p "$LOGS"
# Git Bash path (/c/Users/...) -> WSL path (/mnt/c/Users/...)
WSL_REPO="$(echo "$REPO" | sed -E 's#^/([a-zA-Z])/#/mnt/\L\1/#')"

DISTRO="${DISTRO:-humble}"
case "$DISTRO" in
  humble) WSL=ros-humble; SIM=scripts/ros2_sim.sh ;;
  jazzy)  WSL=ros-jazzy;  SIM=scripts/ros2_jazzy_sim.sh ;;
  lyrical) WSL=ros-lyrical; SIM=scripts/ros2_jazzy_sim.sh ;;
  *) echo "DISTRO must be humble, jazzy or lyrical"; exit 2 ;;
esac
WSL="${WSL_DISTRO:-$WSL}"
# Fail immediately when the selected distro is absent, rather than waiting five minutes for Ready.
installed="$(wsl.exe --list --quiet 2>/dev/null | tr -d '\000\r')"
if ! printf '%s\n' "$installed" | grep -Fqx "$WSL"; then
  echo "ERROR: WSL distro '$WSL' is not installed. Set WSL_DISTRO to an installed ROS distro."
  exit 2
fi
# MULTI=1: two robots (robot1, robot2) instead of one
if [ "${MULTI:-0}" = "1" ]; then
  [ "$DISTRO" = "jazzy" ] && SIM=scripts/ros2_jazzy_multi_sim.sh || SIM=scripts/ros2_humble_multi_sim.sh
fi
# SIM_SCRIPT="scripts/ros2_vehicle_sim.sh car": another robot's simulation (with its arguments) instead
[ -n "${SIM_SCRIPT:-}" ] && SIM="$SIM_SCRIPT"
ENVS="HEADLESS=1"
[ "$DISTRO" = lyrical ] && ENVS="$ENVS ROS_DISTRO_NAME=lyrical"
[ -n "${RMW:-}" ] && ENVS="$ENVS RMW_IMPLEMENTATION=$RMW"
[ -n "${ROBOTS:-}" ] && ENVS="$ENVS ROBOTS=$ROBOTS"

# Only one simulation at a time: both distros share the network and ROS domain 0.
wsl.exe --terminate ros-humble >/dev/null 2>&1
wsl.exe --terminate ros-jazzy >/dev/null 2>&1
wsl.exe --terminate ros-lyrical >/dev/null 2>&1
if [ "$WSL" != ros-humble ] && [ "$WSL" != ros-jazzy ]; then
  wsl.exe --terminate "$WSL" >/dev/null 2>&1
fi
MSYS_NO_PATHCONV=1 wsl.exe -d "$WSL" -- bash -lc "cd '$WSL_REPO' && $ENVS bash $SIM" > "$LOGS/sim.log" 2>&1 &

for _ in $(seq 1 $(( ${READY_S:-300} / 2 ))); do
  grep -q -E '^=== Ready ===' "$LOGS/sim.log" && break
  if grep -q -E '^ERROR:|Missing ROS package' "$LOGS/sim.log"; then
    grep -E '^ERROR:|Missing ROS package' "$LOGS/sim.log"; exit 1
  fi
  sleep 2
done
grep -q -E '^=== Ready ===' "$LOGS/sim.log" || { echo "simulation did not become ready in ${READY_S:-300} s (see $LOGS/sim.log)"; exit 1; }
echo "simulation ready ($DISTRO${RMW:+, $RMW})"

status=0
: > "$LOGS/live-test.log"
for T in "$TEST" "${@:2}"; do
  [ $# -gt 1 ] && echo "--- $T"
  # shellcheck disable=SC2086 -- DEFINES is a list of flags
  (cd "$REPO" && "$FLUTTER" test "$T" --dart-define=ROBOT_HOST=127.0.0.1 --dart-define=ROBOT_PORT=9090 --dart-define=WSL_DISTRO="$WSL" --dart-define=ROS_DISTRO="$DISTRO" \
    ${DEFINES:-}) > "$LOGS/one-test.log" 2>&1 || status=1
  cat "$LOGS/one-test.log" >> "$LOGS/live-test.log"
  grep -E 'camera frame|drove|STOP|result:|cancelled|move:|rotate:|stop word:|navigate_to:|^>|^  |All tests|Some tests' \
    "$LOGS/one-test.log"
done
exit $status

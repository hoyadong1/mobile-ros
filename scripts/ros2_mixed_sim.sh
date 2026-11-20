#!/usr/bin/env bash
# Two different kinds of robot on one network (Humble): a TurtleBot3 with Nav2 in Gazebo under /robot1
# (scripts/ros2_ns_sim.sh) and a fixed arm under /arm1 (scripts/mock_arm.py, no base). For checking that
# the app tells them apart: different summaries, different AI skills, no cross-talk.
#   DISTRO=humble SIM_SCRIPT=scripts/ros2_mixed_sim.sh bash scripts/dev-env/sim_live_test.sh tool/live_mixed_test.dart
set -eo pipefail
source /opt/ros/humble/setup.bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$DIR/mock_arm.py" --namespace /arm1 --no-base > /tmp/mock_arm.log 2>&1 &
ARM_PID=$!
trap 'kill $ARM_PID 2>/dev/null || true' EXIT INT TERM
# The namespaced simulation announces "=== Ready (namespace /robot1) ==="; the test runner waits for "=== Ready ===".
NS=robot1 bash "$DIR/ros2_ns_sim.sh" | sed -u 's/^=== Ready.*/=== Ready ===/'

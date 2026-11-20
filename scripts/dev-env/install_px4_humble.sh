#!/usr/bin/env bash
# One-time setup for scripts/ros2_drone_sim.sh in the ros-humble WSL distro: MAVROS, its geoid data and
# PX4 v1.15.2 SITL (built at ~/PX4-Autopilot). Takes 20-40 minutes. Run inside the distro:
#   bash scripts/dev-env/install_px4_humble.sh
set -eo pipefail
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ros-humble-mavros ros-humble-mavros-extras
sudo /opt/ros/humble/lib/mavros/install_geographiclib_datasets.sh
cd ~
[ -d PX4-Autopilot ] || git clone --quiet --branch v1.15.2 --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/PX4/PX4-Autopilot.git
cd PX4-Autopilot
bash ./Tools/setup/ubuntu.sh --no-nuttx --no-sim-tools
# The shallow clone has no NuttX tags, and the version header script needs one (only the version string
# uses it; SITL does not run NuttX).
git -C platforms/nuttx/NuttX/nuttx tag -l 'nuttx-*' | grep -q . || git -C platforms/nuttx/NuttX/nuttx tag nuttx-10.3.0
make px4_sitl_default
ls -la build/px4_sitl_default/bin/px4
echo "PX4 SETUP DONE"

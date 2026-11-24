#!/usr/bin/env bash
# Installs ROS 2 Lyrical Luth + Nav2 + Gazebo (Harmonic, via ros-gz) + TurtleBot3 sim + rosbridge + rmw_zenoh
# into the `ros-lyrical` WSL distro (Ubuntu 26.04). Everything lands inside that distro, so
# `wsl --unregister ros-lyrical` removes all of it. Run from Git Bash:
#   MSYS_NO_PATHCONV=1 wsl -d ros-lyrical -- bash /mnt/c/<path to repo>/scripts/dev-env/install_ros_lyrical.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y locales software-properties-common curl gnupg lsb-release
sudo locale-gen en_US en_US.UTF-8
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
sudo add-apt-repository -y universe

sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo "$UBUNTU_CODENAME") main" \
  | sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  ros-lyrical-desktop \
  ros-lyrical-navigation2 ros-lyrical-nav2-bringup \
  ros-lyrical-ros-gz \
  ros-lyrical-rosbridge-suite ros-lyrical-foxglove-bridge ros-lyrical-diagnostic-aggregator \
  ros-lyrical-image-transport-plugins \
  ros-dev-tools

# Optional pieces: install each on its own so one missing package does not stop the rest.
for pkg in ros-lyrical-nav2-minimal-tb3-sim ros-lyrical-turtlebot3-gazebo ros-lyrical-turtlebot3-navigation2 \
           ros-lyrical-rmw-zenoh-cpp; do
  sudo apt-get install -y "$pkg" || echo "OPTIONAL PACKAGE NOT INSTALLED: $pkg"
done

grep -q '/opt/ros/lyrical/setup.bash' ~/.bashrc || cat >> ~/.bashrc <<'EOF'
source /opt/ros/lyrical/setup.bash
export TURTLEBOT3_MODEL=waffle
export ROS_DOMAIN_ID=0
EOF

echo "ROS 2 Lyrical Luth install finished: $(date)"

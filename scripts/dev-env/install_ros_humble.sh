#!/usr/bin/env bash
# Installs ROS 2 Humble + Gazebo Classic + TurtleBot3 + Nav2 + rosbridge into the `ros-humble` WSL
# distro (Ubuntu 22.04). Everything lands inside that distro, so `wsl --unregister ros-humble`
# removes all of it. Run as:  MSYS_NO_PATHCONV=1 wsl -d ros-humble -- bash /mnt/c/<path to repo>/scripts/dev-env/install_ros_humble.sh
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
  ros-humble-desktop \
  ros-humble-navigation2 ros-humble-nav2-bringup \
  ros-humble-turtlebot3-gazebo ros-humble-turtlebot3-navigation2 \
  ros-humble-rosbridge-suite \
  ros-humble-image-transport-plugins ros-humble-compressed-image-transport \
  ros-dev-tools

grep -q '/opt/ros/humble/setup.bash' ~/.bashrc || cat >> ~/.bashrc <<'EOF'
source /opt/ros/humble/setup.bash
export TURTLEBOT3_MODEL=waffle
export ROS_DOMAIN_ID=0
EOF

echo "ROS 2 Humble install finished: $(date)"

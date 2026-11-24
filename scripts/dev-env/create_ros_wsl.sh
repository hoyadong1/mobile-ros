#!/usr/bin/env bash
# Creates a dedicated WSL distro for one ROS distribution and installs ROS into it, so the test robots
# never touch your everyday WSL. Run from Git Bash on Windows:
#   bash scripts/dev-env/create_ros_wsl.sh humble   # ros-humble: Ubuntu 22.04 + ROS 2 Humble (Gazebo Classic)
#   bash scripts/dev-env/create_ros_wsl.sh jazzy    # ros-jazzy:  Ubuntu 24.04 + ROS 2 Jazzy (Gazebo Harmonic)
#   bash scripts/dev-env/create_ros_wsl.sh lyrical  # ros-lyrical: Ubuntu 26.04 + ROS 2 Lyrical Luth (from the Store image)
# DIR=<windows folder> sets where the distro disk and downloaded image go (default %USERPROFILE%\ros-ai-lab).
# Remove everything again with:  wsl --unregister ros-humble   (or ros-jazzy), then delete DIR.
# The ROS install downloads ~1 GB and takes 20-40 minutes.
set -euo pipefail
case "${1:-}" in
  humble) NAME=ros-humble; REL=22.04; IMG=ubuntu-jammy-wsl-amd64-wsl.rootfs.tar.gz ;;
  jazzy)  NAME=ros-jazzy;  REL=24.04; IMG=ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz ;;
  lyrical) NAME=ros-lyrical; REL=26.04; IMG= ;;  # no cloud image yet: installed from the Store image below
  *) echo "usage: $0 humble|jazzy|lyrical"; exit 2 ;;
esac
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WSL_REPO="$(echo "$REPO" | sed -E 's#^/([a-zA-Z])/#/mnt/\L\1/#')"
DIR="${DIR:-$(cygpath -w "$HOME")\\ros-ai-lab}"
DL="$(cygpath -u "$DIR")/downloads"
mkdir -p "$DL"

if wsl.exe -l -q | iconv -f utf-16le -t utf-8 | tr -d '\r' | grep -qx "$NAME"; then
  echo "$NAME already exists; installing ROS into it again (apt skips what is there)."
elif [ -z "$IMG" ]; then
  wsl.exe --install "Ubuntu-$REL" --name "$NAME" --no-launch --location "$DIR\wsl\$NAME"
  wsl.exe -d "$NAME" -u root -- bash -c 'useradd -m -s /bin/bash -G sudo ros &&
    echo "ros ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ros && chmod 440 /etc/sudoers.d/ros &&
    printf "[user]
default=ros
" > /etc/wsl.conf'
  wsl.exe --terminate "$NAME"
else
  base="https://cloud-images.ubuntu.com/wsl/releases/$REL/current"
  echo "Downloading Ubuntu $REL WSL image..."
  curl -sfL "$base/$IMG" -o "$DL/$IMG"
  curl -sfL "$base/SHA256SUMS" -o "$DL/SHA256SUMS-$REL"
  (cd "$DL" && grep " \*\?$IMG\$" "SHA256SUMS-$REL" | sha256sum -c -)
  wsl.exe --import "$NAME" "$DIR\\wsl\\$NAME" "$(cygpath -w "$DL/$IMG")" --version 2
  # A normal user with passwordless sudo, as the default login.
  wsl.exe -d "$NAME" -u root -- bash -c 'useradd -m -s /bin/bash -G sudo ros &&
    echo "ros ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ros && chmod 440 /etc/sudoers.d/ros &&
    printf "[user]\ndefault=ros\n" > /etc/wsl.conf'
  wsl.exe --terminate "$NAME"
  rm -f "$DL/$IMG"   # only needed to create the distro
fi
MSYS_NO_PATHCONV=1 wsl.exe -d "$NAME" -- bash "$WSL_REPO/scripts/dev-env/install_ros_${1}.sh"
echo "Done: $NAME. Try:  DISTRO=${1} bash scripts/dev-env/sim_live_test.sh"

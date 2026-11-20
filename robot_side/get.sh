#!/usr/bin/env bash
# Mobile ROS remote access, one line on the robot computer:
#   curl -fsSL @RELAY@/i | sudo bash
# Options after "bash -s --": --name "My robot", --no-rosbridge-service, --reregister.
# Downloads the robot files from this server, checks them against the checksums below (published with
# them) and runs install_agent.sh, which installs the agent as a service and shows a QR code to approve
# the robot from a signed-in phone. Nothing about the account is in this command.
set -euo pipefail

RELAY='@RELAY@'
NAME="" ROSBRIDGE=yes EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --no-rosbridge-service) ROSBRIDGE=no; shift ;;
    --reregister) EXTRA+=(--reregister); shift ;;
    *) echo "Unknown option $1" >&2; exit 1 ;;
  esac
done
if [[ $(id -u) != 0 ]]; then
  echo "Run it with sudo:  curl -fsSL $RELAY/i | sudo bash" >&2
  exit 1
fi
OWNER="${SUDO_USER:-}"
if [[ -z "$OWNER" || "$OWNER" == root ]]; then
  echo "Run it with sudo from your own user (the agent runs as that user, not as root)." >&2
  exit 1
fi
[[ -n "$NAME" ]] || NAME="$(hostname)"
NAME="${NAME:0:60}"
command -v curl >/dev/null || { echo "curl is needed." >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is needed." >&2; exit 1; }

echo
echo "Mobile ROS remote access for \"$NAME\" (user $OWNER)"
dir="$(mktemp -d /tmp/mobile-ros-setup-XXXXXX)"
trap 'rm -rf "$dir"' EXIT
for file in install_agent.sh register_robot.py mobile_ros_agent.py; do
  curl -fsSL --proto '=https' "$RELAY/robot/$file" -o "$dir/$file"
done
(cd "$dir" && sha256sum --quiet -c - <<'SUMS'
@CHECKSUMS@
SUMS
) || { echo "The downloaded files did not match. Nothing was installed." >&2; exit 1; }
bash "$dir/install_agent.sh" --interactive --relay "$RELAY" --name "$NAME" --user "$OWNER" \
  --rosbridge-service "$ROSBRIDGE" "${EXTRA[@]}"

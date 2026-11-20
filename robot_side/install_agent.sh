#!/usr/bin/env bash
# Sets up remote access on a robot computer: installs the Mobile ROS agent as a service that starts at
# boot (and rosbridge too when asked), then registers the robot. The Mobile ROS app runs this over SSH
# with sudo after the owner signs in; nobody types anything on the robot. It can also be run by hand:
#   sudo bash install_agent.sh --relay https://mobile-ros.com --name "My robot" --user "$USER"
#
# Output for the app: "STEP <text>" while working, "FAIL <reason>" on failure, and finally
# "RESULT <json>": {"id", "code"} for a new registration (the one-time code goes only to the app that
# started this, over SSH) or {"status":"already"} when the robot was set up before.
# With --interactive (the one-line install, https://YOUR_SERVER/i) it talks to a person instead: it shows
# the approval link as a QR code and a short code, and waits until the robot is added to an account.
set -euo pipefail

INTERACTIVE=no
step() { if [[ "$INTERACTIVE" == yes ]]; then echo "  - $*"; else echo "STEP $*"; fi; }
fail() { if [[ "$INTERACTIVE" == yes ]]; then echo "  x $*" >&2; else echo "FAIL $*"; fi; exit 1; }

RELAY="" NAME="" OWNER="" ROSBRIDGE=no REREGISTER=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay) RELAY="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --user) OWNER="${2:-}"; shift 2 ;;
    --rosbridge-service) ROSBRIDGE="${2:-}"; shift 2 ;;
    --reregister) REREGISTER=yes; shift ;;
    --interactive) INTERACTIVE=yes; shift ;;
    *) fail "Unknown option $1" ;;
  esac
done
[[ $(id -u) == 0 ]] || fail "Administrator rights (sudo) are needed."
[[ "$RELAY" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || fail "Invalid relay address."
[[ -n "$NAME" && ${#NAME} -le 60 ]] || fail "Enter a robot name (1-60 characters)."
[[ "$OWNER" =~ ^[a-z_][a-z0-9_-]*$ ]] && id "$OWNER" >/dev/null 2>&1 || fail "Unknown user $OWNER."
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || fail "This computer does not use systemd; start the agent by hand."
command -v python3 >/dev/null || fail "Python 3 is needed."

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/opt/mobile-ros-agent
DATA=/var/lib/mobile-ros-agent
TOKEN="$DATA/agent-token"
RELAY="${RELAY%/}"
WSS="${RELAY/https:/wss:}/agent"

step "Installing the agent"
install -d -m 0755 "$PREFIX"
install -m 0644 "$SRC/mobile_ros_agent.py" "$SRC/register_robot.py" "$PREFIX/"
# tornado ships with rosbridge on ROS computers; otherwise a private environment gets the pinned version.
if sudo -u "$OWNER" python3 -c 'import tornado' >/dev/null 2>&1; then
  PY="$(command -v python3)"
else
  if ! python3 -m venv --help >/dev/null 2>&1 || ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
    step "Installing Python tools"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv >/dev/null 2>&1 || fail "Could not install python3-venv."
  fi
  [[ -x "$PREFIX/venv/bin/python" ]] || python3 -m venv "$PREFIX/venv" || fail "Could not create the Python environment."
  "$PREFIX/venv/bin/pip" install -q tornado==6.5.2 >/dev/null 2>&1 || fail "Could not install tornado (internet needed)."
  PY="$PREFIX/venv/bin/python"
fi
install -d -o "$OWNER" -g "$(id -gn "$OWNER")" -m 0700 "$DATA"

RESULT='{"status":"already"}'
if [[ "$REREGISTER" == yes ]]; then
  systemctl stop mobile-ros-agent.service >/dev/null 2>&1 || true
  rm -f "$TOKEN"
fi
if [[ ! -s "$TOKEN" ]]; then
  step "Registering with Mobile ROS"
  RESULT="$(sudo -u "$OWNER" "$PY" "$PREFIX/register_robot.py" --relay "$RELAY" --name "$NAME" \
    --token-file "$TOKEN" --enroll-only)" || fail "Could not register (check the internet connection)."
fi

if [[ "$ROSBRIDGE" == yes ]]; then
  step "Starting rosbridge at boot"
  setup=""
  for d in jazzy humble kilted rolling iron; do
    if [[ -f "/opt/ros/$d/setup.bash" ]] && sudo -u "$OWNER" bash -c "source /opt/ros/$d/setup.bash && ros2 pkg prefix rosbridge_server" >/dev/null 2>&1; then
      setup="/opt/ros/$d/setup.bash"; break
    fi
  done
  if [[ -n "$setup" ]]; then
    cat > /etc/systemd/system/mobile-ros-rosbridge.service <<UNIT
[Unit]
Description=rosbridge for Mobile ROS
After=network-online.target
Wants=network-online.target

[Service]
User=$OWNER
ExecStart=/bin/bash -c 'source $setup && exec ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:=9090'
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    # A rosbridge started by hand keeps running now; the service takes over from the next boot.
    if ss -ltn 2>/dev/null | grep -q ':9090 '; then systemctl enable mobile-ros-rosbridge.service >/dev/null 2>&1
    else systemctl enable --now mobile-ros-rosbridge.service >/dev/null 2>&1; fi
  else
    step "rosbridge_server not found; start rosbridge yourself"
  fi
fi

step "Starting the agent"
cat > /etc/systemd/system/mobile-ros-agent.service <<UNIT
[Unit]
Description=Mobile ROS remote access agent
After=network-online.target
Wants=network-online.target

[Service]
User=$OWNER
ExecStart=$PY $PREFIX/mobile_ros_agent.py --relay $WSS --rosbridge ws://127.0.0.1:9090 --token-file $TOKEN
Restart=always
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable mobile-ros-agent.service >/dev/null 2>&1
since="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart mobile-ros-agent.service
for _ in $(seq 1 30); do
  journalctl -u mobile-ros-agent.service --since "$since" --no-pager 2>/dev/null | grep -q 'connected to' && break
  sleep 1
done
journalctl -u mobile-ros-agent.service --since "$since" --no-pager 2>/dev/null | grep -q 'connected to' ||
  fail "The agent started but could not reach Mobile ROS. Check the internet connection."
if [[ "$INTERACTIVE" != yes ]]; then
  echo "RESULT $RESULT"
  exit 0
fi

CODE="$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1]).get("code", ""))' "$RESULT")"
if [[ -z "$CODE" ]]; then
  echo
  echo "  This robot computer was set up before; the agent is running and starts at boot."
  echo "  Not in My robots? Add it again (replaces the old registration):"
  echo "    curl -fsSL $RELAY/i | sudo bash -s -- --reregister"
  exit 0
fi
# A QR code is easier than typing the link; qrencode is small and optional.
command -v qrencode >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 || true
sudo -u "$OWNER" "$PY" "$PREFIX/register_robot.py" --relay "$RELAY" --show "$CODE"
echo "  Waiting for approval... (Ctrl+C is safe: the agent keeps running)"
if sudo -u "$OWNER" "$PY" "$PREFIX/register_robot.py" --relay "$RELAY" --token-file "$TOKEN" --wait; then
  echo
  echo "  Done. \"$NAME\" is in My robots and starts with this computer."
else
  echo
  echo "  The code expired before it was approved. Run the same command again with --reregister."
  exit 2
fi

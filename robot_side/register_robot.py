#!/usr/bin/env python3
"""Run on the robot computer to add it to a Mobile ROS account.

Stores the robot credential in a private file and shows a ten-minute, single-use link (as a QR code
when `qrencode` is installed) and a short code. The owner opens the link with the phone camera, or
types the code in My robots, and approves. Then starts the existing validated robot agent.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit

CODE = re.compile(r'[A-HJKMNP-TV-Z2-9]{4}-[A-HJKMNP-TV-Z2-9]{4}')


def check_relay(relay):
    base = urlsplit(relay)
    if base.scheme != 'https' or not base.hostname or base.username or base.password or base.query or base.fragment or base.path not in ('', '/'):
        raise ValueError('Use the relay HTTPS base address.')
    return relay.rstrip('/')


def link_for(relay, code):
    """The approval link; built here from the relay address, not taken from the server's reply.
    It opens the Mobile ROS app when installed (Android App Links), else the web app."""
    return f'{check_relay(relay)}/link/{quote(code)}'


def enroll(relay, name, token_file, opener=urllib.request.urlopen):
    relay = check_relay(relay)
    target = Path(token_file).expanduser()
    if target.exists():
        raise ValueError('A robot token file already exists. Use it with mobile_ros_agent.py, or choose a new file after removing the old registration in My robots.')
    request = urllib.request.Request(relay + '/api/enrollments',
        data=json.dumps({'name': name}).encode(), headers={'Content-Type': 'application/json'}, method='POST')
    with opener(request, timeout=15) as response:
        data = json.load(response)
    if not re.fullmatch(r'r-[a-f0-9-]{36}', data.get('id', '')) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', data.get('token', '')) or not CODE.fullmatch(data.get('code', '')):
        raise ValueError('The relay returned invalid registration information.')
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(data['token'])
    return data['id'], data['code'], str(target)


def qr(text, out=sys.stdout):
    """Prints [text] as a terminal QR code when qrencode is installed; returns whether it did."""
    tool = shutil.which('qrencode')
    if not tool:
        return False
    try:
        # Half-height block characters: two QR rows per terminal line keep it small (about 31x16 for the
        # link); phones read it in a normal terminal (checked with a phone camera).
        drawn = subprocess.run([tool, '-t', 'ANSIUTF8', '-m', '2', text], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    if drawn.returncode != 0 or not drawn.stdout:
        return False
    out.write(drawn.stdout)
    out.flush()
    return True


def show(relay, code, out=sys.stdout):
    link = link_for(relay, code)
    out.write('\nAdd this robot to your Mobile ROS account:\n\n')
    if qr(link, out):
        out.write('\n  Scan with your phone camera, or open:\n')
    else:
        out.write('  On your phone, open:\n')
    out.write(f'  {link}\n\n  Or in the app: My robots > Register a robot > code  {code}\n'
              '  Expires in 10 minutes. Do not share it with anyone else.\n\n')
    out.flush()


def wait_for_owner(relay, token_file, opener=urllib.request.urlopen, sleep=time.sleep, limit=660):
    """Polls until someone added the robot (True) or the registration expired (False)."""
    relay = check_relay(relay)
    token = Path(token_file).expanduser().read_text().strip()
    waited = 0
    while waited <= limit:
        request = urllib.request.Request(relay + '/api/enrollments/status', headers={'Authorization': f'Bearer {token}'})
        try:
            with opener(request, timeout=15) as response:
                if json.load(response).get('claimed') is True:
                    return True
        except urllib.error.HTTPError as error:
            if error.code in (401, 410):
                return False
        except (OSError, ValueError):
            pass  # a network hiccup: try again
        sleep(3)
        waited += 3
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--relay', required=True, help='HTTPS relay base address')
    parser.add_argument('--name', help='Name shown in My robots')
    parser.add_argument('--token-file', default=str(Path.home()/'.local/share/mobile-ros/agent-token'))
    parser.add_argument('--rosbridge', default='ws://127.0.0.1:9090')
    parser.add_argument('--enroll-only', action='store_true',
        help='Register and print {"id","code"} as JSON for install_agent.sh; do not start the agent')
    parser.add_argument('--show', metavar='CODE', help='Print the approval link, QR code and code (install_agent.sh)')
    parser.add_argument('--wait', action='store_true', help='Wait until the robot is added to an account (install_agent.sh)')
    args = parser.parse_args()
    if args.show:
        if not CODE.fullmatch(args.show):
            parser.error('invalid code')
        show(args.relay, args.show)
        return
    if args.wait:
        sys.exit(0 if wait_for_owner(args.relay, args.token_file) else 2)
    if not args.name:
        parser.error('--name is required')
    try:
        robot_id, code, target = enroll(args.relay, args.name, args.token_file)
    except Exception:
        sys.exit('Could not register. Check the relay address, internet connection, and that the token file does not already exist. No existing token file was changed.')
    if args.enroll_only:
        # Read by the installer (or the app over its own SSH session); the credential stays in the file.
        print(json.dumps({'id': robot_id, 'code': code}), flush=True)
        return
    show(args.relay, code)
    # Keep credentials out of the process arguments and stdout. The existing agent reads the file.
    os.execv(sys.executable, [sys.executable, str(Path(__file__).with_name('mobile_ros_agent.py')),
        '--relay', args.relay.rstrip('/').replace('https:', 'wss:', 1) + '/agent',
        '--rosbridge', args.rosbridge, '--token-file', target])


if __name__ == '__main__':
    main()

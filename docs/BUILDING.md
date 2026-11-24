# Build and run Mobile ROS yourself

This gets you from a fresh clone to the app running against a robot, a simulated robot or a fake one, without
Google Play. The steps were checked on a fresh clone (Windows 11, Flutter 3.50): `flutter pub get`, analyze, all
tests, the Android debug and release APKs, the web build, and the fake robot with the quickstart test.

- [1. What you need](#1-what-you-need)
- [2. Get the code and check it](#2-get-the-code-and-check-it)
- [3. Run it](#3-run-it) — Android phone, emulator, browser, Windows
- [4. Something to connect to](#4-something-to-connect-to) — real robot, fake robot, simulation
- [5. Tests](#5-tests)
- [6. Native libraries](#6-native-libraries-only-if-you-change-them)
- [7. Troubleshooting](#7-troubleshooting)

## 1. What you need

| | Version | Needed for |
| --- | --- | --- |
| [Flutter](https://docs.flutter.dev/get-started/install) | **3.50 or newer**, stable channel (Dart 3.14) | everything |
| Android Studio or the Android SDK command-line tools | SDK from Flutter's `flutter doctor` | running on Android |
| Chrome or Edge | any recent | running in a browser |
| Visual Studio 2022 with "Desktop development with C++" **and the "C++ ATL" component** | | running on Windows |
| Python 3.10+ with `pip install websockets` | | the fake robot |

You do **not** need the Android NDK, CMake or a C compiler: the native libraries (direct DDS, Zenoh, the
on-device model) are committed prebuilt in `android/app/src/main/jniLibs` and `native/*/prebuilt`.

Check your setup:

```sh
flutter --version     # 3.50.0 or newer
flutter doctor        # Android toolchain (and Chrome / Visual Studio if you want those) without errors
```

## 2. Get the code and check it

```sh
git clone https://github.com/hoyadong1/mobile-ros.git
cd mobile-ros
flutter pub get
flutter analyze lib test tool     # expect: No issues found
flutter test                      # expect: All tests passed (about 600, a minute or two)
```

`flutter test` needs no robot, phone or network: robots are faked in `test/support/`.

## 3. Run it

### On an Android phone or tablet

1. On the phone: Settings → About phone → tap *Build number* 7 times, then Developer options → **USB debugging**
   (or **Wireless debugging**, then `adb pair` / `adb connect`).
2. Plug it in and check it is listed: `flutter devices`.
3. If the Play Store version of Mobile ROS is installed, uninstall it first: your build is signed with a different
   key, so Android refuses to install it over the store one.
4. Run:

```sh
flutter run                    # debug build with hot reload
flutter run --release          # optimised build (signed with your debug key)
```

To hand an APK to someone: `flutter build apk --release`, then `build/app/outputs/flutter-apk/app-release.apk`.

### On the Android emulator

Create an x86_64 emulator in Android Studio (Device Manager; API 34 works) and `flutter run`. From the emulator your
PC is **10.0.2.2**: a robot or simulation on the PC is reached at `10.0.2.2:9090`. Direct DDS needs a real network
(multicast) and does not work through the emulator; rosbridge, Foxglove and Zenoh do.

### In a browser

```sh
flutter run -d chrome          # or -d edge
```

The browser build has rosbridge and the Foxglove bridge; it has no direct DDS, no Zenoh and no on-device model. It
is the quickest way to work on screens.

### On Windows

```sh
flutter run -d windows
```

rosbridge, Foxglove, Zenoh and the on-device model work; direct DDS is Android only. Two plugins (notifications,
secure storage) need Visual Studio's **C++ ATL** component: without it the build stops at `atlbase.h` /
`atlstr.h`. Keep the clone in a short path (for example `C:\src\mobile-ros`): MSBuild fails on paths over 260
characters.

## 4. Something to connect to

### A real robot

Start one of these on the robot, then in the app choose the same mode and enter the robot's address:

| Mode in the app | On the robot |
| --- | --- |
| rosbridge | `ros2 launch rosbridge_server rosbridge_websocket_launch.xml` (port 9090) |
| Foxglove | `ros2 launch foxglove_bridge foxglove_bridge_launch.xml` (port 8765) |
| Direct | nothing; phone on the same Wi-Fi, same `ROS_DOMAIN_ID` |
| Zenoh | `RMW_IMPLEMENTATION=rmw_zenoh_cpp` and `ros2 run rmw_zenoh_cpp rmw_zenohd` (port 7447) |

Before driving, make sure the robot stops on its own when commands stop arriving (driver timeout, `twist_mux`, or
`robot_side/cmd_vel_watchdog.py`).

### No robot: the fake robot (2 minutes, any OS)

A Python script that speaks rosbridge and pretends to be a small robot with odometry, a map, a camera and
`/chatter`. No ROS install needed.

```sh
pip install websockets
python scripts/fake_robot.py --port 9091
```

Connect the app with rosbridge to your PC's address and port 9091 (`127.0.0.1` in the browser or on Windows,
`10.0.2.2` on the emulator, the PC's Wi-Fi address on a phone; the script prints the addresses). Driving moves the
fake robot on its map. Options: `python scripts/fake_robot.py --help`.

A first check without opening the app: `flutter test tool/live_quickstart_test.dart --dart-define=PORT=9091` lists
the topics, reads odometry, drives one second and checks the robot moved.

### No robot: TurtleBot3 + Nav2 in Gazebo (Windows with WSL, about 30 minutes once)

A real ROS 2 stack: Nav2, AMCL, a lidar, a camera, rosbridge. The scripts in `scripts/dev-env/` set it up in its own
WSL distro, so your other Linux setups are untouched.

```sh
bash scripts/dev-env/create_ros_wsl.sh jazzy     # once: Ubuntu 24.04 + ROS 2 Jazzy + Nav2 + Gazebo (~1 GB)
DISTRO=jazzy bash scripts/dev-env/sim_live_test.sh tool/live_robot_test.dart
```

`sim_live_test.sh` starts the simulation from a fresh state, waits until it is ready and runs a live test. The
simulation keeps running afterwards (rosbridge on `127.0.0.1:9090`), so you can also connect the app to it by hand;
stop it with `wsl --terminate ros-jazzy`. `RMW=rmw_zenoh_cpp` runs the robot on Zenoh instead. The script headers
list every option.

On Linux or macOS, run the same thing natively: install ROS 2 Jazzy with `ros-jazzy-nav2-bringup`,
`ros-jazzy-nav2-minimal-tb3-sim`, `ros-jazzy-ros-gz` and `ros-jazzy-rosbridge-suite`, then `HEADLESS=1 bash scripts/ros2_jazzy_sim.sh`.

## 5. Tests

| Command | What it checks | Needs |
| --- | --- | --- |
| `flutter test` | Unit and widget tests | nothing |
| `flutter analyze lib test tool` | Lints and types | nothing |
| `bash scripts/dev-env/localized_review.sh` | Every screen in all five languages at phone and tablet sizes, no overflow | Flutter only |
| `flutter test tool/live_<name>_test.dart` | One feature against a real robot | a robot or the simulation |
| `bash scripts/dev-env/sim_live_test.sh tool/live_<name>_test.dart` | The same on a fresh simulation | WSL simulation |

Pull requests need the first two to pass; if you change driving, navigation or the assistant, say which live test
you ran (see [CONTRIBUTING.md](../CONTRIBUTING.md)).

## 6. Native libraries (only if you change them)

The C parts live in `native/`; each folder has the build scripts used for the committed libraries.

| Library | Source | Android build | Windows build |
| --- | --- | --- | --- |
| Direct DDS | `native/dds` (Eclipse Cyclone DDS) | `native/dds/build_android.ps1` | — |
| Zenoh | `native/zenoh` (zenoh-pico) | `native/zenoh/build_android.ps1` | `native/zenoh/build_windows.ps1` |
| On-device model | `native/llm` (llama.cpp) | `native/llm/build_android.ps1` | `native/llm/build_windows.ps1` |

Android builds need NDK 28.2.13676358 and CMake 3.22.1 (both from Android Studio's SDK Manager → SDK Tools) and git;
Windows builds need Visual Studio 2022 C++ tools. The scripts are PowerShell; they copy their output where the app
loads it.

## 7. Troubleshooting

| Problem | Fix |
| --- | --- |
| `version solving failed` / SDK too old | `flutter upgrade`; the app needs Flutter 3.50+ |
| Windows: `atlbase.h` / `atlstr.h` not found | Visual Studio Installer → Modify → Individual components → "C++ ATL for latest build tools" |
| Windows: "Unable to generate build files" | Move the clone to a shorter path (MSBuild's 260-character limit) |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` on a phone | Uninstall the Play Store version (different signing key) |
| Connects, but no topics | rosbridge: is `rosapi` running (it starts with the launch file)? Direct DDS: same Wi-Fi and `ROS_DOMAIN_ID`, and UDP 7400–7700 open on the robot |
| Phone cannot reach the PC | Allow the port in the PC's firewall (private network); use the PC's Wi-Fi address, not 127.0.0.1 |
| Emulator cannot reach the PC | Use `10.0.2.2`, not `127.0.0.1` |
| Zenoh: "could not reach the Zenoh router" | Router running and port 7447 reachable; the app is a client of the router, it does not scout |
| The assistant does nothing offline | The on-device model downloads on first use (about 1.3 GB); check free space and network once |

Still stuck? [Open an issue](https://github.com/hoyadong1/mobile-ros/issues) with your OS, `flutter --version`, the
command and its output.

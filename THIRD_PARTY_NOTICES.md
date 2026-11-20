# Third-party notices

Mobile ROS is licensed under the Apache License 2.0 (`LICENSE`). It also contains the software below.
The full license and notice texts are in [`assets/licenses/`](assets/licenses/) and are shown in the app
(Menu → Open-source licenses), together with the licenses of the Dart and Flutter packages it uses.

## Native libraries built into the app

These are compiled into `android/app/src/main/jniLibs/*/libmobileros_*.so` and
`native/*/prebuilt/windows-x64/` by the scripts in `native/`, from unmodified upstream sources unless noted.

| Library | Version | License | Source | In |
| --- | --- | --- | --- | --- |
| llama.cpp (incl. ggml) | tag `v0.9.0` | MIT | https://github.com/ggml-org/llama.cpp | `libmobileros_llm*.so`, `mobileros_llm.dll` (on-device assistant) |
| Eclipse Cyclone DDS | `releases/0.10.x` at `5041f3560c088c99e5088b2b8520b69169621196` | EPL-2.0 or EDL-1.0 (BSD-3-Clause) | https://github.com/eclipse-cyclonedds/cyclonedds | `libmobileros_dds.so` (direct ROS 2 connection) |
| Eclipse zenoh-pico | tag `1.8.0` | EPL-2.0 or Apache-2.0 | https://github.com/eclipse-zenoh/zenoh-pico | `libmobileros_zenoh.so` (Zenoh connection) |

Cyclone DDS is built with the changes in [`native/dds/cyclonedds-android.patch`](native/dds/cyclonedds-android.patch)
so it builds and runs on Android; that file is the complete source of those changes. Security, SSL and shared
memory are turned off in this build. The code that ties each library to the app (`native/*/mobileros_*.c`) is
part of Mobile ROS (Apache-2.0).

| File in `assets/licenses/` | Text |
| --- | --- |
| `llama_cpp.txt` | llama.cpp `LICENSE` (MIT) |
| `cyclonedds.txt`, `cyclonedds_notice.txt` | Cyclone DDS `LICENSE` (EPL-2.0 / EDL-1.0) and `NOTICE.md` |
| `zenoh_pico.txt`, `zenoh_pico_notice.txt` | zenoh-pico `LICENSE` (Apache-2.0 / EPL-2.0) and `NOTICE.md` |

## Data

`assets/ros2_interfaces.json` and `assets/message_types.json` list ROS message, service and action field
definitions taken from ROS 2 interface packages (for example `common_interfaces`, `rcl_interfaces`,
`ackermann_msgs`), which are under the Apache License 2.0 (some under BSD-3-Clause).

## Dart and Flutter packages

Packages from pub.dev (see `pubspec.yaml` and `pubspec.lock`) keep their own licenses; Flutter collects them
into the app's licenses page automatically. On Android, `mobile_scanner` uses Google ML Kit barcode scanning
under the [ML Kit terms](https://developers.google.com/ml-kit/terms).

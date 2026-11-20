import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Native libraries built into the app (android/app/src/main/jniLibs, native/*/prebuilt). Dart and Flutter
/// packages register their own licenses; these are C libraries, so their notices are added here and shown
/// on the app's open-source licenses page. The texts are the upstream files of the shipped versions
/// (assets/licenses/, listed in THIRD_PARTY_NOTICES.md).
const thirdPartyNatives = [
  (package: 'llama.cpp (ggml)', files: ['llama_cpp.txt']),
  (package: 'Eclipse Cyclone DDS', files: ['cyclonedds_notice.txt', 'cyclonedds.txt']),
  (package: 'Eclipse zenoh-pico', files: ['zenoh_pico_notice.txt', 'zenoh_pico.txt']),
];

bool _registered = false;

/// Once, at start-up.
void registerThirdPartyLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    for (final native in thirdPartyNatives) {
      for (final file in native.files) {
        yield LicenseEntryWithLineBreaks([native.package], await rootBundle.loadString('assets/licenses/$file'));
      }
    }
  });
}

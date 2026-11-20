import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/third_party_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every native library in the app has its license text, as listed in THIRD_PARTY_NOTICES.md', () async {
    registerThirdPartyLicenses();
    registerThirdPartyLicenses(); // once only
    final entries = await LicenseRegistry.licenses.toList();
    final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    for (final native in thirdPartyNatives) {
      final mine = entries.where((e) => e.packages.contains(native.package)).toList();
      expect(mine, hasLength(native.files.length), reason: native.package);
      expect(mine.every((e) => e.paragraphs.isNotEmpty), isTrue, reason: native.package);
      for (final file in native.files) {
        expect(notices, contains(file), reason: 'THIRD_PARTY_NOTICES.md lists $file');
      }
    }
    String text(String package) => entries.where((e) => e.packages.contains(package))
        .expand((e) => e.paragraphs).map((p) => p.text).join('\n');
    expect(text('llama.cpp (ggml)'), contains('MIT License'));
    expect(text('Eclipse Cyclone DDS'), contains('Eclipse Public License'));
    expect(text('Eclipse zenoh-pico'), contains('Apache License'));
  });

  test('each shipped native library is covered by a notice', () {
    final shipped = Directory('android/app/src/main/jniLibs').listSync(recursive: true)
        .whereType<File>().map((f) => f.uri.pathSegments.last).toSet();
    const covered = {'libmobileros_llm.so', 'libmobileros_llm_dotprod.so', 'libmobileros_dds.so', 'libmobileros_zenoh.so'};
    expect(shipped.difference(covered), isEmpty,
        reason: 'a new native library needs its license in assets/licenses/ and THIRD_PARTY_NOTICES.md');
  });
}

import 'local_backend.dart';

/// The web build has no on-device model.
class NativeLlm implements LocalModel {
  NativeLlm(this.modelPath);

  final String modelPath;

  static bool get available => false;
  static String? get loadError => 'Not available in the browser.';

  @override
  Future<String> generate({required String system, required String user, required String grammar,
          int maxTokens = 160}) =>
      Future.error(UnsupportedError('No on-device model in the browser.'));

  @override
  void cancel() {}

  Future<void> dispose() async {}
}

/// Where the on-device model file lives and how it gets there.
class LocalModelFile {
  static const sizeBytes = 0;
  static Future<String?> path() async => null;
  static Future<bool> exists() async => false;
  static Future<void> download({void Function(int received, int total)? onProgress}) =>
      Future.error(UnsupportedError('No on-device model in the browser.'));
  static Future<void> delete() async {}
}

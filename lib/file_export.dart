import 'package:flutter/services.dart';

/// Saves bytes where the person chooses (Android's "save as": Downloads, Drive, …).
/// True when saved, false when they cancelled; throws [FileExportUnavailable] where it cannot be done.
Future<bool> saveFileAs(String name, Uint8List bytes, {String mime = 'application/octet-stream',
    MethodChannel channel = const MethodChannel('mobile_ros/files')}) async {
  try {
    return await channel.invokeMethod<bool>('saveAs', {'name': name, 'bytes': bytes, 'mime': mime}) ?? false;
  } on MissingPluginException {
    throw const FileExportUnavailable();
  } on PlatformException catch (e) {
    if (e.code == 'unavailable') throw const FileExportUnavailable();
    rethrow;
  }
}

class FileExportUnavailable implements Exception {
  const FileExportUnavailable();
}

import 'app_language.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app_links.dart';
import 'link_robot_page.dart' show normalizeRobotCode;

/// Scans the QR code the robot computer shows after the one-line install and returns its code
/// (XXXX-XXXX). Other QR codes are ignored; nothing is opened from them.
class ScanRobotCodePage extends StatefulWidget {
  const ScanRobotCodePage({super.key});
  @override
  State<ScanRobotCodePage> createState() => _ScanRobotCodePageState();
}

class _ScanRobotCodePageState extends State<ScanRobotCodePage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false, _wrong = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text == null) continue;
      final code = normalizeRobotCode(robotCodeFromLink(text) ?? '');
      if (code != null) {
        _done = true;
        Navigator.pop(context, code);
        return;
      }
    }
    if (!_wrong) setState(() => _wrong = true);
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.strings.scanRobotQr)),
    body: Stack(children: [
      MobileScanner(controller: _scanner, onDetect: _onDetect,
        errorBuilder: (context, error) => Center(child: Padding(padding: const EdgeInsets.all(24),
          child: Text(error.errorCode == MobileScannerErrorCode.permissionDenied
              ? 'Allow the camera to scan, or type the code shown under the QR code.'
              : 'The camera is not available. Type the code shown under the QR code.',
            textAlign: TextAlign.center)))),
      Align(alignment: Alignment.bottomCenter, child: SafeArea(child: Container(
        margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
        child: Text(_wrong ? 'That is not a Mobile ROS robot code. Scan the code on the robot computer.'
            : 'Point the camera at the QR code in the robot computer’s terminal.',
          style: const TextStyle(color: Colors.white), textAlign: TextAlign.center)))),
    ]),
  );
}

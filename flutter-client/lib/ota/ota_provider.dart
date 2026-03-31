import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'nus_ota_service.dart';

class OtaProvider extends ChangeNotifier {
  final _svc = NusOtaService();

  OtaProgress _progress = const OtaProgress();
  OtaProgress get progress => _progress;

  String?    _fileName;
  Uint8List? _fileBytes;
  String?    get fileName  => _fileName;
  bool       get fileReady => _fileBytes != null;

  OtaProvider() {
    _svc.progress.listen((p) {
      _progress = p;
      notifyListeners();
    });
  }

  void setFile(String name, Uint8List bytes) {
    _fileName  = name;
    _fileBytes = bytes;
    notifyListeners();
  }

  /// Call when your existing BLE code already has a live connection.
  Future<void> startOtaOnConnected({
    required BluetoothDevice device,
    String? version,
    String? token,
  }) async {
    if (_fileBytes == null) throw Exception("No file selected");
    await _svc.runOtaOnConnected(
      device:    device,
      filename:  _fileName ?? "main.py",
      fileBytes: _fileBytes!,
      version:   version,
      token:     token,
    );
  }

  /// Call when you want the OTA service to manage its own connection.
  Future<void> startOta({
    required BluetoothDevice device,
    String? version,
    String? token,
  }) async {
    if (_fileBytes == null) throw Exception("No file selected");
    await _svc.runOta(
      device:    device,
      filename:  _fileName ?? "main.py",
      fileBytes: _fileBytes!,
      version:   version,
      token:     token,
    );
  }

  Future<void> abort() => _svc.abort();

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }
}

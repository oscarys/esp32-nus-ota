// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
// https://github.com/oscarys/esp32-nus-ota
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/device_history.dart';
import '../models/device_record.dart';
import 'nus_ota_service.dart';

class OtaProvider extends ChangeNotifier {
  final DeviceHistory history;

  OtaProvider({required this.history}) {
    _svc.progress.listen((p) {
      _progress = p;
      notifyListeners();
    });
  }

  final _svc = NusOtaService();

  OtaProgress _progress = const OtaProgress();
  OtaProgress get progress => _progress;

  // ── Scan state ───────────────────────────────────────────────────
  bool             _scanning        = false;
  String?          _permissionError;
  StreamSubscription? _scanSub;

  bool    get scanning        => _scanning;
  String? get permissionError => _permissionError;

  final List<BluetoothDevice> _scanResults = [];
  List<BluetoothDevice> get scanResults => List.unmodifiable(_scanResults);

  // ── Selected device ──────────────────────────────────────────────
  BluetoothDevice? _device;
  BluetoothDevice? get device => _device;

  void selectDevice(BluetoothDevice d) {
    _device = d;
    notifyListeners();
  }

  // ── Selected file ────────────────────────────────────────────────
  String?    _fileName;
  Uint8List? _fileBytes;
  String?    get fileName  => _fileName;
  bool       get fileReady => _fileBytes != null;

  void setFile(String name, Uint8List bytes) {
    _fileName  = name;
    _fileBytes = bytes;
    notifyListeners();
  }

  // ── Permissions ──────────────────────────────────────────────────
  Future<bool> _requestBlePermissions() async {
    if (!Platform.isAndroid) return true;

    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;

    final perms = sdk >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.bluetooth, Permission.location];

    final statuses = await perms.request();
    final denied   = statuses.entries
        .where((e) => !e.value.isGranted)
        .map((e) => e.key.toString())
        .toList();

    if (denied.isNotEmpty) {
      _permissionError = 'Permissions denied: ${denied.join(', ')}. '
          'Tap Settings to enable.';
      notifyListeners();
      return false;
    }

    // Ensure adapter is on
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
      try {
        await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        _permissionError = 'Bluetooth did not turn on — enable it manually.';
        notifyListeners();
        return false;
      }
    }

    _permissionError = null;
    notifyListeners();
    return true;
  }

  // ── Scan ─────────────────────────────────────────────────────────
  Future<void> startScan() async {
    final granted = await _requestBlePermissions();
    if (!granted) return;

    // Cancel any previous subscription
    await _scanSub?.cancel();
    _scanSub = null;

    _scanResults.clear();
    _scanning = true;
    notifyListeners();

    // Subscribe BEFORE starting the scan — avoids the race where
    // results arrive before the listener is attached
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      bool changed = false;
      for (final r in results) {
        if (!_scanResults.any((d) => d.remoteId == r.device.remoteId)) {
          // No service filter — show all devices so the user can pick
          // their ESP32 regardless of what it includes in its adv packet.
          // The NUS service will be verified at connection time.
          _scanResults.add(r.device);
          changed = true;
          debugPrint('[OTA] found: ${r.device.remoteId} '
              '| ${r.device.platformName} '
              '| services: ${r.advertisementData.serviceUuids}');
        }
      }
      if (changed) notifyListeners();
    });

    // No withServices filter — many ESP32 MicroPython stacks don't
    // include the NUS UUID in the advertisement packet, only in the
    // GATT table post-connection.  We filter by NUS after connecting.
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 8),
    );

    // Wait for scan to complete then clean up
    await FlutterBluePlus.isScanning
        .where((s) => s == false)
        .first
        .timeout(const Duration(seconds: 10), onTimeout: () => false);

    await _scanSub?.cancel();
    _scanSub  = null;
    _scanning = false;
    notifyListeners();
  }

  // ── OTA ──────────────────────────────────────────────────────────
  Future<void> startOta({String? token, String? version}) async {
    if (_device == null || _fileBytes == null) return;

    try {
      await _svc.runOta(
        device:    _device!,
        filename:  _fileName ?? 'main.py',
        fileBytes: _fileBytes!,
        token:     token,
        version:   version,
      );

      await history.touch(DeviceRecord(
        remoteId: _device!.remoteId.toString(),
        name:     _device!.platformName,
        lastSeen: DateTime.now(),
        lastFile: _fileName,
      ));
    } catch (_) {
      rethrow;
    }
  }

  Future<void> abort() => _svc.abort();

  bool get canStart =>
      _device != null && fileReady && _progress.state == OtaState.idle;

  bool get busy =>
      _progress.state != OtaState.idle &&
      _progress.state != OtaState.done  &&
      _progress.state != OtaState.error;

  bool get finished =>
      _progress.state == OtaState.done ||
      _progress.state == OtaState.error;

  /// Reset state machine back to idle so a new transfer can be started.
  /// Keeps the selected device and file so the user can retry immediately.
  void reset() {
    _progress = const OtaProgress();
    notifyListeners();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _svc.dispose();
    super.dispose();
  }
}

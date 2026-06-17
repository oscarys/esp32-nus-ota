// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_record.dart';

/// Persists a list of recently used BLE devices.
/// Keeps the 10 most recently seen entries, newest first.
class DeviceHistory extends ChangeNotifier {
  static const _kPrefsKey = 'ota_device_history';
  static const _kMaxItems = 10;

  final List<DeviceRecord> _records = [];
  List<DeviceRecord> get records => List.unmodifiable(_records);

  /// Load from SharedPreferences on app start.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getStringList(_kPrefsKey) ?? [];
    _records
      ..clear()
      ..addAll(raw.map(DeviceRecord.tryFromJson).whereType<DeviceRecord>());
    notifyListeners();
  }

  /// Upsert a device (update lastSeen + lastFile, move to top).
  Future<void> touch(DeviceRecord record) async {
    _records.removeWhere((r) => r.remoteId == record.remoteId);
    _records.insert(0, record);
    if (_records.length > _kMaxItems) _records.removeLast();
    await _persist();
    notifyListeners();
  }

  /// Remove a device from history.
  Future<void> remove(String remoteId) async {
    _records.removeWhere((r) => r.remoteId == remoteId);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kPrefsKey,
      _records.map((r) => jsonEncode(r.toJson())).toList(),
    );
  }
}

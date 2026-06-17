// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'dart:convert';

/// A previously used BLE device, persisted in SharedPreferences.
class DeviceRecord {
  final String remoteId;
  final String name;
  final DateTime lastSeen;
  final String? lastFile;

  const DeviceRecord({
    required this.remoteId,
    required this.name,
    required this.lastSeen,
    this.lastFile,
  });

  String get displayName => name.isNotEmpty ? name : remoteId;

  DeviceRecord copyWith({String? lastFile, DateTime? lastSeen}) => DeviceRecord(
    remoteId: remoteId,
    name:     name,
    lastSeen: lastSeen ?? this.lastSeen,
    lastFile: lastFile ?? this.lastFile,
  );

  Map<String, dynamic> toJson() => {
    'remoteId': remoteId,
    'name':     name,
    'lastSeen': lastSeen.toIso8601String(),
    'lastFile': lastFile,
  };

  factory DeviceRecord.fromJson(Map<String, dynamic> j) => DeviceRecord(
    remoteId: j['remoteId'] as String,
    name:     j['name']     as String,
    lastSeen: DateTime.parse(j['lastSeen'] as String),
    lastFile: j['lastFile'] as String?,
  );

  static DeviceRecord? tryFromJson(String raw) {
    try {
      return DeviceRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

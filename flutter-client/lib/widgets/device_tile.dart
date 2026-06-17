// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../theme/app_theme.dart';
import '../models/device_record.dart';

/// Tile for a scan result — optionally shows history badge if known.
class DeviceTile extends StatelessWidget {
  final BluetoothDevice  device;
  final bool             selected;
  final DeviceRecord?    history;
  final VoidCallback     onTap;

  const DeviceTile({
    super.key,
    required this.device,
    required this.selected,
    required this.onTap,
    this.history,
  });

  @override
  Widget build(BuildContext context) {
    final name = device.platformName.isNotEmpty
        ? device.platformName
        : '(unnamed)';
    final addr = device.remoteId.toString();

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:        selected ? AppTheme.tealDim : AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppTheme.teal : AppTheme.border,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Row(children: [
          Icon(Icons.bluetooth,
              size: 16,
              color: selected ? AppTheme.tealText : AppTheme.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: AppTheme.sans(
                        size: 13,
                        color: selected ? AppTheme.tealText : AppTheme.textPrimary,
                        weight: FontWeight.w600)),
                Text(addr,
                    style: AppTheme.mono(size: 10, color: AppTheme.textTertiary)),
                if (history?.lastFile != null)
                  Text('last: ${history!.lastFile}',
                      style: AppTheme.mono(
                          size: 10, color: AppTheme.textTertiary)),
              ],
            ),
          ),
          if (history != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color:        AppTheme.tealDim,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('known',
                  style: AppTheme.mono(size: 9, color: AppTheme.tealText)),
            ),
          if (selected)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.check_circle_outline,
                  size: 16, color: AppTheme.tealText),
            ),
        ]),
      ),
    );
  }
}

/// Tile for a device history entry (used when not scanning).
class HistoryTile extends StatelessWidget {
  final DeviceRecord  record;
  final bool          selected;
  final VoidCallback  onTap;
  final VoidCallback  onDelete;

  const HistoryTile({
    super.key,
    required this.record,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:        selected ? AppTheme.tealDim : AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppTheme.teal : AppTheme.border,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Row(children: [
          Icon(Icons.history,
              size: 16,
              color: selected ? AppTheme.tealText : AppTheme.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(record.displayName,
                    style: AppTheme.sans(
                        size: 13,
                        color: selected ? AppTheme.tealText : AppTheme.textPrimary,
                        weight: FontWeight.w600)),
                Text(record.remoteId,
                    style: AppTheme.mono(size: 10, color: AppTheme.textTertiary)),
                if (record.lastFile != null)
                  Text('last: ${record.lastFile}',
                      style: AppTheme.mono(size: 10, color: AppTheme.textTertiary)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            color: AppTheme.textTertiary,
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ]),
      ),
    );
  }
}

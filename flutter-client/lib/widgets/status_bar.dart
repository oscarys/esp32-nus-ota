// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../ota/nus_ota_service.dart';

/// Persistent bottom status strip — shows phase, bytes, speed.
class StatusBar extends StatelessWidget {
  final OtaProgress progress;
  const StatusBar({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final (bg, fg, label) = _style(p);

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Container(
          width: 6, height: 6,
          decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: AppTheme.mono(size: 11, color: fg),
              overflow: TextOverflow.ellipsis),
        ),
        if (p.state == OtaState.transferring) ...[
          Text(
            '${p.bytesSent}/${p.totalBytes} B',
            style: AppTheme.mono(size: 11, color: AppTheme.textTertiary),
          ),
          const SizedBox(width: 12),
          Text(
            '${p.kbps.toStringAsFixed(1)} kB/s',
            style: AppTheme.mono(size: 11, color: fg),
          ),
        ],
      ]),
    );
  }

  (Color, Color, String) _style(OtaProgress p) => switch (p.state) {
    OtaState.idle         => (AppTheme.surface,   AppTheme.textTertiary, 'idle — ready to update'),
    OtaState.connecting   => (AppTheme.surfaceHigh, AppTheme.amberText,  'connecting…'),
    OtaState.handshaking  => (AppTheme.surfaceHigh, AppTheme.amberText,  'handshaking with device…'),
    OtaState.transferring => (AppTheme.tealDim,   AppTheme.tealText,
        'transferring — chunk ${p.chunksAcked}/${p.totalChunks}'),
    OtaState.committing   => (AppTheme.purpleDim, AppTheme.purpleText,  'verifying CRC32 and committing…'),
    OtaState.done         => (AppTheme.tealDim,   AppTheme.tealText,    'done — device is rebooting'),
    OtaState.error        => (AppTheme.coralDim,  AppTheme.coralText,
        'error: ${p.errorMessage ?? "unknown"}'),
  };
}

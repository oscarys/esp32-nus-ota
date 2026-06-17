// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../ota/nus_ota_service.dart';

/// Circular progress arc — the signature visual element of the app.
/// Animates chunk-by-chunk during transfer like an oscilloscope sweep.
class SweepArc extends StatefulWidget {
  final OtaProgress progress;
  const SweepArc({super.key, required this.progress});

  @override
  State<SweepArc> createState() => _SweepArcState();
}

class _SweepArcState extends State<SweepArc>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _anim;
  double _prevFraction = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _anim = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void didUpdateWidget(SweepArc old) {
    super.didUpdateWidget(old);
    final next = widget.progress.fraction;
    if ((next - _prevFraction).abs() > 0.001) {
      _anim = Tween<double>(begin: _prevFraction, end: next).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
      );
      _ctrl.forward(from: 0);
      _prevFraction = next;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prog = widget.progress;
    final color = _arcColor(prog.state);
    final label = _centerLabel(prog);

    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => CustomPaint(
        size: const Size(160, 160),
        painter: _ArcPainter(fraction: _anim.value, color: color),
        child: SizedBox(
          width: 160, height: 160,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.value,
                  style: AppTheme.mono(
                    size: label.large ? 28 : 16,
                    color: color,
                    weight: FontWeight.w700,
                  ),
                ),
                if (label.sub != null)
                  Text(
                    label.sub!,
                    style: AppTheme.mono(size: 10, color: AppTheme.textTertiary),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _arcColor(OtaState s) => switch (s) {
    OtaState.transferring => AppTheme.teal,
    OtaState.committing   => AppTheme.purpleText,
    OtaState.done         => AppTheme.teal,
    OtaState.error        => AppTheme.coralText,
    _                     => AppTheme.textTertiary,
  };

  _Label _centerLabel(OtaProgress p) => switch (p.state) {
    OtaState.idle         => const _Label('OTA',     sub: 'ready'),
    OtaState.connecting   => const _Label('BLE',     sub: 'connecting'),
    OtaState.handshaking  => const _Label('HAND',    sub: 'shaking'),
    OtaState.transferring => _Label(
        '${(p.fraction * 100).toStringAsFixed(0)}%', large: true,
        sub: '${p.kbps.toStringAsFixed(1)} kB/s'),
    OtaState.committing   => const _Label('CRC',     sub: 'verifying'),
    OtaState.done         => const _Label('DONE',    sub: 'rebooting'),
    OtaState.error        => const _Label('ERR',     sub: 'see log'),
  };
}

class _Label {
  final String value;
  final String? sub;
  final bool large;
  const _Label(this.value, {this.sub, this.large = false});
}

class _ArcPainter extends CustomPainter {
  final double fraction;
  final Color  color;
  const _ArcPainter({required this.fraction, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = cx - 12;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    // Track ring
    canvas.drawArc(
      rect, 0, math.pi * 2,
      false,
      Paint()
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color       = AppTheme.border,
    );

    // Active sweep — starts at top (-pi/2)
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * fraction,
        false,
        Paint()
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap   = StrokeCap.round
          ..color       = color,
      );
    }

    // Tick marks at 0 / 25 / 50 / 75 %
    for (int i = 0; i < 4; i++) {
      final angle = -math.pi / 2 + i * math.pi / 2;
      final inner = r - 8;
      final outer = r + 2;
      canvas.drawLine(
        Offset(cx + math.cos(angle) * inner, cy + math.sin(angle) * inner),
        Offset(cx + math.cos(angle) * outer, cy + math.sin(angle) * outer),
        Paint()
          ..color       = AppTheme.textTertiary
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.fraction != fraction || old.color != color;
}

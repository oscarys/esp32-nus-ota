// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum StepStatus { idle, active, done, error }

class StepCard extends StatelessWidget {
  final String     number;
  final String     title;
  final StepStatus status;
  final Widget     child;

  const StepCard({
    super.key,
    required this.number,
    required this.title,
    required this.status,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final (borderColor, badgeColor, badgeText) = switch (status) {
      StepStatus.active => (AppTheme.teal,      AppTheme.teal,      AppTheme.background),
      StepStatus.done   => (AppTheme.tealDim,   AppTheme.tealDim,   AppTheme.tealText),
      StepStatus.error  => (AppTheme.coral,     AppTheme.coralDim,  AppTheme.coralText),
      StepStatus.idle   => (AppTheme.border,    AppTheme.surfaceHigh, AppTheme.textTertiary),
    };

    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: borderColor, width: 0.8),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color:        badgeColor,
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                status == StepStatus.done ? '✓' : number,
                style: AppTheme.mono(size: 11, color: badgeText,
                    weight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            Text(title,
                style: AppTheme.sans(
                    size: 13,
                    weight: FontWeight.w600,
                    color: status == StepStatus.idle
                        ? AppTheme.textSecondary
                        : AppTheme.textPrimary)),
          ]),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

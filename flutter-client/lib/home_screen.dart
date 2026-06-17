// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import 'models/device_history.dart';
import 'ota/nus_ota_service.dart';
import 'ota/ota_provider.dart';
import 'theme/app_theme.dart';
import 'widgets/device_tile.dart';
import 'widgets/status_bar.dart';
import 'widgets/step_card.dart';
import 'widgets/sweep_arc.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showHistory = false;   // toggle between history list and scan results
  bool _showSettings = false;  // token / version settings panel

  final _tokenCtrl   = TextEditingController();
  final _versionCtrl = TextEditingController();

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _versionCtrl.dispose();
    super.dispose();
  }

  // ── Step status helpers ──────────────────────────────────────────────

  StepStatus _deviceStep(OtaProvider ota) {
    if (ota.busy) return StepStatus.done;
    if (ota.progress.state == OtaState.done) return StepStatus.done;
    if (ota.device != null) return StepStatus.active;
    return StepStatus.idle;
  }

  StepStatus _fileStep(OtaProvider ota) {
    if (ota.busy) return StepStatus.done;
    if (ota.progress.state == OtaState.done) return StepStatus.done;
    if (ota.fileReady) return StepStatus.active;
    return StepStatus.idle;
  }

  StepStatus _transferStep(OtaProvider ota) {
    if (ota.progress.state == OtaState.error) return StepStatus.error;
    if (ota.progress.state == OtaState.done)  return StepStatus.done;
    if (ota.busy) return StepStatus.active;
    return StepStatus.idle;
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ota     = context.watch<OtaProvider>();
    final history = context.watch<DeviceHistory>();
    final prog    = ota.progress;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: _buildAppBar(ota),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [

                // ── Sweep arc ─────────────────────────────────────────
                Center(child: SweepArc(progress: prog)),
                const SizedBox(height: 20),

                // ── Step 1 — Device ───────────────────────────────────
                StepCard(
                  number: '1',
                  title:  'Select device',
                  status: _deviceStep(ota),
                  child:  _DeviceSection(
                    ota:          ota,
                    history:      history,
                    showHistory:  _showHistory,
                    onToggleView: () =>
                        setState(() => _showHistory = !_showHistory),
                  ),
                ),
                const SizedBox(height: 12),

                // ── Step 2 — File ─────────────────────────────────────
                StepCard(
                  number: '2',
                  title:  'Select .py file',
                  status: _fileStep(ota),
                  child:  _FileSection(ota: ota),
                ),
                const SizedBox(height: 12),

                // ── Step 3 — Transfer ─────────────────────────────────
                StepCard(
                  number: '3',
                  title:  'Transfer',
                  status: _transferStep(ota),
                  child:  _TransferSection(
                    ota:         ota,
                    tokenCtrl:   _tokenCtrl,
                    versionCtrl: _versionCtrl,
                    showSettings: _showSettings,
                    onToggleSettings: () =>
                        setState(() => _showSettings = !_showSettings),
                  ),
                ),

              ],
            ),
          ),

          // ── Status bar ────────────────────────────────────────────────
          const Divider(height: 1),
          StatusBar(progress: prog),
        ],
      ),
    );
  }

  AppBar _buildAppBar(OtaProvider ota) => AppBar(
    backgroundColor: AppTheme.surface,
    elevation: 0,
    centerTitle: false,
    title: Row(children: [
      const Icon(Icons.bluetooth, size: 18, color: AppTheme.tealText),
      const SizedBox(width: 8),
      Text('esp32-nus-ota',
          style: AppTheme.mono(size: 14, color: AppTheme.textPrimary,
              weight: FontWeight.w600)),
    ]),
    bottom: PreferredSize(
      preferredSize: const Size.fromHeight(1),
      child: Container(height: 0.5, color: AppTheme.border),
    ),
    actions: [
      if (ota.busy)
        TextButton(
          onPressed: ota.abort,
          child: Text('ABORT',
              style: AppTheme.mono(size: 11, color: AppTheme.coralText)),
        ),
      const SizedBox(width: 8),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 1 — Device section
// ─────────────────────────────────────────────────────────────────────────────

class _DeviceSection extends StatelessWidget {
  final OtaProvider    ota;
  final DeviceHistory  history;
  final bool           showHistory;
  final VoidCallback   onToggleView;

  const _DeviceSection({
    required this.ota,
    required this.history,
    required this.showHistory,
    required this.onToggleView,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [

        // ── Toggle bar ─────────────────────────────────────────────────
        Row(children: [
          _ToggleChip(
            label:    'Scan',
            selected: !showHistory,
            onTap:    onToggleView,
          ),
          const SizedBox(width: 8),
          _ToggleChip(
            label:    'History (${history.records.length})',
            selected: showHistory,
            onTap:    onToggleView,
          ),
        ]),
        const SizedBox(height: 10),

        // ── Permission error ───────────────────────────────────────────
        if (ota.permissionError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color:        AppTheme.coralDim,
              borderRadius: BorderRadius.circular(8),
              border:       Border.all(color: AppTheme.coral, width: 0.8),
            ),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 14, color: AppTheme.coralText),
              const SizedBox(width: 8),
              Expanded(child: Text(
                ota.permissionError!,
                style: AppTheme.mono(size: 11, color: AppTheme.coralText),
              )),
              GestureDetector(
                onTap: () => openAppSettings(),
                child: Text('Settings',
                    style: AppTheme.mono(size: 11, color: AppTheme.amberText)),
              ),
            ]),
          ),

        // ── Scan panel ─────────────────────────────────────────────────
        if (!showHistory) ...[
          OutlinedButton.icon(
            onPressed: ota.busy || ota.scanning ? null : ota.startScan,
            icon: ota.scanning
                ? const SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search, size: 16),
            label: Text(ota.scanning ? 'Scanning for NUS devices…' : 'Scan',
                style: AppTheme.sans(size: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.tealText,
              side: const BorderSide(color: AppTheme.border),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
          if (ota.scanResults.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...ota.scanResults.map((d) {
              final rec = history.records
                  .where((r) => r.remoteId == d.remoteId.toString())
                  .firstOrNull;
              return DeviceTile(
                device:   d,
                selected: ota.device?.remoteId == d.remoteId,
                history:  rec,
                onTap:    () => ota.selectDevice(d),
              );
            }),
          ] else if (!ota.scanning)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('No devices found — tap Scan',
                  style: AppTheme.mono(size: 11, color: AppTheme.textTertiary)),
            ),
        ],

        // ── History panel ──────────────────────────────────────────────
        if (showHistory) ...[
          if (history.records.isEmpty)
            Text('No history yet — scan and connect to a device first',
                style: AppTheme.mono(size: 11, color: AppTheme.textTertiary))
          else
            ...history.records.map((rec) => HistoryTile(
              record:   rec,
              selected: ota.device?.remoteId.toString() == rec.remoteId,
              onTap:    () {
                // Create a BluetoothDevice from the stored address
                final d = BluetoothDevice(
                  remoteId: DeviceIdentifier(rec.remoteId));
                ota.selectDevice(d);
              },
              onDelete: () => history.remove(rec.remoteId),
            )),
        ],

        // ── Selected device summary ────────────────────────────────────
        if (ota.device != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color:        AppTheme.tealDim,
              borderRadius: BorderRadius.circular(6),
              border:       Border.all(color: AppTheme.teal, width: 0.5),
            ),
            child: Row(children: [
              const Icon(Icons.check_circle_outline,
                  size: 14, color: AppTheme.tealText),
              const SizedBox(width: 6),
              Expanded(child: Text(
                ota.device!.platformName.isNotEmpty
                    ? ota.device!.platformName
                    : ota.device!.remoteId.toString(),
                style: AppTheme.mono(size: 11, color: AppTheme.tealText),
                overflow: TextOverflow.ellipsis,
              )),
            ]),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 2 — File section
// ─────────────────────────────────────────────────────────────────────────────

class _FileSection extends StatelessWidget {
  final OtaProvider ota;
  const _FileSection({required this.ota});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: ota.fileName != null
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ota.fileName!,
                    style: AppTheme.mono(size: 12, color: AppTheme.tealText,
                        weight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ])
            : Text('No file chosen',
                style: AppTheme.mono(
                    size: 12, color: AppTheme.textTertiary)),
      ),
      const SizedBox(width: 12),
      OutlinedButton(
        onPressed: ota.busy ? null : () => _pick(context),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.textPrimary,
          side: const BorderSide(color: AppTheme.border),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        child: Text('Browse', style: AppTheme.sans(size: 13)),
      ),
    ]);
  }

  Future<void> _pick(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['py'],
      withData: true,
    );
    if (result == null || !context.mounted) return;
    final f = result.files.first;
    if (f.bytes == null) return;
    context.read<OtaProvider>().setFile(
        f.name, Uint8List.fromList(f.bytes!));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 3 — Transfer section
// ─────────────────────────────────────────────────────────────────────────────

class _TransferSection extends StatelessWidget {
  final OtaProvider        ota;
  final TextEditingController tokenCtrl;
  final TextEditingController versionCtrl;
  final bool               showSettings;
  final VoidCallback        onToggleSettings;

  const _TransferSection({
    required this.ota,
    required this.tokenCtrl,
    required this.versionCtrl,
    required this.showSettings,
    required this.onToggleSettings,
  });

  @override
  Widget build(BuildContext context) {
    final prog = ota.progress;
    final busy = ota.busy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [

        // ── Progress bar ───────────────────────────────────────────────
        if (prog.state == OtaState.transferring ||
            prog.state == OtaState.committing) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value:           prog.fraction,
              minHeight:       6,
              backgroundColor: AppTheme.border,
              valueColor: AlwaysStoppedAnimation(
                prog.state == OtaState.committing
                    ? AppTheme.purple
                    : AppTheme.teal,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${prog.chunksAcked} / ${prog.totalChunks} chunks'
                '  ·  ${(prog.fraction * 100).toStringAsFixed(1)} %',
                style: AppTheme.mono(size: 10, color: AppTheme.textTertiary),
              ),
              Text('${prog.kbps.toStringAsFixed(1)} kB/s',
                  style: AppTheme.mono(size: 10, color: AppTheme.amberText)),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // ── Result messages ────────────────────────────────────────────
        if (prog.state == OtaState.done)
          _ResultBanner(
            color: AppTheme.tealDim,
            border: AppTheme.teal,
            icon: Icons.check_circle_outline,
            iconColor: AppTheme.tealText,
            text: 'Update complete — device is rebooting',
            textColor: AppTheme.tealText,
          ),

        if (prog.state == OtaState.error)
          _ResultBanner(
            color: AppTheme.coralDim,
            border: AppTheme.coral,
            icon: Icons.error_outline,
            iconColor: AppTheme.coralText,
            text: prog.errorMessage ?? 'Unknown error',
            textColor: AppTheme.coralText,
          ),

        // ── Settings toggle ────────────────────────────────────────────
        GestureDetector(
          onTap: onToggleSettings,
          child: Row(children: [
            Text('Advanced settings',
                style: AppTheme.mono(size: 11, color: AppTheme.textTertiary)),
            const SizedBox(width: 4),
            Icon(
              showSettings
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 14, color: AppTheme.textTertiary,
            ),
          ]),
        ),

        if (showSettings) ...[
          const SizedBox(height: 10),
          _SettingsField(
            controller: tokenCtrl,
            label:      'Auth token',
            hint:       'leave blank if disabled',
          ),
          const SizedBox(height: 8),
          _SettingsField(
            controller: versionCtrl,
            label:      'Version (optional)',
            hint:       '1.2.3',
          ),
        ],

        const SizedBox(height: 14),

        // ── Start / Reset buttons ──────────────────────────────────────
        if (ota.finished) ...[
          // After done or error — show a prominent Reset button so the
          // user can start a new transfer without restarting the app.
          // Device and file selection are preserved.
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => context.read<OtaProvider>().reset(),
                icon: const Icon(Icons.refresh, size: 16),
                label: Text('New transfer',
                    style: AppTheme.sans(size: 14, weight: FontWeight.w600,
                        color: AppTheme.background)),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal,
                  foregroundColor: AppTheme.background,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ]),
        ] else
          FilledButton(
            onPressed: ota.canStart && !busy
                ? () => _start(context)
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.teal,
              foregroundColor: AppTheme.background,
              disabledBackgroundColor: AppTheme.border,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: busy
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.tealText)),
                      const SizedBox(width: 10),
                      Text(_busyLabel(prog.state),
                          style: AppTheme.sans(size: 14, color: AppTheme.tealText)),
                    ],
                  )
                : Text('Start update',
                    style: AppTheme.sans(
                        size: 14, weight: FontWeight.w600,
                        color: AppTheme.background)),
          ),
      ],
    );
  }

  String _busyLabel(OtaState s) => switch (s) {
    OtaState.connecting  => 'Connecting…',
    OtaState.handshaking => 'Handshaking…',
    OtaState.transferring=> 'Transferring…',
    OtaState.committing  => 'Committing…',
    _ => 'Working…',
  };

  Future<void> _start(BuildContext context) async {
    try {
      await context.read<OtaProvider>().startOta(
        token:   tokenCtrl.text.trim().isEmpty ? null : tokenCtrl.text.trim(),
        version: versionCtrl.text.trim().isEmpty ? null : versionCtrl.text.trim(),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString(),
              style: AppTheme.mono(size: 12, color: AppTheme.coralText)),
          backgroundColor: AppTheme.coralDim,
        ));
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small shared widgets
// ─────────────────────────────────────────────────────────────────────────────

class _ToggleChip extends StatelessWidget {
  final String     label;
  final bool       selected;
  final VoidCallback onTap;
  const _ToggleChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color:        selected ? AppTheme.tealDim : AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected ? AppTheme.teal : AppTheme.border,
          width: 0.8,
        ),
      ),
      child: Text(label,
          style: AppTheme.mono(
              size: 11,
              color: selected ? AppTheme.tealText : AppTheme.textTertiary)),
    ),
  );
}

class _ResultBanner extends StatelessWidget {
  final Color    color, border, iconColor, textColor;
  final IconData icon;
  final String   text;
  const _ResultBanner({
    required this.color, required this.border,
    required this.icon,  required this.iconColor,
    required this.text,  required this.textColor,
  });

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color:        color,
      borderRadius: BorderRadius.circular(8),
      border:       Border.all(color: border, width: 0.8),
    ),
    child: Row(children: [
      Icon(icon, size: 16, color: iconColor),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
          style: AppTheme.mono(size: 11, color: textColor))),
    ]),
  );
}

class _SettingsField extends StatelessWidget {
  final TextEditingController controller;
  final String label, hint;
  const _SettingsField({required this.controller, required this.label, required this.hint});

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    style: AppTheme.mono(size: 12, color: AppTheme.textPrimary),
    decoration: InputDecoration(
      labelText:     label,
      hintText:      hint,
      labelStyle:    AppTheme.mono(size: 11, color: AppTheme.textTertiary),
      hintStyle:     AppTheme.mono(size: 11, color: AppTheme.textTertiary),
      filled:        true,
      fillColor:     AppTheme.surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppTheme.border, width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppTheme.border, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppTheme.teal, width: 1),
      ),
    ),
  );
}

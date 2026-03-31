import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import 'nus_ota_service.dart';
import 'ota_provider.dart';

/// Full-screen OTA UI.
///
/// Pass [connectedDevice] if you are already connected via your app's
/// existing BLE code — the OTA service will reuse the connection and
/// will NOT disconnect when finished.
///
/// Omit [connectedDevice] (or pass null) to let the screen handle its
/// own scan → connect → disconnect lifecycle.
class OtaScreen extends StatelessWidget {
  final BluetoothDevice? connectedDevice;
  const OtaScreen({super.key, this.connectedDevice});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => OtaProvider(),
      child: _OtaBody(connectedDevice: connectedDevice),
    );
  }
}

// ---------------------------------------------------------------------------

class _OtaBody extends StatefulWidget {
  final BluetoothDevice? connectedDevice;
  const _OtaBody({this.connectedDevice});

  @override
  State<_OtaBody> createState() => _OtaBodyState();
}

class _OtaBodyState extends State<_OtaBody> {
  // If no device passed in, show a simple scan-and-pick list
  BluetoothDevice?       _pickedDevice;
  List<BluetoothDevice>  _scanned = [];
  bool                   _scanning = false;

  BluetoothDevice? get _activeDevice =>
      widget.connectedDevice ?? _pickedDevice;

  bool get _usingExistingConnection => widget.connectedDevice != null;

  @override
  Widget build(BuildContext context) {
    final ota  = context.watch<OtaProvider>();
    final prog = ota.progress;
    final busy = _isBusy(prog.state);

    return Scaffold(
      appBar: AppBar(
        title: const Text("OTA firmware update"),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [

          // ── Connected device banner ────────────────────────────────
          if (_usingExistingConnection)
            _InfoBanner(
              icon: Icons.bluetooth_connected,
              text: "Using existing connection to "
                    "${widget.connectedDevice!.platformName.isNotEmpty
                        ? widget.connectedDevice!.platformName
                        : widget.connectedDevice!.remoteId.toString()}",
            )
          else ...[
            _StepCard(
              step: "1",
              title: "Select device",
              child: _DevicePickerSection(
                scanned:  _scanned,
                picked:   _pickedDevice,
                scanning: _scanning,
                busy:     busy,
                onScan:   _startScan,
                onPick:   (d) => setState(() => _pickedDevice = d),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // ── File picker ────────────────────────────────────────────
          _StepCard(
            step: _usingExistingConnection ? "1" : "2",
            title: "Select .py file",
            child: _FilePickerSection(busy: busy),
          ),

          const SizedBox(height: 12),

          // ── Transfer ───────────────────────────────────────────────
          _StepCard(
            step: _usingExistingConnection ? "2" : "3",
            title: "Update",
            child: _TransferSection(
              progress:  prog,
              busy:      busy,
              canStart:  _activeDevice != null && ota.fileReady,
              onStart:   () => _startOta(ota),
              onAbort:   ota.abort,
            ),
          ),

        ],
      ),
    );
  }

  bool _isBusy(OtaState s) =>
      s != OtaState.idle && s != OtaState.done && s != OtaState.error;

  Future<void> _startScan() async {
    setState(() { _scanning = true; _scanned = []; });
    final stream = FlutterBluePlus.startScan(
      withServices: [Guid("6e400001-b5a3-f393-e0a9-e50e24dcca9e")],
      timeout: const Duration(seconds: 8),
    );
    FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          if (!_scanned.any((d) => d.remoteId == r.device.remoteId)) {
            _scanned.add(r.device);
          }
        }
      });
    });
    await Future.delayed(const Duration(seconds: 8));
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _startOta(OtaProvider ota) async {
    final device = _activeDevice!;
    try {
      if (_usingExistingConnection) {
        await ota.startOtaOnConnected(device: device);
      } else {
        await ota.startOta(device: device);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("OTA failed: $e"),
                   backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Sub-sections
// ---------------------------------------------------------------------------

class _DevicePickerSection extends StatelessWidget {
  final List<BluetoothDevice> scanned;
  final BluetoothDevice?      picked;
  final bool scanning, busy;
  final VoidCallback onScan;
  final ValueChanged<BluetoothDevice> onPick;

  const _DevicePickerSection({
    required this.scanned, required this.picked,
    required this.scanning, required this.busy,
    required this.onScan, required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: busy || scanning ? null : onScan,
          icon: scanning
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.search, size: 18),
          label: Text(scanning ? "Scanning…" : "Scan for NUS devices"),
        ),
        if (scanned.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...scanned.map((d) {
            final name = d.platformName.isNotEmpty
                ? d.platformName : d.remoteId.toString();
            final selected = picked?.remoteId == d.remoteId;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bluetooth,
                  color: selected
                      ? Theme.of(context).colorScheme.primary : null),
              title: Text(name),
              subtitle: Text(d.remoteId.toString(),
                  style: Theme.of(context).textTheme.bodySmall),
              selected: selected,
              onTap: () => onPick(d),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            );
          }),
        ],
      ],
    );
  }
}

class _FilePickerSection extends StatelessWidget {
  final bool busy;
  const _FilePickerSection({required this.busy});

  @override
  Widget build(BuildContext context) {
    final ota = context.watch<OtaProvider>();
    return Row(
      children: [
        Expanded(
          child: Text(
            ota.fileName ?? "No file chosen",
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: ota.fileName != null
                  ? null : Theme.of(context).hintColor,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.tonal(
          onPressed: busy ? null : () => _pick(context),
          child: const Text("Browse"),
        ),
      ],
    );
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

class _TransferSection extends StatelessWidget {
  final OtaProgress progress;
  final bool busy, canStart;
  final VoidCallback onStart, onAbort;

  const _TransferSection({
    required this.progress, required this.busy,
    required this.canStart, required this.onStart,
    required this.onAbort,
  });

  @override
  Widget build(BuildContext context) {
    final prog = progress;
    final cs   = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [

        // Progress bar
        if (prog.state == OtaState.transferring ||
            prog.state == OtaState.committing) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: prog.fraction,
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "${prog.chunksAcked}/${prog.totalChunks} chunks  "
                "·  ${(prog.fraction * 100).toStringAsFixed(1)}%",
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                "${prog.kbps.toStringAsFixed(1)} kB/s",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],

        // Indeterminate bar for commit phase
        if (prog.state == OtaState.committing)
          const LinearProgressIndicator(),

        // Status label
        if (prog.state != OtaState.idle) ...[
          const SizedBox(height: 6),
          Text(
            _label(prog),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: switch (prog.state) {
                OtaState.error => cs.error,
                OtaState.done  => Colors.green,
                _              => cs.primary,
              },
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
        ],

        // Buttons
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: canStart && !busy ? onStart : null,
                child: busy
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          SizedBox(width: 14, height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white)),
                          SizedBox(width: 8),
                          Text("Updating…"),
                        ],
                      )
                    : const Text("Start update"),
              ),
            ),
            if (busy) ...[
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: onAbort,
                child: const Text("Abort"),
              ),
            ],
          ],
        ),
      ],
    );
  }

  String _label(OtaProgress p) => switch (p.state) {
    OtaState.connecting   => "Connecting to device…",
    OtaState.handshaking  => "Handshaking…",
    OtaState.transferring => "Sending file…",
    OtaState.committing   => "Verifying & committing…",
    OtaState.done         => "Done — device is rebooting",
    OtaState.error        => "Error: ${p.errorMessage ?? 'unknown'}",
    _                     => "",
  };
}

// ---------------------------------------------------------------------------
// Utility widgets
// ---------------------------------------------------------------------------

class _StepCard extends StatelessWidget {
  final String step, title;
  final Widget child;
  const _StepCard({required this.step, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(step,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    )),
              ),
              const SizedBox(width: 8),
              Text(title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String   text;
  const _InfoBanner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color:        cs.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: cs.onSecondaryContainer),
        const SizedBox(width: 8),
        Expanded(child: Text(text,
            style: TextStyle(fontSize: 13, color: cs.onSecondaryContainer))),
      ]),
    );
  }
}

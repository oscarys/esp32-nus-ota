import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ---------------------------------------------------------------------------
// NUS UUIDs — must match your ESP32 firmware
// ---------------------------------------------------------------------------
const _kNusService = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
const _kNusRx      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; // phone → ESP32
const _kNusTx      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"; // ESP32 → phone

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
enum OtaState { idle, connecting, handshaking, transferring, committing, done, error }

class OtaProgress {
  final OtaState state;
  final int      bytesSent;
  final int      totalBytes;
  final int      chunksAcked;
  final int      totalChunks;
  final double   kbps;
  final String?  errorMessage;

  const OtaProgress({
    this.state        = OtaState.idle,
    this.bytesSent    = 0,
    this.totalBytes   = 0,
    this.chunksAcked  = 0,
    this.totalChunks  = 0,
    this.kbps         = 0.0,
    this.errorMessage,
  });

  double get fraction => totalBytes > 0 ? bytesSent / totalBytes : 0.0;

  OtaProgress copyWith({
    OtaState? state,
    int?      bytesSent,
    int?      totalBytes,
    int?      chunksAcked,
    int?      totalChunks,
    double?   kbps,
    String?   errorMessage,
  }) => OtaProgress(
    state:        state        ?? this.state,
    bytesSent:    bytesSent    ?? this.bytesSent,
    totalBytes:   totalBytes   ?? this.totalBytes,
    chunksAcked:  chunksAcked  ?? this.chunksAcked,
    totalChunks:  totalChunks  ?? this.totalChunks,
    kbps:         kbps         ?? this.kbps,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

// ---------------------------------------------------------------------------
// NusOtaService
// ---------------------------------------------------------------------------
class NusOtaService {
  // Chunk = bytes of raw file data per packet.
  // Hex-encoded on the wire → multiply by 2 for actual BLE payload size.
  // 88 bytes → 176-char payload — safe even before MTU negotiation.
  // Bump to 180 after confirming requestMtu(512) succeeds on your devices.
  static const int _kDefaultChunk  = 88;
  static const int _kAckTimeoutMs  = 8000;
  static const int _kMaxRetries    = 5;

  final _progressCtrl = StreamController<OtaProgress>.broadcast();
  Stream<OtaProgress> get progress => _progressCtrl.stream;

  OtaProgress _prog = const OtaProgress();

  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;
  StreamSubscription?      _notifySub;
  final _replier = _Replier();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Use this when you are NOT already connected — service will connect first.
  Future<void> runOta({
    required BluetoothDevice device,
    required String          filename,
    required Uint8List       fileBytes,
    int      chunkSize = _kDefaultChunk,
    String?  version,
    String?  token,
  }) async {
    try {
      _emit(state: OtaState.connecting);
      await _connectAndNegotiate(device);
      await _discoverNus(device);
      await _runTransfer(
        device:    device,
        filename:  filename,
        fileBytes: fileBytes,
        chunkSize: chunkSize,
        version:   version,
        token:     token,
      );
    } catch (e) {
      _emit(state: OtaState.error, errorMessage: e.toString());
      rethrow;
    } finally {
      await _teardown(device, disconnect: true);
    }
  }

  /// Use this when you are ALREADY connected via your existing BLE code.
  /// Pass the live BluetoothDevice — no reconnect, no disconnect on finish.
  Future<void> runOtaOnConnected({
    required BluetoothDevice device,
    required String          filename,
    required Uint8List       fileBytes,
    int      chunkSize = _kDefaultChunk,
    String?  version,
    String?  token,
  }) async {
    try {
      // MTU bump only — skip connect()
      try { await device.requestMtu(512); } catch (_) {}
      await _discoverNus(device);
      await _runTransfer(
        device:    device,
        filename:  filename,
        fileBytes: fileBytes,
        chunkSize: chunkSize,
        version:   version,
        token:     token,
      );
    } catch (e) {
      _emit(state: OtaState.error, errorMessage: e.toString());
      rethrow;
    } finally {
      // Don't disconnect — caller owns the connection
      await _teardown(device, disconnect: false);
    }
  }

  Future<void> abort() async {
    try { await _sendLine("OTA:ABORT"); } catch (_) {}
    _emit(state: OtaState.idle);
  }

  void dispose() {
    _notifySub?.cancel();
    _progressCtrl.close();
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<void> _connectAndNegotiate(BluetoothDevice device) async {
    if (!device.isConnected) {
      await device.connect(
        timeout:     const Duration(seconds: 15),
        autoConnect: false,
      );
    }
    try { await device.requestMtu(512); } catch (_) {}
  }

  Future<void> _discoverNus(BluetoothDevice device) async {
    // Re-use cached services if already discovered
    List<BluetoothService> services = device.servicesList;
    if (services.isEmpty) {
      services = await device.discoverServices();
    }

    for (final svc in services) {
      if (svc.uuid.toString().toLowerCase() != _kNusService) continue;
      for (final c in svc.characteristics) {
        final uuid = c.uuid.toString().toLowerCase();
        if (uuid == _kNusRx) _rx = c;
        if (uuid == _kNusTx) _tx = c;
      }
    }

    if (_rx == null || _tx == null) {
      throw Exception(
        "NUS characteristics not found.\n"
        "Check that your ESP32 is advertising the NUS service UUID."
      );
    }

    await _tx!.setNotifyValue(true);
    _notifySub?.cancel();
    _notifySub = _tx!.onValueReceived.listen((data) {
      final line = utf8.decode(data, allowMalformed: true).trim();
      if (line.startsWith("OTA:")) _replier.deliver(line);
    });
  }

  // ---------------------------------------------------------------------------
  // Transfer orchestration
  // ---------------------------------------------------------------------------

  Future<void> _runTransfer({
    required BluetoothDevice device,
    required String          filename,
    required Uint8List       fileBytes,
    required int             chunkSize,
    String?  version,
    String?  token,
  }) async {
    await _handshake(filename, fileBytes, chunkSize, version, token);
    await _transferChunks(fileBytes, chunkSize);
    await _commit();
    _emit(state: OtaState.done);
  }

  Future<void> _handshake(
    String filename, Uint8List bytes,
    int chunkSize, String? version, String? token,
  ) async {
    _emit(state: OtaState.handshaking);

    final crc     = _crc32(bytes);
    final size    = bytes.length;
    final nChunks = (size / chunkSize).ceil();

    // Build OTA:START command
    var cmd = "OTA:START:$filename:$size:${crc.toRadixString(16).padLeft(8, '0')}";
    if (version != null) {
      cmd += ":$version";
    } else if (token != null) {
      cmd += ":0.0.0";           // placeholder version slot
    }
    if (token != null) cmd += ":$token";

    await _sendLine(cmd);
    final reply = await _replier.next(timeoutMs: 10000);

    if (!reply.startsWith("OTA:READY")) {
      throw Exception("Device rejected OTA start: $reply");
    }

    _emit(
      state:       OtaState.transferring,
      totalBytes:  size,
      totalChunks: nChunks,
    );
  }

  Future<void> _transferChunks(Uint8List bytes, int chunkSize) async {
    final total   = bytes.length;
    int   offset  = 0;
    int   seq     = 0;
    final tStart  = DateTime.now();

    while (offset < total) {
      final end   = (offset + chunkSize).clamp(0, total);
      final chunk = bytes.sublist(offset, end);
      final hex   = _hexEncode(chunk);
      final pkt   = "OTA:DATA:$seq:$hex";

      int retries = 0;
      while (retries < _kMaxRetries) {
        await _sendLine(pkt);
        try {
          final reply = await _replier.next(timeoutMs: _kAckTimeoutMs);
          if (reply == "OTA:ACK:$seq") break;           // success
          if (reply == "OTA:ACK:${seq - 1}") break;     // duplicate ACK — already done
          retries++;
        } on TimeoutException {
          retries++;
        }
      }

      if (retries >= _kMaxRetries) {
        throw Exception("Too many retries on chunk $seq — aborting.");
      }

      offset += chunk.length;
      seq++;

      final elapsedMs = DateTime.now().difference(tStart).inMilliseconds;
      final kbps      = elapsedMs > 0 ? (offset / 1024) / (elapsedMs / 1000) : 0.0;

      _emit(
        bytesSent:   offset,
        chunksAcked: seq,
        kbps:        kbps,
      );
    }
  }

  Future<void> _commit() async {
    _emit(state: OtaState.committing);
    await _sendLine("OTA:COMMIT");
    try {
      final reply = await _replier.next(timeoutMs: 15000);
      if (!reply.startsWith("OTA:OK")) {
        throw Exception("Commit failed: $reply");
      }
    } on TimeoutException {
      // Device likely already reset before OTA:OK drained — treat as success
    }
  }

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  Future<void> _sendLine(String text) async {
    final payload = Uint8List.fromList(utf8.encode("$text\n"));
    // BLE write-without-response; split defensively at 512 bytes
    const mtu = 512;
    for (int i = 0; i < payload.length; i += mtu) {
      final slice = payload.sublist(i, (i + mtu).clamp(0, payload.length));
      await _rx!.write(slice, withoutResponse: true);
    }
  }

  Future<void> _teardown(BluetoothDevice device, {required bool disconnect}) async {
    _notifySub?.cancel();
    _notifySub = null;
    _rx = _tx = null;
    if (disconnect) {
      try { await device.disconnect(); } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // CRC32 — identical output to Python binascii.crc32()
  // ---------------------------------------------------------------------------
  static final _table = _buildTable();

  static List<int> _buildTable() {
    final t = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int j = 0; j < 8; j++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      t[i] = c;
    }
    return t;
  }

  static int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = _table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static String _hexEncode(Uint8List data) {
    final sb = StringBuffer();
    for (final b in data) sb.write(b.toRadixString(16).padLeft(2, '0'));
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // Emit
  // ---------------------------------------------------------------------------
  void _emit({
    OtaState? state,
    int?      bytesSent,
    int?      totalBytes,
    int?      chunksAcked,
    int?      totalChunks,
    double?   kbps,
    String?   errorMessage,
  }) {
    _prog = _prog.copyWith(
      state:        state,
      bytesSent:    bytesSent,
      totalBytes:   totalBytes,
      chunksAcked:  chunksAcked,
      totalChunks:  totalChunks,
      kbps:         kbps,
      errorMessage: errorMessage,
    );
    if (!_progressCtrl.isClosed) _progressCtrl.add(_prog);
  }
}

// ---------------------------------------------------------------------------
// _Replier — delivers the next OTA reply to whoever is await-ing it
// ---------------------------------------------------------------------------
class _Replier {
  Completer<String>? _pending;

  /// Await the next OTA:* line from the device.
  Future<String> next({required int timeoutMs}) {
    _pending = Completer<String>();
    return _pending!.future.timeout(
      Duration(milliseconds: timeoutMs),
      onTimeout: () => throw TimeoutException("BLE reply timeout"),
    );
  }

  /// Called by the notification listener when a line arrives.
  void deliver(String line) {
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.complete(line);
    }
  }
}

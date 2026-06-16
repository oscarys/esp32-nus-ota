# flutter-client/

Android OTA client app. Targets Android 6.0+ (API 23+).

## Setup

```bash
flutter pub get
```

Add permissions to `android/app/src/main/AndroidManifest.xml` — see `android_setup.md` in docs.

## Integration

```dart
// Already connected via your existing BLE code:
Navigator.push(context, MaterialPageRoute(
  builder: (_) => OtaScreen(connectedDevice: yourBluetoothDevice),
));

// Or let OTA manage its own scan/connect:
Navigator.push(context, MaterialPageRoute(
  builder: (_) => const OtaScreen(),
));
```

## Run tests

```bash
flutter test
```

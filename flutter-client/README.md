# flutter-client/

Android OTA client app built with Flutter.
Targets Android 6.0+ (API 23+).

## Setup

### 1. Dependencies

```bash
flutter pub get
```

### 2. Android permissions

Add to `android/app/src/main/AndroidManifest.xml` inside `<manifest>`:

```xml
<!-- Android 12+ -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Android 6–11 -->
<uses-permission android:name="android.permission.BLUETOOTH"
    android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
    android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    android:maxSdkVersion="30" />

<!-- File picker -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
```

Set `minSdkVersion 21` in `android/app/build.gradle`.

### 3. Build and run

```bash
flutter run
```

## Integration

### Already connected to your ESP32

```dart
import 'lib/ota/ota_screen.dart';

// Pass your existing BluetoothDevice — OTA reuses the connection
// and will NOT disconnect when finished.
Navigator.push(context, MaterialPageRoute(
  builder: (_) => OtaScreen(connectedDevice: yourBluetoothDevice),
));
```

### Let OTA manage its own connection

```dart
// Omit connectedDevice — the screen handles scan → connect → disconnect.
Navigator.push(context, MaterialPageRoute(
  builder: (_) => const OtaScreen(),
));
```

## File structure

```
lib/ota/
  nus_ota_service.dart   BLE logic + OTA protocol state machine
  ota_provider.dart      ChangeNotifier for state management
  ota_screen.dart        Ready-to-use OTA UI screen
```

## Run tests

```bash
flutter test
```

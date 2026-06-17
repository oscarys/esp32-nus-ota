# flutter-client/

Full Android Flutter app for ESP32 NUS-based OTA updates.

## Architecture

```
lib/
  main.dart                    App entry point, providers, theme setup
  home_screen.dart             Single-screen UI
  theme/
    app_theme.dart             Dark instrumentation theme (palette, typography)
  models/
    device_record.dart         BLE device + last-used-file record
    device_history.dart        SharedPreferences-backed device history
  ota/
    nus_ota_service.dart       BLE logic + OTA protocol state machine
    ota_provider.dart          ChangeNotifier — scan, file, transfer state
  widgets/
    sweep_arc.dart             Animated circular progress arc (signature element)
    step_card.dart             Numbered step card with status colouring
    status_bar.dart            Persistent bottom status strip
    device_tile.dart           Scan result and history list tiles
```

## Setup

### 1. Install dependencies

```bash
flutter pub get
```

### 2. Android minimum SDK

In `android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        minSdkVersion 21
    }
}
```

### 3. Run

```bash
flutter run
```

## Integrating into an existing app

To use just the OTA screen in an existing Flutter app with BLE already set up:

```dart
import 'package:esp32_nus_ota/home_screen.dart';
import 'package:esp32_nus_ota/models/device_history.dart';
import 'package:esp32_nus_ota/ota/ota_provider.dart';

// Navigate to the OTA screen:
Navigator.push(context, MaterialPageRoute(
  builder: (_) => MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => DeviceHistory()..load()),
      ChangeNotifierProxyProvider<DeviceHistory, OtaProvider>(
        create:  (ctx) => OtaProvider(history: ctx.read()),
        update:  (ctx, hist, prev) => prev ?? OtaProvider(history: hist),
      ),
    ],
    child: const HomeScreen(),
  ),
));
```

## Run tests

```bash
flutter test
```

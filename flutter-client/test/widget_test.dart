// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:esp32_nus_ota/main.dart';
import 'package:esp32_nus_ota/models/device_history.dart';
import 'package:esp32_nus_ota/ota/ota_provider.dart';

void main() {
  late DeviceHistory history;

  setUp(() {
    history = DeviceHistory();   // not loaded from prefs — empty, fine for tests
  });

  testWidgets('App renders HomeScreen without crashing', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DeviceHistory>.value(value: history),
          ChangeNotifierProvider<OtaProvider>(
            create: (_) => OtaProvider(history: history),
          ),
        ],
        child: const NusOtaApp(),
      ),
    );
    expect(find.text('esp32-nus-ota'),   findsOneWidget);
    expect(find.text('Select device'),   findsOneWidget);
    expect(find.text('Select .py file'), findsOneWidget);
    expect(find.text('Transfer'),        findsOneWidget);
  });

  testWidgets('Start update button disabled when no device or file selected',
      (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DeviceHistory>.value(value: history),
          ChangeNotifierProvider<OtaProvider>(
            create: (_) => OtaProvider(history: history),
          ),
        ],
        child: const NusOtaApp(),
      ),
    );
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start update'));
    expect(btn.onPressed, isNull);
  });
}

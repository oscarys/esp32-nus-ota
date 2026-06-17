// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'home_screen.dart';
import 'models/device_history.dart';
import 'ota/ota_provider.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor:                    Colors.transparent,
    statusBarIconBrightness:           Brightness.light,
    systemNavigationBarColor:          AppTheme.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Load history before first frame so the UI never shows a flash of empty state
  final history = DeviceHistory();
  await history.load();

  runApp(
    MultiProvider(
      providers: [
        // history is already initialised — expose the existing instance
        ChangeNotifierProvider<DeviceHistory>.value(value: history),

        // OtaProvider holds a reference to history; create it directly
        // using the already-initialised history object (no ProxyProvider needed)
        ChangeNotifierProvider<OtaProvider>(
          create: (_) => OtaProvider(history: history),
        ),
      ],
      child: const NusOtaApp(),
    ),
  );
}

class NusOtaApp extends StatelessWidget {
  const NusOtaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title:                      'esp32-nus-ota',
    debugShowCheckedModeBanner: false,
    theme:                      AppTheme.data,
    home:                       const HomeScreen(),
  );
}

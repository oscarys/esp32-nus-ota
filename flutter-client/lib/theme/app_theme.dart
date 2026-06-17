// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2025 esp32-nus-ota contributors
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  static const background  = Color(0xFF0D1117);
  static const surface     = Color(0xFF161B22);
  static const surfaceHigh = Color(0xFF1C2128);
  static const border      = Color(0xFF30363D);

  static const teal        = Color(0xFF1D9E75);
  static const tealDim     = Color(0xFF0F2A1E);
  static const tealText    = Color(0xFF5DCAA5);

  static const amber       = Color(0xFFBA7517);
  static const amberDim    = Color(0xFF1A1500);
  static const amberText   = Color(0xFFEF9F27);

  static const coral       = Color(0xFFA32D2D);
  static const coralDim    = Color(0xFF2A0F0F);
  static const coralText   = Color(0xFFF09595);

  static const purple      = Color(0xFF534AB7);
  static const purpleDim   = Color(0xFF1A1F2E);
  static const purpleText  = Color(0xFFAFA9EC);

  static const textPrimary   = Color(0xFFE6EDF3);
  static const textSecondary = Color(0xFF8B949E);
  static const textTertiary  = Color(0xFF484F58);

  static TextStyle mono({double size = 12, Color? color, FontWeight weight = FontWeight.normal}) =>
      GoogleFonts.robotoMono(fontSize: size, color: color ?? textSecondary, fontWeight: weight);

  static TextStyle sans({double size = 14, Color? color, FontWeight weight = FontWeight.normal}) =>
      GoogleFonts.roboto(fontSize: size, color: color ?? textPrimary, fontWeight: weight);

  static ThemeData get data => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      surface: surface, primary: teal, secondary: amber, error: coral,
      onSurface: textPrimary, onPrimary: background,
      surfaceContainer: surfaceHigh, outline: border,
    ),
    textTheme: GoogleFonts.robotoTextTheme(ThemeData.dark().textTheme)
        .apply(bodyColor: textPrimary, displayColor: textPrimary),
    cardTheme: CardThemeData(
      color: surface, elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: border, width: 0.5),
      ),
      margin: EdgeInsets.zero,
    ),
    dividerTheme: const DividerThemeData(color: border, thickness: 0.5, space: 0),
    iconTheme: const IconThemeData(color: textSecondary, size: 18),
  );
}

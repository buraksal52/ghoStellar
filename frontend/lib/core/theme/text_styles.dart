import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Space Grotesk for headings/amounts, IBM Plex Sans for body text — matches
/// the design's `font-family` choices exactly.
class AppTextStyles {
  AppTextStyles._();

  static TextTheme textTheme(Color textColor) {
    final body = GoogleFonts.ibmPlexSansTextTheme();
    final heading = GoogleFonts.spaceGrotesk();
    return body
        .copyWith(
          headlineLarge: heading.copyWith(
            fontSize: 34,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
            color: textColor,
          ),
          headlineMedium: heading.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
          titleLarge: heading.copyWith(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
          titleMedium: heading.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
          displayLarge: heading.copyWith(
            fontSize: 36,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: textColor,
          ),
          bodyLarge: body.bodyLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: textColor,
          ),
          bodyMedium: body.bodyMedium?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: textColor,
          ),
          bodySmall: body.bodySmall?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: textColor,
          ),
          labelLarge: body.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        )
        .apply(bodyColor: textColor, displayColor: textColor);
  }
}

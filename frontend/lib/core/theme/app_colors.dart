import 'package:flutter/material.dart';

/// Verbatim port of the design mockup's DARK/LIGHT token objects. Values are
/// not re-derived or approximated — if the design changes, edit here only.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.pageBg,
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.text,
    required this.textSecondary,
    required this.muted,
    required this.primary,
    required this.primaryText,
    required this.info,
    required this.positive,
    required this.negative,
    required this.overlay,
    required this.primaryDim,
    required this.navActive,
    required this.infoCard,
    required this.warmCard,
    required this.tileSend,
    required this.tileReceive,
    required this.tilePool,
    required this.tileSendIcon,
    required this.tileReceiveIcon,
    required this.tilePoolIcon,
  });

  final Color pageBg;
  final Color bg;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color text;
  final Color textSecondary;
  final Color muted;
  final Color primary;
  final Color primaryText;
  final Color info;
  final Color positive;
  final Color negative;
  final Color overlay;
  final Color primaryDim;
  final Color navActive;
  final Color infoCard;
  final Color warmCard;
  final Color tileSend;
  final Color tileReceive;
  final Color tilePool;
  final Color tileSendIcon;
  final Color tileReceiveIcon;
  final Color tilePoolIcon;

  static const dark = AppColors(
    pageBg: Color(0xFF050B12),
    bg: Color(0xFF071018),
    surface: Color(0xFF0B151F),
    surfaceRaised: Color(0xFF101B26),
    border: Color(0xFF26384A),
    text: Color(0xFFF8F5EA),
    textSecondary: Color(0xFFA5B0BE),
    muted: Color(0xFF6F7C8E),
    primary: Color(0xFFFFA62B),
    primaryText: Color(0xFF07182F),
    info: Color(0xFF86C5FF),
    positive: Color(0xFF8FD6A8),
    negative: Color(0xFFD98A7A),
    overlay: Color(0xB7050B12), // rgba(5,11,18,.72)
    primaryDim: Color(0xFF3A3628),
    navActive: Color(0xFFFFA62B),
    infoCard: Color(0xFF0E1C2A),
    warmCard: Color(0xFF1B180E),
    tileSend: Color(0xFF2C2312),
    tileReceive: Color(0xFF122B40),
    tilePool: Color(0xFF173247),
    tileSendIcon: Color(0xFFFFA62B),
    tileReceiveIcon: Color(0xFF86C5FF),
    tilePoolIcon: Color(0xFF2E5AA7),
  );

  static const light = AppColors(
    pageBg: Color(0xFFEDEAE0),
    bg: Color(0xFFFFFDF6),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF6F2E7),
    border: Color(0xFFDDD8CA),
    text: Color(0xFF07182F),
    textSecondary: Color(0xFF5A6675),
    muted: Color(0xFF8A94A3),
    primary: Color(0xFFFFA62B),
    primaryText: Color(0xFF07182F),
    info: Color(0xFF2E5AA7),
    positive: Color(0xFF2F7A4F),
    negative: Color(0xFFA4432F),
    overlay: Color(0xB7FBF8ED), // rgba(251,248,237,.72)
    primaryDim: Color(0xFFEFE3CC),
    navActive: Color(0xFFFFA62B),
    infoCard: Color(0xFFEAF5FF),
    warmCard: Color(0xFFFFF1C8),
    tileSend: Color(0xFFFFF2BF),
    tileReceive: Color(0xFFE8F4FF),
    tilePool: Color(0xFFE9EEF9),
    tileSendIcon: Color(0xFFFFA62B),
    tileReceiveIcon: Color(0xFF86C5FF),
    tilePoolIcon: Color(0xFF2E5AA7),
  );

  @override
  AppColors copyWith({
    Color? pageBg,
    Color? bg,
    Color? surface,
    Color? surfaceRaised,
    Color? border,
    Color? text,
    Color? textSecondary,
    Color? muted,
    Color? primary,
    Color? primaryText,
    Color? info,
    Color? positive,
    Color? negative,
    Color? overlay,
    Color? primaryDim,
    Color? navActive,
    Color? infoCard,
    Color? warmCard,
    Color? tileSend,
    Color? tileReceive,
    Color? tilePool,
    Color? tileSendIcon,
    Color? tileReceiveIcon,
    Color? tilePoolIcon,
  }) {
    return AppColors(
      pageBg: pageBg ?? this.pageBg,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      border: border ?? this.border,
      text: text ?? this.text,
      textSecondary: textSecondary ?? this.textSecondary,
      muted: muted ?? this.muted,
      primary: primary ?? this.primary,
      primaryText: primaryText ?? this.primaryText,
      info: info ?? this.info,
      positive: positive ?? this.positive,
      negative: negative ?? this.negative,
      overlay: overlay ?? this.overlay,
      primaryDim: primaryDim ?? this.primaryDim,
      navActive: navActive ?? this.navActive,
      infoCard: infoCard ?? this.infoCard,
      warmCard: warmCard ?? this.warmCard,
      tileSend: tileSend ?? this.tileSend,
      tileReceive: tileReceive ?? this.tileReceive,
      tilePool: tilePool ?? this.tilePool,
      tileSendIcon: tileSendIcon ?? this.tileSendIcon,
      tileReceiveIcon: tileReceiveIcon ?? this.tileReceiveIcon,
      tilePoolIcon: tilePoolIcon ?? this.tilePoolIcon,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      pageBg: l(pageBg, other.pageBg),
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      border: l(border, other.border),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      muted: l(muted, other.muted),
      primary: l(primary, other.primary),
      primaryText: l(primaryText, other.primaryText),
      info: l(info, other.info),
      positive: l(positive, other.positive),
      negative: l(negative, other.negative),
      overlay: l(overlay, other.overlay),
      primaryDim: l(primaryDim, other.primaryDim),
      navActive: l(navActive, other.navActive),
      infoCard: l(infoCard, other.infoCard),
      warmCard: l(warmCard, other.warmCard),
      tileSend: l(tileSend, other.tileSend),
      tileReceive: l(tileReceive, other.tileReceive),
      tilePool: l(tilePool, other.tilePool),
      tileSendIcon: l(tileSendIcon, other.tileSendIcon),
      tileReceiveIcon: l(tileReceiveIcon, other.tileReceiveIcon),
      tilePoolIcon: l(tilePoolIcon, other.tilePoolIcon),
    );
  }
}

extension AppColorsContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

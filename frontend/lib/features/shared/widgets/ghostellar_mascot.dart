import 'package:flutter/material.dart';

/// Transparent ghoStellar mascot, bundled for offline use.
class GhostellarMascot extends StatelessWidget {
  const GhostellarMascot({super.key, this.size = 220});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/ghostellar-mascot-transparent.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'ghoStellar mascot: a ghost holding a phone',
    );
  }
}

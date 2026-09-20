import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A QR code on a white card. Always white, independent of theme: a
/// dark-mode QR is unreadable to most scanners.
class QrCard extends StatelessWidget {
  const QrCard({required this.data, this.size = 160, super.key});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: QrImageView(data: data, size: size),
    );
  }
}

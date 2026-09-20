import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = <(IconData, String, String)>[
      (Icons.home_rounded, 'Home', '/home'),
      (Icons.north_rounded, 'Send', '/send'),
      (Icons.south_rounded, 'Receive', '/receive'),
      (Icons.pool_rounded, 'Pool', '/pool'),
      (Icons.account_balance_rounded, 'Bank', '/anchor'),
      (Icons.bar_chart_rounded, 'Activity', '/activity'),
      (Icons.settings_rounded, 'Settings', '/settings'),
    ];
    return Drawer(
      backgroundColor: c.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('ghoStellar', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: Icon(Icons.close, color: c.text),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              for (final (icon, label, path) in items)
                ListTile(
                  leading: Icon(icon, color: c.textSecondary),
                  title: Text(label, style: TextStyle(color: c.text)),
                  onTap: () {
                    Navigator.of(context).pop();
                    context.go(path);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

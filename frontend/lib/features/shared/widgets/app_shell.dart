import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_provider.dart';
import 'app_drawer.dart';
import 'signing_overlay.dart';

const _titles = {
  '/home': 'ghoStellar',
  '/send': 'Send',
  '/receive': 'Receive',
  '/pool': 'Pool',
  '/anchor': 'Bank',
  '/anchor/trustline': 'Set up USDC',
  '/activity': 'Activity',
  '/settings': 'Settings',
};

const _navRoutes = ['/home', '/send', '/receive', '/pool', '/settings'];
const _navIcons = [
  Icons.home_rounded,
  Icons.north_rounded,
  Icons.south_rounded,
  Icons.pool_rounded,
  Icons.more_horiz_rounded,
];
const _navLabels = ['Home', 'Send', 'Receive', 'Pool', 'More'];

/// The persistent app frame (top bar, drawer, bottom nav) wrapping every
/// authenticated screen, plus the signing-lifecycle overlay stacked above
/// whatever the current screen renders — matches the design's single
/// scaffold with swapped content regions.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final location = GoRouterState.of(context).uri.path;
    final title = _titles[location] ?? 'ghoStellar';
    final showBack = !_navRoutes.contains(location) && location != '/anchor';

    return Scaffold(
      backgroundColor: c.bg,
      drawer: const AppDrawer(),
      appBar: AppBar(
        // Keyed switchers so the title and back/menu icon fade instead of
        // snapping when the route changes under the persistent app bar.
        leading: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: showBack
              ? IconButton(
                  key: const ValueKey('back'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
                )
              : Builder(
                  key: const ValueKey('menu'),
                  builder: (ctx) => IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () => Scaffold.of(ctx).openDrawer(),
                  ),
                ),
        ),
        title: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(title, key: ValueKey(title)),
        ),
        actions: [
          IconButton(
            icon: Icon(
              ref.watch(themeModeProvider) == ThemeMode.dark
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined,
            ),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: child,
          ),
          const SigningOverlay(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: c.bg,
        selectedItemColor: c.navActive,
        unselectedItemColor: c.muted,
        currentIndex: _currentIndex(location),
        onTap: (i) => context.go(_navRoutes[i]),
        type: BottomNavigationBarType.fixed,
        items: [
          for (var i = 0; i < _navRoutes.length; i++)
            BottomNavigationBarItem(icon: Icon(_navIcons[i]), label: _navLabels[i]),
        ],
      ),
    );
  }

  int _currentIndex(String location) {
    final i = _navRoutes.indexOf(location);
    return i == -1 ? 0 : i;
  }
}

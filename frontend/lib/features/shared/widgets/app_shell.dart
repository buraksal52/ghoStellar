import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../state/inbox_providers.dart';
import '../../../state/offline_providers.dart';
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

const _barSwitchDuration = Duration(milliseconds: 280);

/// Same fade-through as the page transitions (see `router/soft_transition.dart`):
/// the old title/icon is gone before the new one appears, so they never overlap.
Widget _barSwitchTransition(Widget child, Animation<double> animation) => FadeTransition(
  opacity: animation.drive(CurveTween(curve: const Interval(0.5, 1.0, curve: Curves.easeInOutCubic))),
  child: child,
);

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
///
/// Also where a pending offline cheque handoff gets its retries kicked:
/// once on first build (equivalent to "app opened, wallet unlocked" — this
/// widget only exists inside the authenticated shell) and again every time
/// the app comes back to the foreground, on top of `PendingHandoffsNotifier`'s
/// own periodic timer.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _comeOnline();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _comeOnline();
  }

  /// Everything that needs "we might be online now": retry both offline
  /// queues, refresh the account snapshot an offline payment would be built
  /// from next, and (once, at startup) load which requests were already
  /// answered offline in a previous session.
  void _comeOnline() {
    ref.read(pendingHandoffsProvider.notifier).retryAll();
    ref.read(pendingOfflinePaymentsProvider.notifier).retryAll();
    ref.read(accountSnapshotProvider.notifier).refresh();
    unawaited(_hydrateOfflineSpentIdsOnce());
  }

  bool _hydratedOfflineSpentIds = false;

  Future<void> _hydrateOfflineSpentIdsOnce() async {
    if (_hydratedOfflineSpentIds) return;
    _hydratedOfflineSpentIds = true;
    final ids = await ref.read(offlinePaymentStoreProvider).spentRequestIds();
    if (mounted) ref.read(offlineSpentRequestIdsProvider.notifier).hydrate(ids);
  }

  @override
  Widget build(BuildContext context) {
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
          duration: _barSwitchDuration,
          transitionBuilder: _barSwitchTransition,
          child: showBack
              ? IconButton(
                  key: const ValueKey('back'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
                )
              : Builder(
                  key: const ValueKey('menu'),
                  builder: (ctx) =>
                      IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
                ),
        ),
        title: AnimatedSwitcher(
          duration: _barSwitchDuration,
          transitionBuilder: _barSwitchTransition,
          // Default layout centers the children, so titles of different
          // widths would slide sideways while switching; keep them start-aligned.
          layoutBuilder: (current, previous) =>
              Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
          child: Text(title, key: ValueKey(title)),
        ),
        actions: [
          IconButton(
            icon: Icon(
              ref.watch(themeModeProvider) == ThemeMode.dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            ),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 0), child: widget.child),
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

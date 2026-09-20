import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/env.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../state/home_providers.dart';
import '../../../state/inbox_providers.dart';
import '../../../state/offline_providers.dart';
import '../../../state/starter_funds.dart';
import '../../../state/sync_providers.dart';
import '../../../state/wallet_providers.dart';
import '../starter_funds_action.dart';
import 'app_drawer.dart';
import 'ghostellar_mascot.dart';
import 'signing_overlay.dart';

const _titles = {
  '/home': 'ghoStellar',
  '/send': 'Send',
  '/receive': 'Receive',
  '/pool': 'Pool',
  '/anchor': 'Bank',
  '/anchor/trustline': 'Set up',
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
    // After the first frame: the signing overlay this may show is part of it.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_maybeOfferStarterFunds()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _comeOnline();
      // Money may have arrived while the app was in the background. Not part
      // of _comeOnline: that also runs from initState, where WidgetRef.invalidate
      // can't be used (it depends on the ProviderScope inherited widget).
      ref.invalidate(balancesProvider);
    }
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

  /// A brand-new testnet wallet used to get network fees automatically, but
  /// fees are invisible in a one-unit (USDC) app, so it looked like nothing
  /// happened. Give it what it actually needs — once per wallet, never as a
  /// retry loop: a failure is retried by hand from Settings → "Get test funds".
  Future<void> _maybeOfferStarterFunds() async {
    try {
      if (Env.networkLabel(ref.read(networkPassphraseProvider)) != 'Testnet') return;
      final me = ref.read(walletProvider).publicKey;
      if (me == null) return;
      final flag = ref.read(starterFundsFlagProvider);
      if (await flag.wasOffered(me)) return;

      final balances = await ref.read(balancesProvider.future);
      if (!mounted) return;
      // Marked before running: a failed run must not repeat on every start.
      await flag.markOffered(me);
      if (balances.holdsPayAsset) return;
      await runStarterFunds(ref);
    } catch (_) {
      // Best-effort convenience; the Home button is the manual path.
    }
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
          child: title == 'ghoStellar'
              ? Row(
                  key: ValueKey(title),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ExcludeSemantics(child: GhostellarMascot(size: 36)),
                    const SizedBox(width: 8),
                    Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                )
              : Text(title, key: ValueKey(title)),
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

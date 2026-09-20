import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/errors/api_error.dart';
import '../core/theme/app_colors.dart';
import '../features/shared/widgets/startup_loading_screen.dart';
import '../state/auth_providers.dart';
import '../state/connectivity_providers.dart';
import '../state/core_providers.dart';
import '../state/home_providers.dart';
import '../state/offline_providers.dart';
import '../state/sync_providers.dart';

/// SEP-10 login (if not already authenticated) followed by an
/// unconditional forced `/sync`, per the architecture docs — nothing else
/// renders until both succeed, UNLESS the failure is specifically "no
/// connection" on a device that has been online before: that goes straight
/// to the shell in offline mode instead (`_hasBeenOnlineBefore`), so the
/// classic-payment offline path (`offline_providers.dart`) is actually
/// reachable without a network round trip at cold start. Any other failure
/// (Horizon down, invalid signature, a brand-new never-synced wallet with
/// nothing cached) still shows the retry wall.
class AuthGatePage extends ConsumerStatefulWidget {
  const AuthGatePage({super.key});

  @override
  ConsumerState<AuthGatePage> createState() => _AuthGatePageState();
}

class _AuthGatePageState extends ConsumerState<AuthGatePage> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => _error = null);
    try {
      final authState = ref.read(authProvider);
      final alreadyAuthed = authState.value ?? false;
      if (!alreadyAuthed) {
        await ref.read(authProvider.notifier).login();
        final result = ref.read(authProvider);
        if (result.hasError) throw result.error!;
      }
      await ref.read(syncProvider.notifier).refresh();
      // The wallet was unlocked before this login ran, so the first
      // balance read can predate the friendbot fund the login just did.
      ref.invalidate(balancesProvider);
      final syncResult = ref.read(syncProvider);
      if (syncResult.hasError) throw syncResult.error!;
      if (mounted) context.go('/home');
    } catch (e) {
      if (isNetworkFailure(e) && await _hasBeenOnlineBefore()) {
        // No connection right now, but this device has a session or a
        // cached account snapshot from a previous online run — enter the
        // shell in offline mode instead of a dead-end wall, so the
        // already-built offline NFC/QR payment path is actually reachable.
        // A wallet that has never been online has nothing cached to build
        // an offline payment from, so it still gets the wall below.
        ref.read(offlineModeProvider.notifier).markOffline();
        if (mounted) context.go('/home');
        return;
      }
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<bool> _hasBeenOnlineBefore() async {
    final token = await ref.read(secureWalletStoreProvider).readAccessToken();
    if (token != null) return true;
    final snapshot = await ref.read(offlineAccountCacheProvider).read();
    return snapshot != null;
  }

  @override
  Widget build(BuildContext context) {
    if (_error == null) return const StartupLoadingScreen();

    final c = context.colors;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, color: c.negative, size: 40),
              const SizedBox(height: 16),
              Text(
                'Could not connect. Check your connection and try again.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              // The catch-all above also swallows non-network failures
              // (e.g. a response that fails to parse), so surface the
              // real cause.
              SelectableText(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: c.negative),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _run,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: c.primaryText,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

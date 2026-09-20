import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/anchor/anchor_deposit_withdraw_page.dart';
import '../features/anchor/trustline_setup_page.dart';
import '../features/activity/activity_page.dart';
import '../features/home/home_page.dart';
import '../features/onboarding/onboarding_step1_page.dart';
import '../features/onboarding/onboarding_step2_page.dart';
import '../features/onboarding/restore_wallet_page.dart';
import '../features/pool/pool_page.dart';
import '../features/receive/receive_page.dart';
import '../features/send/send_page.dart';
import '../features/settings/settings_page.dart';
import '../features/shared/widgets/app_shell.dart';
import 'auth_gate_page.dart';
import 'soft_transition.dart';
import 'splash_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => softPage(state: state, child: const SplashPage()),
      ),
      GoRoute(
        path: '/onboarding',
        pageBuilder: (context, state) =>
            softPage(state: state, child: const OnboardingStep1Page()),
      ),
      GoRoute(
        path: '/onboarding/recovery',
        pageBuilder: (context, state) {
          final words = state.extra as List<String>? ?? const [];
          return softPage(state: state, slide: true, child: OnboardingStep2Page(words: words));
        },
      ),
      GoRoute(
        path: '/onboarding/restore',
        pageBuilder: (context, state) =>
            softPage(state: state, slide: true, child: const RestoreWalletPage()),
      ),
      GoRoute(
        path: '/auth-gate',
        // Keep startup branding visible while restore hands off to login/sync.
        pageBuilder: (context, state) =>
            NoTransitionPage(key: state.pageKey, child: const AuthGatePage()),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => softPage(state: state, child: const HomePage()),
          ),
          GoRoute(
            path: '/send',
            pageBuilder: (context, state) => softPage(state: state, child: const SendPage()),
          ),
          GoRoute(
            path: '/receive',
            pageBuilder: (context, state) => softPage(state: state, child: const ReceivePage()),
          ),
          GoRoute(
            path: '/pool',
            pageBuilder: (context, state) => softPage(state: state, child: const PoolPage()),
          ),
          GoRoute(
            path: '/anchor',
            pageBuilder: (context, state) =>
                softPage(state: state, child: const AnchorDepositWithdrawPage()),
          ),
          GoRoute(
            path: '/anchor/trustline',
            pageBuilder: (context, state) =>
                softPage(state: state, slide: true, child: const TrustlineSetupPage()),
          ),
          GoRoute(
            path: '/activity',
            pageBuilder: (context, state) => softPage(state: state, child: const ActivityPage()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => softPage(state: state, child: const SettingsPage()),
          ),
        ],
      ),
    ],
  );
});

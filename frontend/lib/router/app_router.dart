import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/anchor/anchor_deposit_withdraw_page.dart';
import '../features/anchor/anchor_webview_page.dart';
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
import 'splash_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashPage()),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingStep1Page(),
      ),
      GoRoute(
        path: '/onboarding/recovery',
        builder: (context, state) {
          final words = state.extra as List<String>? ?? const [];
          return OnboardingStep2Page(words: words);
        },
      ),
      GoRoute(
        path: '/onboarding/restore',
        builder: (context, state) => const RestoreWalletPage(),
      ),
      GoRoute(path: '/auth-gate', builder: (context, state) => const AuthGatePage()),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/home', builder: (context, state) => const HomePage()),
          GoRoute(path: '/send', builder: (context, state) => const SendPage()),
          GoRoute(path: '/receive', builder: (context, state) => const ReceivePage()),
          GoRoute(path: '/pool', builder: (context, state) => const PoolPage()),
          GoRoute(
            path: '/anchor',
            builder: (context, state) => const AnchorDepositWithdrawPage(),
          ),
          GoRoute(
            path: '/anchor/trustline',
            builder: (context, state) => const TrustlineSetupPage(),
          ),
          GoRoute(
            path: '/anchor/webview',
            builder: (context, state) {
              final args = state.extra as AnchorWebviewArgs;
              return AnchorWebviewPage(args: args);
            },
          ),
          GoRoute(path: '/activity', builder: (context, state) => const ActivityPage()),
          GoRoute(path: '/settings', builder: (context, state) => const SettingsPage()),
        ],
      ),
    ],
  );
});

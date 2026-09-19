import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_colors.dart';
import '../state/auth_providers.dart';
import '../state/sync_providers.dart';

/// SEP-10 login (if not already authenticated) followed by an
/// unconditional forced `/sync`, per the architecture docs — nothing else
/// renders until both succeed. Any failure (network, Horizon, invalid
/// signature) shows a retry screen rather than crashing silently.
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
      final syncResult = ref.read(syncProvider);
      if (syncResult.hasError) throw syncResult.error!;
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
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

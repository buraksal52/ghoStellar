import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app currently believes it has no connection to the backend
/// gateway. There is no platform connectivity check here (no OS-level
/// "connected to Wi-Fi" signal, which can lie anyway — connected to a
/// network with no internet still reports "connected") — this is purely
/// inferred from the last request's outcome, flipped by [ApiClient]'s
/// reachability callback (`core_providers.dart`) and by `AuthGatePage` on
/// cold start.
class OfflineModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void markOffline() {
    if (!state) state = true;
  }

  void markOnline() {
    if (state) state = false;
  }
}

final offlineModeProvider = NotifierProvider<OfflineModeNotifier, bool>(OfflineModeNotifier.new);

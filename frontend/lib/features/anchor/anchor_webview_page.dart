import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../data/storage/local_activity_log.dart';
import '../../state/activity_providers.dart';
import '../../state/core_providers.dart';

class AnchorWebviewArgs {
  const AnchorWebviewArgs({
    required this.anchorId,
    required this.txId,
    required this.url,
    required this.kind,
    this.amount,
    this.decimals,
  });

  final String anchorId;
  final String txId;
  final String url;

  /// 'deposit' | 'withdraw'
  final String kind;
  final String? amount;
  final int? decimals;
}

/// Hosts the SEP-24 interactive flow. Since the anchor JWT never touches
/// the backend, this app is the one that must observe the outcome and
/// self-report it — there's no server-side push to rely on here.
class AnchorWebviewPage extends ConsumerStatefulWidget {
  const AnchorWebviewPage({required this.args, super.key});
  final AnchorWebviewArgs args;

  @override
  ConsumerState<AnchorWebviewPage> createState() => _AnchorWebviewPageState();
}

class _AnchorWebviewPageState extends ConsumerState<AnchorWebviewPage> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(widget.args.url));
  }

  Future<void> _finishAndReport() async {
    final anchorApi = ref.read(anchorApiProvider);
    final log = ref.read(localActivityLogProvider);
    try {
      await anchorApi.reportTransaction(
        widget.args.anchorId,
        widget.args.txId,
        kind: widget.args.kind,
        state: 'completed',
        amount: widget.args.amount,
        decimals: widget.args.decimals,
      );
      if (widget.args.amount != null) {
        await log.append(LocalActivityEvent(
          kind: 'anchor_${widget.args.kind}',
          amount: widget.args.amount!,
          assetCode: 'USDC',
          timestamp: DateTime.now(),
        ));
        ref.invalidate(activityItemsProvider);
      }
    } catch (_) {
      // Self-report is best-effort; the anchor's own record is authoritative.
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: WebViewWidget(controller: _controller),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton(
            onPressed: _finishAndReport,
            style: OutlinedButton.styleFrom(side: BorderSide(color: c.border), foregroundColor: c.text),
            child: const Text("I'm done"),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

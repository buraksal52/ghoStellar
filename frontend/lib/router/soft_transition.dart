import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

const _enterDuration = Duration(milliseconds: 300);
const _exitDuration = Duration(milliseconds: 220);
const _curve = Curves.easeInOutCubic;

/// Incoming pages start this far (as a fraction of their own width) to the
/// right — a nudge, not the full-width slide of the platform default.
const _slideOffset = Offset(0.06, 0);
const _scaleBegin = 0.98;

/// Cross-fade page transition used by every route. Tab-like screens
/// ([slide] false) fade through with a barely-there scale; deeper screens
/// ([slide] true) also drift in from the right. The outgoing page fades out
/// via [secondaryAnimation], so the two screens cross-fade instead of one
/// sliding over the other.
CustomTransitionPage<void> softPage({
  required GoRouterState state,
  required Widget child,
  bool slide = false,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: _enterDuration,
    reverseTransitionDuration: _exitDuration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final enter = animation.drive(CurveTween(curve: _curve));
      final leave = secondaryAnimation.drive(CurveTween(curve: _curve));

      final Widget moving = slide
          ? SlideTransition(
              position: enter.drive(Tween(begin: _slideOffset, end: Offset.zero)),
              child: child,
            )
          : ScaleTransition(
              scale: enter.drive(Tween(begin: _scaleBegin, end: 1.0)),
              child: child,
            );

      return FadeTransition(
        opacity: leave.drive(Tween(begin: 1.0, end: 0.0)),
        child: FadeTransition(opacity: enter, child: moving),
      );
    },
  );
}

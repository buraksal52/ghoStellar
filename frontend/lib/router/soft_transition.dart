import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

const _enterDuration = Duration(milliseconds: 380);
const _exitDuration = Duration(milliseconds: 280);

/// Incoming pages on [softPage]`(slide: true)` drift in from this far to the
/// right (fraction of their width) — a nudge, not the platform's full slide.
const _slideOffset = Offset(0.04, 0);

/// Fade-through: the outgoing page is fully faded out (first 30% of the
/// timeline) before the incoming one starts fading in (last 70%), so the
/// texts of the two screens never sit on top of each other half-transparent.
/// No scale on purpose — scaling re-rasterizes text and makes it shimmer.
const _fadeIn = Interval(0.3, 1.0, curve: Curves.easeInOutCubic);
const _fadeOut = Interval(0.0, 0.3, curve: Curves.easeInOutCubic);

/// Fade-through page transition used by every route. Tab-like screens
/// ([slide] false) only fade; deeper screens ([slide] true) also drift in a
/// few percent from the right.
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
      // A page fades in as `animation` runs forward and out as it reverses
      // (pop / replaced); when another page is pushed over it,
      // `secondaryAnimation` fades it out.
      final visible = animation.drive(CurveTween(curve: _fadeIn));
      final covered = secondaryAnimation.drive(CurveTween(curve: _fadeOut));

      final Widget moving = slide
          ? SlideTransition(
              position: visible.drive(Tween(begin: _slideOffset, end: Offset.zero)),
              child: child,
            )
          : child;

      return FadeTransition(
        opacity: covered.drive(Tween(begin: 1.0, end: 0.0)),
        child: FadeTransition(opacity: visible, child: moving),
      );
    },
  );
}

import 'dart:ui' show SemanticsRole;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Shared, quiet loading feedback for previews, maps and asynchronous screens.
class ImmichLoadingIndicator extends StatelessWidget {
  const ImmichLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'loading'.tr(),
      role: SemanticsRole.loadingSpinner,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 40,
          child: Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                strokeCap: StrokeCap.round,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                value: MediaQuery.disableAnimationsOf(context) ? 0.65 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

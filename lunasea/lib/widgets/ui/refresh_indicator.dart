import 'package:flutter/material.dart';

class LunaRefreshIndicator extends RefreshIndicator {
  LunaRefreshIndicator({
    GlobalKey<RefreshIndicatorState>? super.key,
    required BuildContext context,
    required super.onRefresh,
    required super.child,
  }) : super(
          backgroundColor: Theme.of(context).primaryColor,
          color: Theme.of(context).colorScheme.secondary,
        );
}

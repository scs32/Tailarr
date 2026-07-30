import 'package:flutter/material.dart';

import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/router/router.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/system/demo/demo.dart';
import 'package:lunasea/utils/profile_tools.dart';
import 'package:lunasea/widgets/pages/first_run_landing.dart';
import 'package:lunasea/widgets/ui.dart';

/// Wraps the app and, while [DemoMode.active], pins a persistent
/// "Demo Mode — Exit" bar under the content — never mistaken for real data,
/// and always a one-tap way back to the first-run landing (same "don't trap
/// the user" rule as the Basic shell's Leave Server).
class DemoModeBanner extends StatelessWidget {
  final Widget? child;

  const DemoModeBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // Rebuild when the active profile changes (enter/exit demo).
    return LunaSeaDatabase.ENABLED_PROFILE.listenableBuilder(
      builder: (context, _) {
        final content = child ?? const SizedBox.shrink();
        if (!DemoMode.active) return content;
        return Column(
          children: [
            Expanded(child: content),
            _bar(context),
          ],
        );
      },
    );
  }

  Widget _bar(BuildContext context) {
    return Material(
      color: LunaColours.accent,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.play_circle_outline_rounded,
                  color: Colors.white, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Demo Mode — sample data',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _exit(context),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.white.withValues(alpha: 0.18),
                ),
                child: const Text('Exit'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exit(BuildContext context) async {
    await LunaProfileTools().leaveDemo();
    // Go straight to the landing when nothing is configured (the usual case) —
    // explicit target instead of relying on the '/' redirect's timing.
    final target = LunaProfileTools.isFirstRun()
        ? FirstRunLandingRoute.path
        : LunaRoutes.initialLocation;
    LunaRouter.router.go(target);
  }
}

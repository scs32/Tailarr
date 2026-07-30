import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

class LunaReorderableListViewDragger extends StatelessWidget {
  final int index;

  const LunaReorderableListViewDragger({
    super.key,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ReorderableDragStartListener(
          index: index,
          child: const LunaIconButton(
            icon: Icons.menu_rounded,
            mouseCursor: SystemMouseCursors.click,
          ),
        ),
      ],
    );
  }
}

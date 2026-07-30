import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

class LunaDivider extends Divider {
  LunaDivider({
    super.key,
  }) : super(
          thickness: 1.0,
          color: LunaColours.accent.dimmed(),
          indent: LunaUI.DEFAULT_MARGIN_SIZE * 5,
          endIndent: LunaUI.DEFAULT_MARGIN_SIZE * 5,
        );
}

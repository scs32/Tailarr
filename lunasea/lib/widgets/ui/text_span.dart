import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

class LunaTextSpan extends TextSpan {
  const LunaTextSpan.extended({
    required super.text,
  }) : super(
          style: const TextStyle(
            height: LunaBlock.SUBTITLE_HEIGHT / LunaUI.FONT_SIZE_H3,
          ),
        );
}

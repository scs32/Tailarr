import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

class LunaCard extends Card {
  LunaCard({
    super.key,
    required BuildContext context,
    required Widget child,
    EdgeInsets super.margin = LunaUI.MARGIN_H_DEFAULT_V_HALF,
    Color? color,
    Decoration? decoration,
    double? height,
    double? width,
  }) : super(
          child: Container(
            child: child,
            decoration: decoration,
            height: height,
            width: width,
          ),
          color: color ?? Theme.of(context).primaryColor,
          shape: LunaUI.shapeBorder,
          elevation: 0.0,
          clipBehavior: Clip.antiAlias,
        );
}

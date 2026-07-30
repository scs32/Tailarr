import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LunaSwitch extends Switch {
  LunaSwitch({
    super.key,
    required super.value,
    required void Function(bool)? onChanged,
  }) : super(
          onChanged: onChanged == null
              ? null
              : (value) {
                  HapticFeedback.lightImpact();
                  onChanged(value);
                },
        );
}

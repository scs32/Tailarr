import 'package:flutter/material.dart';

class LunaPageView extends StatelessWidget {
  final PageController? controller;
  final List<Widget> children;

  const LunaPageView({
    super.key,
    this.controller,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: controller,
      children: children,
      physics: const NeverScrollableScrollPhysics(),
    );
  }
}

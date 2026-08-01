import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

class HomeNavigationBar extends StatelessWidget {
  final PageController? pageController;

  static List<ScrollController> scrollControllers = List.generate(
    icons.length,
    (_) => ScrollController(),
  );

  static final List<String> titles = [
    'dashboard.Assistant'.tr(),
    'dashboard.Calendar'.tr(),
  ];

  static const List<IconData> icons = [
    Icons.graphic_eq_rounded,
    Icons.calendar_today_rounded,
  ];

  const HomeNavigationBar({
    super.key,
    required this.pageController,
  });

  @override
  Widget build(BuildContext context) {
    return LunaBottomNavigationBar(
      pageController: pageController,
      scrollControllers: scrollControllers,
      icons: icons,
      titles: titles,
    );
  }
}

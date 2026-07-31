import 'package:flutter/material.dart';

import 'package:lunasea/modules/dashboard/routes/dashboard/widgets/navigation_bar.dart';
import 'package:lunasea/modules/voice/widgets/assistant_view.dart';

/// The Dashboard's home tab: the mesh-decorated pulsing voice orb you talk to.
///
/// Replaces the old module-launcher tab — the launcher still lives in the
/// hamburger drawer, so nothing is stranded, and Calendar stays as the second
/// tab. This is what the app lands on at launch.
class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key});

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AssistantView(
      scrollController: HomeNavigationBar.scrollControllers[0],
    );
  }
}

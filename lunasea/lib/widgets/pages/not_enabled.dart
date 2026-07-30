import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

class NotEnabledPage extends StatelessWidget {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final String module;

  NotEnabledPage({
    super.key,
    required this.module,
  });

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: LunaAppBar(title: module),
      body: LunaMessage.moduleNotEnabled(
        context: context,
        module: module,
      ),
    );
  }
}

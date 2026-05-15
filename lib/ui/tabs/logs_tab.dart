import 'package:flutter/material.dart';

import '../log_view.dart';

/// Second Playground tab. Wraps the existing [LogView] in
/// AutomaticKeepAliveClientMixin so the log scroll position and the
/// RX-visibility filter state survive switching to the controls tab.
class LogsTab extends StatefulWidget {
  const LogsTab({super.key});

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return const LogView();
  }
}

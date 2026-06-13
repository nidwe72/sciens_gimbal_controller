import 'package:flutter/material.dart';

import 'parallax_explainer.dart';
import 'parallax_pipeline_explainer.dart';

/// PR 9.1b — the "More infos" slide-in panel for the Parallax sub-tab.
///
/// A height-bounded modal bottom sheet hosting two tabs:
///   • **Problem**  — why the no-parallax point matters (PR 9.1 physics).
///   • **Solution** — how the CV pipeline computes the metric (PR 9.1b).
///
/// Each tab's content is a self-contained, internally-scrolling explainer; the
/// sheet is bounded (~88% screen) so the `TabBarView` has a finite height.
Future<void> showParallaxInfo(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const ParallaxInfoSheet(),
  );
}

class ParallaxInfoSheet extends StatelessWidget {
  const ParallaxInfoSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.88;
    return SizedBox(
      height: height,
      child: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            TabBar(
              tabs: [
                Tab(text: 'Problem'),
                Tab(text: 'Solution'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  ParallaxExplainerSheet(),
                  ParallaxPipelineExplainer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

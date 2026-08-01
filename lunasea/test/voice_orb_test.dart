import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/widgets/assistant_orb.dart';

/// The assistant dashboard's face is a deliberate, animated fabric-mesh sphere
/// — NOT a loading spinner. It renders through a fragment shader on device and
/// a CPU lat/long mesh fallback where Impeller is unavailable (as in this test
/// harness). These guard that, either way, it renders and animates without
/// throwing, and that it is a painted surface rather than a progress indicator.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('AssistantOrb paints (idle) and is not a spinner', (tester) async {
    await tester.pumpWidget(host(const AssistantOrb(size: 200.0)));

    expect(find.byType(AssistantOrb), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // Advance the looping animation a few frames — must not throw.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AssistantOrb shows its label and honours intensity extremes',
      (tester) async {
    await tester.pumpWidget(
      host(const AssistantOrb(size: 160.0, intensity: 1.0, label: 'Thinking…')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Thinking…'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Rebuild with clamped-below-zero-equivalent (0.0) intensity, no label.
    await tester.pumpWidget(host(const AssistantOrb(size: 160.0)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Thinking…'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

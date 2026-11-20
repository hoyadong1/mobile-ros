import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/tool_tabs.dart';

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.name});
  final String name;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final controller = TextEditingController();
  @override
  void dispose() { controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(ToolTabsScope.maybeOf(context)!.title), bottom: ToolTabsScope.maybeOf(context)!.bar),
    body: Column(children: [const Spacer(), TextField(key: Key('input-${widget.name}'), controller: controller)]),
  );
}

void main() {
  testWidgets('phone tabs become simultaneous tablet panes without losing either editor', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: ToolTabs(title: 'Status', tabs: [
      ToolTab(key: const Key('left-tab'), label: 'Left', icon: Icons.map_outlined,
        build: (_) => const _Probe(key: Key('left-probe'), name: 'left')),
      ToolTab(key: const Key('right-tab'), label: 'Right', icon: Icons.receipt_outlined,
        build: (_) => const _Probe(key: Key('right-probe'), name: 'right')),
    ])));
    await tester.enterText(find.byKey(const Key('input-left')), 'left draft');
    final left = tester.state<_ProbeState>(find.byKey(const Key('left-probe')));
    expect(find.byKey(const Key('right-probe')), findsNothing);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpAndSettle();
    expect(tester.widget<Flex>(find.byKey(const Key('tool-panes'))).direction, Axis.horizontal);
    expect(identical(tester.state(find.byKey(const Key('left-probe'))), left), isTrue);
    await tester.enterText(find.byKey(const Key('input-right')), 'right draft');
    final right = tester.state<_ProbeState>(find.byKey(const Key('right-probe')));

    await tester.binding.setSurfaceSize(const Size(800, 1280));
    await tester.pumpAndSettle();
    expect(tester.widget<Flex>(find.byKey(const Key('tool-panes'))).direction, Axis.vertical);
    expect(identical(tester.state(find.byKey(const Key('right-probe'))), right), isTrue);
    expect(find.text('left draft'), findsOneWidget);
    expect(find.text('right draft'), findsOneWidget);

    final upperInput = find.byKey(const Key('input-left'));
    final beforeKeyboard = tester.getBottomLeft(upperInput).dy;
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getBottomLeft(upperInput).dy, closeTo(beforeKeyboard, 1),
      reason: 'the keyboard is below the upper pane, so its input must not jump upwards');
    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('right-tab')));
    await tester.pumpAndSettle();
    expect(identical(tester.state(find.byKey(const Key('right-probe'))), right), isTrue);
    expect(find.text('right draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

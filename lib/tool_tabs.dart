import 'package:material_ui/material_ui.dart';

/// One tab of [ToolTabs]: a whole screen (with its own app bar) shown when the tab is picked.
class ToolTab {
  const ToolTab({required this.key, required this.label, required this.icon, required this.build, this.badge = 0});
  final Key key;
  final String label;
  final IconData icon;
  final WidgetBuilder build;
  /// A count on the tab while another tab is shown (new problems, ...).
  final int badge;
}

/// Screens that belong together, as tabs under one title at the top, like the settings screen's tabs.
/// Each tab is a screen with its own app bar and buttons; inside [ToolTabs] its app bar shows the shared
/// title and the tabs ([ToolTabsScope]). A tab is built the first time it is shown and kept after (its
/// subscriptions and state stay while the person switches back and forth).
class ToolTabs extends StatefulWidget {
  const ToolTabs({super.key, required this.title, required this.tabs, this.initial = 0, this.barKey,
    this.phoneTabs = true}) : assert(tabs.length > 0);
  final String title;
  final List<ToolTab> tabs;
  final int initial;
  final Key? barKey;
  final bool phoneTabs;

  static Axis? splitAxis(Size size) {
    if (!size.width.isFinite || !size.height.isFinite) return null;
    if (size.width >= 1100 && size.height >= 480) return Axis.horizontal;
    if (size.width >= 700 && size.height >= 1000) return Axis.vertical;
    return null;
  }

  @override
  State<ToolTabs> createState() => ToolTabsState();
}

class ToolTabsState extends State<ToolTabs> with TickerProviderStateMixin {
  late TabController _controller;
  final _built = <Key>{};
  final _paneKeys = <Key, GlobalKey>{};

  int get tab => _controller.index;

  @override
  void initState() {
    super.initState();
    _createController(widget.initial.clamp(0, widget.tabs.length - 1));
    _built.add(widget.tabs[tab].key);
  }

  void _createController(int index) {
    _controller = TabController(length: widget.tabs.length, vsync: this, initialIndex: index)..addListener(_onTab);
  }

  void _onTab() {
    if (mounted) setState(() => _built.add(widget.tabs[tab].key));
  }

  @override
  void didUpdateWidget(ToolTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = oldWidget.tabs[_controller.index.clamp(0, oldWidget.tabs.length - 1)].key;
    if (oldWidget.tabs.length != widget.tabs.length || widget.tabs[tab.clamp(0, widget.tabs.length - 1)].key != selected) {
      _controller.dispose();
      final next = widget.tabs.indexWhere((t) => t.key == selected);
      _createController(next < 0 ? 0 : next);
    }
    _built.add(widget.tabs[tab].key);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final axis = widget.tabs.length == 2 ? ToolTabs.splitAxis(box.biggest) : null;
    final outerPadding = MediaQuery.paddingOf(context);
    final lowerPaneHeight = (box.maxHeight - kToolbarHeight - outerPadding.vertical) / 2 + outerPadding.bottom;
    final split = axis != null;
    if (split) {
      _built.addAll(widget.tabs.map((t) => t.key));
    }
    final bar = !widget.phoneTabs || widget.tabs.length < 2 || split ? null : TabBar(key: widget.barKey, controller: _controller, tabs: [
      for (final (i, t) in widget.tabs.indexed)
        // The label shrinks (with an ellipsis) before the row overflows: a small phone with large text
        // could not fit "Sensors" beside its icon.
        Tab(key: t.key, height: 46, child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(t.icon, size: 20),
          const SizedBox(width: 8),
          Flexible(child: Badge(isLabelVisible: t.badge > 0 && i != tab, label: Text('${t.badge}'), offset: const Offset(14, -6),
            child: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis))),
        ])),
    ]);
    Widget pane(int index) {
      final t = widget.tabs[index], visible = split || index == tab;
      if (!_built.contains(t.key)) return const SizedBox.shrink();
      return TickerMode(enabled: visible, child: KeyedSubtree(
        key: _paneKeys.putIfAbsent(t.key, () => GlobalKey()),
        child: Builder(builder: (context) {
          final media = MediaQuery.of(context);
          // A keyboard below a portrait tablet's upper pane must not also shrink that pane.
          final bottom = axis == Axis.vertical && index == 0
              ? (media.viewInsets.bottom - lowerPaneHeight).clamp(0.0, media.viewInsets.bottom).toDouble()
              : media.viewInsets.bottom;
          return MediaQuery(data: media.copyWith(viewInsets: media.viewInsets.copyWith(bottom: bottom)),
            child: ToolTabsScope(title: split ? t.label : widget.title, bar: bar, split: split, visible: visible,
              child: Builder(builder: t.build)));
        })));
    }
    if (split) {
      return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(top: false, child: Flex(key: const Key('tool-panes'), direction: axis, children: [
        Expanded(child: pane(0)),
        if (axis == Axis.horizontal) const VerticalDivider(width: 1) else const Divider(height: 1),
        Expanded(child: pane(1)),
      ])),
      );
    }
    return ColoredBox(color: context.pageColor, child: IndexedStack(index: tab, children: [
      for (var i = 0; i < widget.tabs.length; i++) pane(i),
    ]));
  });
}

/// What a screen shown as a tab puts in its app bar: the shared title, and the tabs below it.
class ToolTabsScope extends InheritedWidget {
  const ToolTabsScope({super.key, required this.title, required this.bar, required super.child,
    this.split = false, this.visible = true});
  final String title;
  final PreferredSizeWidget? bar;
  final bool split, visible;

  static ToolTabsScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ToolTabsScope>();

  @override
  bool updateShouldNotify(ToolTabsScope old) => old.title != title || old.bar != bar || old.split != split || old.visible != visible;
}

extension on BuildContext {
  Color get pageColor => Theme.of(this).scaffoldBackgroundColor;
}

import 'package:flutter/material.dart';

class TabItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const TabItem(this.icon, this.selectedIcon, this.label);
}

/// Rounded floating tab dock (same design as the bitFocus bottom bar).
/// Only the selected tab shows its name, so five tabs fit cleanly.
/// Colours can be passed in so it matches the current bitLMP palette.
class TabDock extends StatelessWidget {
  final List<TabItem> items;
  final int index;
  final ValueChanged<int> onSelect;
  final Color? containerColor;
  final Color? indicatorColor;
  final Color? selectedColor;
  final Color? unselectedColor;

  const TabDock({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    this.containerColor,
    this.indicatorColor,
    this.selectedColor,
    this.unselectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = containerColor ?? scheme.surfaceContainerHigh;
    final ind = indicatorColor ?? scheme.primaryContainer;
    final sel = selectedColor ?? scheme.onPrimaryContainer;
    final un = unselectedColor ?? scheme.onSurfaceVariant;
    return Material(
      color: bg,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(34),
        side: BorderSide(color: Colors.white.withOpacity(0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(
          builder: (context, c) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: c.maxWidth),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (int i = 0; i < items.length; i++)
                      _barItem(i, ind, sel, un),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _barItem(int i, Color ind, Color sel, Color un) {
    final item = items[i];
    final on = i == index;
    return Semantics(
      button: true,
      selected: on,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          height: 48,
          padding: EdgeInsets.symmetric(horizontal: on ? 14 : 10),
          decoration: BoxDecoration(
            color: on ? ind : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(on ? item.selectedIcon : item.icon,
                  size: 23, color: on ? sel : un),
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: on
                    ? Padding(
                        padding: const EdgeInsets.only(left: 7),
                        child: Text(
                          item.label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: sel,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

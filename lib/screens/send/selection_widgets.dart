import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../logic/send_selection.dart';
import '../../utils/format.dart';
import '../../utils/helper.dart';

/// Duration that collapses to zero when the system asks for reduced motion.
Duration motion(BuildContext context, [int ms = 160]) =>
    MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : Duration(milliseconds: ms);

/// Reacts on pointer-down (not on release) with a quick, interruptible scale.
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const PressScale({required this.child, this.onTap, this.scale = 0.97});

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: motion(context, 100),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Round check mark used in lists and grids.
class SelectCheck extends StatelessWidget {
  final bool selected;
  final double size;

  const SelectCheck({required this.selected, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: motion(context, 140),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? Colors.deepPurple.shade400 : Colors.black26,
        border: Border.all(
          color: selected ? Colors.deepPurple.shade400 : Colors.white,
          width: 1.6,
        ),
      ),
      child: AnimatedOpacity(
        duration: motion(context, 120),
        opacity: selected ? 1 : 0,
        child: Icon(LucideIcons.check, size: size * 0.64, color: Colors.white),
      ),
    );
  }
}

/// One list row (icon + title + subtitle + check). Rebuilds only when its own
/// selection state changes.
class SelectableRow extends StatelessWidget {
  final String selectionKey;
  final SelectedItem Function() item;
  final Widget leading;
  final String title;
  final String? subtitle;

  const SelectableRow({
    required this.selectionKey,
    required this.item,
    required this.leading,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final selected = context
        .select<SendSelection, bool>((s) => s.contains(selectionKey));

    return PressScale(
      scale: 0.985,
      onTap: () => context.read<SendSelection>().toggle(item()),
      child: AnimatedContainer(
        duration: motion(context),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? Colors.deepPurple.shade400.withOpacity(0.14)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            SizedBox(width: 44, height: 44, child: Center(child: leading)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.getFont(
                      context.l.fontAndika,
                      fontSize: 16,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.getFont(
                        context.l.fontAndika,
                        fontSize: 13,
                        color: context.t.dividerColor.withOpacity(0.7),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SelectCheck(selected: selected),
          ],
        ),
      ),
    );
  }
}

/// Files / APKs the user picked manually, shown so they can be un-ticked again.
class PickedFilesList extends StatelessWidget {
  final bool Function(SelectedItem) filter;

  const PickedFilesList({required this.filter});

  @override
  Widget build(BuildContext context) {
    final picked = context
        .watch<SendSelection>()
        .items
        .where((i) => i.kind == SelectedKind.file && filter(i))
        .toList();

    return Column(
      children: [
        for (final i in picked)
          SelectableRow(
            selectionKey: i.key,
            item: () => i,
            leading: Icon(
              i.isApk ? LucideIcons.binary : LucideIcons.file,
              color: Colors.deepPurple.shade400,
            ),
            title: i.label,
            subtitle: i.size != null ? formatBytes(i.size!) : null,
          ),
      ],
    );
  }
}

/// Reads sizes of freshly picked files without blocking the UI isolate for long.
Future<List<SelectedItem>> itemsFromPaths(Iterable<String?> paths) async {
  final out = <SelectedItem>[];
  for (final p in paths) {
    if (p == null) continue;
    int? size;
    try {
      size = await File(p).length();
    } catch (_) {}
    out.add(SelectedItem.file(path: p, size: size));
  }
  return out;
}

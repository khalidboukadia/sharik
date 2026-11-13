import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../components/buttons.dart';
import '../../logic/native_bridge.dart';
import '../../logic/send_selection.dart';
import '../../utils/format.dart';
import '../../utils/helper.dart';
import 'selection_widgets.dart';

/// Images / videos as a grid, music as a list. Content is read from MediaStore
/// by native code; nothing is copied.
class MediaTab extends StatefulWidget {
  final MediaKind kind;

  const MediaTab(this.kind);

  @override
  State<MediaTab> createState() => _MediaTabState();
}

class _MediaTabState extends State<MediaTab>
    with AutomaticKeepAliveClientMixin<MediaTab>, WidgetsBindingObserver {
  bool _loading = true;
  bool _denied = false;
  bool _failed = false;
  List<MediaItem> _items = const [];

  // video thumbnails are requested lazily, once per item
  final Map<int, Future<Uint8List?>> _thumbs = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && (_denied || _failed)) _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _denied = false;
      _failed = false;
    });

    try {
      final granted = await MediaApi.hasPermission(widget.kind) ||
          await MediaApi.requestPermission(widget.kind);
      if (!mounted) return;
      if (!granted) {
        setState(() {
          _loading = false;
          _denied = true;
        });
        return;
      }

      final items = await MediaApi.list(widget.kind);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  SelectedItem _selected(MediaItem m) =>
      SelectedItem.file(path: m.path, label: m.name, size: m.size);

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(
            context.t.colorScheme.secondary.withOpacity(0.8),
          ),
        ),
      );
    }

    if (_denied || _failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l.sendAccessNeeded,
                textAlign: TextAlign.center,
                style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 220,
                child: PrimaryButton(
                  height: 48,
                  fontSize: 16,
                  onClick: _init,
                  text: context.l.sendAllowAccess,
                ),
              ),
              const SizedBox(height: 10),
              // after a refusal "don't ask again" Android shows no dialog any more
              SizedBox(
                width: 220,
                child: TransparentButton(
                  Center(
                    child: Text(
                      context.l.sendOpenAppSettings,
                      style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 15),
                    ),
                  ),
                  MediaApi.openAppSettings,
                  TransparentButtonBackground.def,
                  border: true,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: Text(
          context.l.sendNothingFound,
          style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
        ),
      );
    }

    return widget.kind == MediaKind.audio ? _audioList() : _grid();
  }

  Widget _audioList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final m = _items[i];
        final details = [
          if (m.artist != null && m.artist != '<unknown>') m.artist!,
          if (m.durationMs > 0) formatDuration(m.durationMs),
          formatBytes(m.size),
        ].join('  •  ');

        return SelectableRow(
          selectionKey: m.path,
          item: () => _selected(m),
          leading: Icon(LucideIcons.music, color: Colors.deepPurple.shade400),
          title: m.name,
          subtitle: details,
        );
      },
    );
  }

  Widget _grid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) => _GridTile(
        item: _items[i],
        isVideo: widget.kind == MediaKind.videos,
        thumbnail: widget.kind == MediaKind.videos
            ? _thumbs.putIfAbsent(
                _items[i].id,
                () => MediaApi.thumbnail(MediaKind.videos, _items[i].id),
              )
            : null,
        toSelected: () => _selected(_items[i]),
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  final MediaItem item;
  final bool isVideo;
  final Future<Uint8List?>? thumbnail;
  final SelectedItem Function() toSelected;

  const _GridTile({
    required this.item,
    required this.isVideo,
    required this.thumbnail,
    required this.toSelected,
  });

  Widget _placeholder(BuildContext context) => Container(
        color: Colors.deepPurple.shade100.withOpacity(0.4),
        child: Icon(
          isVideo ? LucideIcons.video : LucideIcons.image,
          color: Colors.deepPurple.shade300,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final selected =
        context.select<SendSelection, bool>((s) => s.contains(item.path));

    final Widget picture = isVideo
        ? FutureBuilder<Uint8List?>(
            future: thumbnail,
            builder: (context, snap) => snap.data == null
                ? _placeholder(context)
                : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
          )
        : Image.file(
            File(item.path),
            fit: BoxFit.cover,
            // decode small: a full-size photo per tile would waste RAM
            cacheWidth: 300,
            gaplessPlayback: true,
            errorBuilder: (context, _, __) => _placeholder(context),
          );

    return PressScale(
      scale: 0.96,
      onTap: () => context.read<SendSelection>().toggle(toSelected()),
      child: AnimatedScale(
        scale: selected ? 0.9 : 1,
        duration: motion(context),
        curve: Curves.easeOut,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              picture,
              if (isVideo && item.durationMs > 0)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      formatDuration(item.durationMs),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              Positioned(
                right: 6,
                top: 6,
                child: SelectCheck(selected: selected, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

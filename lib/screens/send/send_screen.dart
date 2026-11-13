import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../components/buttons.dart';
import '../../logic/native_bridge.dart';
import '../../logic/send_selection.dart';
import '../../utils/helper.dart';
import 'apps_tab.dart';
import 'files_tab.dart';
import 'media_tab.dart';
import 'selection_widgets.dart';

/// Full-screen sender (Android). A category bar on top switches the content:
/// apps / images / videos / music / files. The selection is shared by all
/// categories, and the bottom bar sends everything at once.
///
/// Pops with a [SendResult] (ticked items and/or a typed text).
class SendScreen extends StatefulWidget {
  const SendScreen();

  /// Slides in from the right and back out the same way it came.
  static Future<SendResult?> open(BuildContext context) =>
      Navigator.of(context).push<SendResult>(
        PageRouteBuilder<SendResult>(
          transitionDuration: motion(context, 280),
          reverseTransitionDuration: motion(context, 240),
          pageBuilder: (_, __, ___) => const SendScreen(),
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        ),
      );

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);
  final SendSelection _selection = SendSelection();

  @override
  void dispose() {
    _tabs.dispose();
    _selection.dispose();
    super.dispose();
  }

  void _send() {
    if (_selection.isEmpty) return;
    Navigator.of(context).pop(SendResult(items: _selection.items));
  }

  Widget _tab(IconData icon, String label) => Tab(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _selection,
      child: Scaffold(
        body: Column(
          children: [
            const SafeArea(
              bottom: false,
              left: false,
              right: false,
              child: SizedBox(height: 12),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  TransparentButton(
                    const Icon(LucideIcons.chevronLeft, size: 28),
                    () => Navigator.of(context).pop(),
                    TransparentButtonBackground.purpleDark,
                  ),
                  Text(
                    context.l.homeSend,
                    style: GoogleFonts.getFont(
                      context.l.fontComfortaa,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TabBar(
                controller: _tabs,
                isScrollable: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.deepPurple.shade400,
                ),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.deepPurple.shade400,
                labelStyle: GoogleFonts.getFont(
                  context.l.fontAndika,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: GoogleFonts.getFont(
                  context.l.fontAndika,
                  fontSize: 15,
                ),
                tabs: [
                  _tab(LucideIcons.binary, context.l.sendTabApps),
                  _tab(LucideIcons.image, context.l.sendTabImages),
                  _tab(LucideIcons.video, context.l.sendTabVideos),
                  _tab(LucideIcons.music, context.l.sendTabMusic),
                  _tab(LucideIcons.file, context.l.sendTabFiles),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  const AppsTab(),
                  const MediaTab(MediaKind.images),
                  const MediaTab(MediaKind.videos),
                  const MediaTab(MediaKind.audio),
                  FilesTab(
                    onText: (text) =>
                        Navigator.of(context).pop(SendResult(text: text.data)),
                  ),
                ],
              ),
            ),
            _bottomBar(context),
          ],
        ),
      ),
    );
  }

  /// Translucent bar that slides in once something is selected.
  Widget _bottomBar(BuildContext context) {
    return Consumer<SendSelection>(
      builder: (context, selection, _) {
        final visible = !selection.isEmpty;

        return AnimatedSize(
          duration: motion(context, 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: !visible
              ? const SizedBox(width: double.infinity)
              : ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      color: Colors.deepPurple.shade50.withOpacity(0.85),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
                          child: Row(
                            children: [
                              TransparentButton(
                                const Icon(LucideIcons.x, size: 22),
                                selection.clear,
                                TransparentButtonBackground.purpleDark,
                              ),
                              Expanded(
                                child: PrimaryButton(
                                  height: 52,
                                  fontSize: 18,
                                  onClick: _send,
                                  text:
                                      '${context.l.generalSend} (${selection.count})',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

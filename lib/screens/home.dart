
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../components/buttons.dart';
import '../components/logo.dart';
import 'session/host_screen.dart';
import 'session/scan_screen.dart';
import '../logic/language.dart';
import '../conf.dart';
import 'send/selection_widgets.dart';
import 'send/send_screen.dart';
import '../utils/helper.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen();

  Future<void> _openSend(BuildContext context) async {
    // 1) pick what to send  2) scan the receiver's QR code  3) the shared session page
    final result = await SendScreen.open(context);
    if (result == null) return;
    await ScanScreen.open(context, result);
  }

  Future<void> _openReceive(BuildContext context) => HostScreen.open(context);

  void _pickLanguage(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        children: [
          for (final l in languageList)
            SimpleDialogOption(
              onPressed: () {
                context.read<LanguageManager>().language = l;
                Navigator.of(ctx).pop();
              },
              child: Text(l.nameLocal, style: const TextStyle(fontSize: 18)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SafeArea(
            bottom: false,
            left: false,
            right: false,
            child: SizedBox(height: 22),
          ),
          SharikLogo(),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(
                  child: _ActionTile(
                    icon: LucideIcons.upload,
                    label: context.l.homeSend,
                    onTap: () => _openSend(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionTile(
                    icon: LucideIcons.download,
                    label: context.l.homeReceive,
                    onTap: () => _openReceive(context),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Container(
            color: Colors.deepPurple.shade100,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Row(
                  children: [
                    TransparentButton(
                      SizedBox(
                        height: 20,
                        width: 20,
                        child: Icon(
                          LucideIcons.languages,
                          color: Colors.deepPurple.shade700,
                          size: 20,
                        ),
                      ),
                      () => _pickLanguage(context),
                      TransparentButtonBackground.purpleLight,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.96,
      onTap: onTap,
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade400,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 52, color: Colors.grey.shade100),
            const SizedBox(height: 12),
            Text(
              label,
              style: GoogleFonts.getFont(
                context.l.fontAndika,
                color: Colors.grey.shade100,
                fontSize: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

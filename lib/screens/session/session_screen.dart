import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:wakelock/wakelock.dart';

import '../../components/buttons.dart';
import '../../logic/send_selection.dart';
import '../../logic/session/session_models.dart';
import '../../logic/session/session_service.dart';
import '../../logic/wifi_bridge.dart';
import '../../utils/format.dart';
import '../../utils/helper.dart';
import '../send/selection_widgets.dart';
import '../send/send_screen.dart';

/// The page both phones end up on after the scan: everything sent and received
/// with its progress. Either phone can send more at any time, no new scan needed.
class SessionScreen extends StatefulWidget {
  final SessionService service;

  /// what the sender picked before scanning: offered as soon as the page opens
  final SendResult? initial;

  const SessionScreen({required this.service, this.initial});

  /// Replaces the current page (the scanner / the QR page) with the session.
  static Future<void> replace(
    BuildContext context,
    SessionService service, {
    SendResult? initial,
  }) =>
      Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          transitionDuration: motion(context, 260),
          pageBuilder: (_, __, ___) => SessionScreen(service: service, initial: initial),
          transitionsBuilder: (_, animation, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          ),
        ),
      );

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  SessionService get service => widget.service;

  @override
  void initState() {
    super.initState();
    Wakelock.enable();
    final initial = widget.initial;
    if (initial != null) _offer(initial);
  }

  @override
  void dispose() {
    Wakelock.disable();
    service.leave().whenComplete(service.dispose);
    HotspotSession.stop();
    WifiApi.leaveWifi().catchError((Object _) {});
    super.dispose();
  }

  Future<void> _offer(SendResult result) async {
    try {
      await service.offer(await result.toSpecs());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l.sendError)),
      );
    }
  }

  Future<void> _sendMore() async {
    final result = await SendScreen.open(context);
    if (result != null) _offer(result);
  }

  Future<bool> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(c.l.sessionLeaveTitle),
        content: Text(c.l.sessionLeaveBody),
        actions: [
          DialogTextButton(c.l.sessionStay, () => Navigator.of(c).pop(false)),
          DialogTextButton(c.l.sessionLeave, () => Navigator.of(c).pop(true)),
        ],
      ),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _confirmLeave,
      child: Scaffold(
        body: AnimatedBuilder(
          animation: service,
          builder: (context, _) => Column(
            children: [
              const SafeArea(
                bottom: false,
                left: false,
                right: false,
                child: SizedBox(height: 12),
              ),
              _header(context),
              Expanded(child: _list(context)),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: PrimaryButton(
                    height: 54,
                    fontSize: 19,
                    onClick: _sendMore,
                    text: context.l.sessionSendMore,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final up = service.connected;
    final name = service.peer?.name ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
      child: Row(
        children: [
          TransparentButton(
            const Icon(LucideIcons.chevronLeft, size: 28),
            () async {
              if (await _confirmLeave() && mounted) Navigator.of(context).pop();
            },
            TransparentButtonBackground.purpleDark,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? context.l.sessionConnected : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.getFont(
                    context.l.fontComfortaa,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Row(
                  children: [
                    AnimatedContainer(
                      duration: motion(context),
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: up ? Colors.green.shade500 : Colors.red.shade400,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      up ? context.l.sessionConnected : context.l.sessionDisconnected,
                      style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 14),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    final items = service.items;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            context.l.sessionEmpty,
            textAlign: TextAlign.center,
            style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      itemCount: items.length,
      itemBuilder: (context, i) => _ItemCard(item: items[i], service: service),
    );
  }
}

class _ItemCard extends StatelessWidget {
  final TransferItem item;
  final SessionService service;

  const _ItemCard({required this.item, required this.service});

  String _status(BuildContext c) {
    switch (item.state) {
      case TransferState.waiting:
        return c.l.sessionWaiting;
      case TransferState.active:
        return item.isIncoming ? c.l.sessionReceiving : c.l.sessionSending;
      case TransferState.done:
        return c.l.sessionDone;
      case TransferState.failed:
        return c.l.sessionFailed;
      case TransferState.canceled:
        return c.l.sessionCanceled;
    }
  }

  IconData get _icon {
    switch (item.kind) {
      case ItemKind.app:
        return LucideIcons.binary;
      case ItemKind.text:
        return LucideIcons.fileText;
      case ItemKind.file:
        return LucideIcons.file;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = item.state == TransferState.active;
    final deep = Colors.deepPurple.shade400;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: deep.withOpacity(0.1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: deep.withOpacity(0.18),
                ),
                child: Icon(_icon, color: deep),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.getFont(
                        context.l.fontAndika,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          item.isIncoming ? LucideIcons.download : LucideIcons.upload,
                          size: 14,
                          color: deep,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            item.kind == ItemKind.text
                                ? _status(context)
                                : '${formatBytes(item.total)}  •  ${_status(context)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.getFont(
                              context.l.fontAndika,
                              fontSize: 13,
                              color: item.state == TransferState.failed
                                  ? Colors.red.shade400
                                  : context.t.dividerColor.withOpacity(0.75),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _trailing(context),
            ],
          ),
          if (active || item.state == TransferState.waiting) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                // waiting: indeterminate; moving: real progress
                value: active ? item.progress : null,
                minHeight: 6,
                backgroundColor: deep.withOpacity(0.15),
                valueColor: AlwaysStoppedAnimation(deep),
              ),
            ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${formatBytes(item.bytes)} / ${formatBytes(item.total)}  (${(item.progress * 100).floor()}%)',
                  style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 12),
                ),
              ),
          ],
          if (item.kind == ItemKind.text && item.text != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                item.text!,
                maxLines: 6,
                style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 14),
              ),
            ),
          if (item.isIncoming && item.state == TransferState.done && item.kind == ItemKind.file)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                item.savedToDownloads
                    ? context.l.sessionSavedDownloads
                    : '${context.l.sessionSavedApp}: ${item.files.first.path ?? ''}',
                style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 12),
              ),
            ),
          if (item.installState == InstallState.failed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${context.l.sessionInstallFailed}${(item.installMessage ?? '').isEmpty ? '' : ': ${item.installMessage}'}',
                style: GoogleFonts.getFont(
                  context.l.fontAndika,
                  fontSize: 12,
                  color: Colors.red.shade400,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _trailing(BuildContext context) {
    final deep = Colors.deepPurple.shade400;

    if (item.isActive) {
      return PressScale(
        onTap: () => service.cancel(item),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(LucideIcons.x, color: deep),
        ),
      );
    }

    if (item.state == TransferState.done) {
      if (item.isIncoming && item.kind == ItemKind.text) {
        return PressScale(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: item.text ?? ''));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l.connectCopied)),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(LucideIcons.copy, color: deep),
          ),
        );
      }

      if (item.isIncoming && item.kind == ItemKind.app) {
        switch (item.installState) {
          case InstallState.installing:
            return const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            );
          case InstallState.installed:
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.check, color: Colors.green.shade500),
                const SizedBox(width: 4),
                Text(context.l.sessionInstalled),
              ],
            );
          case InstallState.none:
          case InstallState.failed:
            return PressScale(
              onTap: () => service.install(item),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: deep,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  context.l.sessionInstall,
                  style: GoogleFonts.getFont(
                    context.l.fontAndika,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
        }
      }

      return Icon(LucideIcons.check, color: Colors.green.shade500);
    }

    return Icon(LucideIcons.x, color: Colors.red.shade300);
  }
}

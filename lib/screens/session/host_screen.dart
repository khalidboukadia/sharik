import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../components/buttons.dart';
import '../../logic/native_bridge.dart';
import '../../logic/session/session_models.dart';
import '../../logic/session/session_service.dart';
import '../../logic/wifi_bridge.dart';
import '../../utils/helper.dart';
import '../send/connect_screen.dart';
import '../send/selection_widgets.dart';
import 'session_screen.dart';

/// "Receive": this phone shows the QR code. The sender scans it, and both land on the
/// session page. If the phone is on no network yet, it first creates a hotspot (the QR
/// then also carries the hotspot's name and password).
class HostScreen extends StatefulWidget {
  const HostScreen();

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: motion(context, 280),
          reverseTransitionDuration: motion(context, 240),
          pageBuilder: (_, __, ___) => const HostScreen(),
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      );

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  SessionService? _service;
  JoinCode? _code;
  String? _error;
  StreamSubscription<Peer>? _sub;
  bool _handedOver = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (!_handedOver) {
      // nobody connected: free the port and the hotspot
      final s = _service;
      if (s != null) s.leave().whenComplete(s.dispose);
      HotspotSession.stop();
    }
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      // 1) a network both phones can share: Wi-Fi, the phone's hotspot, or our own hotspot
      if (await LocalNetwork.detect() == null) {
        final ok = await ConnectScreen.open(context);
        if (!ok || !mounted) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
      }

      // 2) the server both phones talk through
      final service = SessionService(
        token: SessionService.newToken(),
        deviceName: await DeviceApi.deviceName(),
      );
      await service.start();
      _service = service;

      // 3) our addresses (a fresh hotspot needs a moment to get its IP)
      var ips = <String>[];
      for (var i = 0; i < 12 && ips.isEmpty; i++) {
        ips = await LocalNetwork.addresses(preferred: HotspotSession.interfaceName);
        if (ips.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!mounted) return;
      if (ips.isEmpty) {
        setState(() => _error = context.l.hostNoAddress);
        return;
      }

      _sub = service.onPeerJoined.listen((_) {
        if (!mounted || _handedOver) return;
        _handedOver = true;
        SessionScreen.replace(context, service);
      });

      setState(() {
        _code = JoinCode(
          ips: ips,
          port: service.port,
          token: service.token,
          name: service.deviceName,
          wifi: HotspotSession.current,
        );
      });
    } catch (_) {
      if (mounted) setState(() => _error = context.l.hostNoAddress);
    }
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
                  context.l.homeReceive,
                  style: GoogleFonts.getFont(
                    context.l.fontComfortaa,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.getFont(
              context.l.fontAndika,
              fontSize: 16,
              color: Colors.red.shade400,
            ),
          ),
        ),
      );
    }

    final code = _code;
    if (code == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              context.l.hostPreparing,
              style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Text(
          context.l.hostHint,
          style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
        ),
        const SizedBox(height: 18),
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: QrImage(data: code.uri, size: 260, backgroundColor: Colors.white),
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            code.name,
            style: GoogleFonts.getFont(
              context.l.fontAndika,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                context.l.hostWaiting,
                style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 14),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        TransparentButton(
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LucideIcons.copy, size: 18),
                const SizedBox(width: 8),
                Text(
                  context.l.connectCopyCode,
                  style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
                ),
              ],
            ),
          ),
          () async {
            await Clipboard.setData(ClipboardData(text: code.uri));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l.connectCopied)),
            );
          },
          TransparentButtonBackground.def,
          border: true,
        ),
      ],
    );
  }
}

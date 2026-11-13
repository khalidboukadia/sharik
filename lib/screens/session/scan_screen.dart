import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';

import '../../components/buttons.dart';
import '../../logic/native_bridge.dart';
import '../../logic/send_selection.dart';
import '../../logic/session/session_models.dart';
import '../../logic/session/session_service.dart';
import '../../logic/wifi_bridge.dart';
import '../../utils/helper.dart';
import '../send/selection_widgets.dart';
import 'session_screen.dart';

/// Sender side, after choosing what to send: the camera scans the receiver's QR code,
/// joins its network when needed, connects, and opens the session page where the
/// chosen items start going right away.
class ScanScreen extends StatefulWidget {
  final SendResult pending;

  const ScanScreen({required this.pending});

  static Future<void> open(BuildContext context, SendResult pending) =>
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: motion(context, 280),
          reverseTransitionDuration: motion(context, 240),
          pageBuilder: (_, __, ___) => ScanScreen(pending: pending),
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      );

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'sharik-qr');
  QRViewController? _controller;
  StreamSubscription<Barcode>? _sub;

  bool _busy = false;
  bool _cameraDenied = false;
  String? _status;
  String? _error;
  DateTime _lastBadCode = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _sub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _onCreated(QRViewController c) {
    _controller = c;
    _sub = c.scannedDataStream.listen((barcode) {
      final raw = barcode.code;
      if (raw == null || _busy) return;
      _handleRaw(raw);
    });
  }

  void _handleRaw(String raw) {
    final code = JoinCode.parse(raw);
    if (code == null) {
      // keep scanning, but do not spam the user with the same message
      if (DateTime.now().difference(_lastBadCode).inSeconds >= 3) {
        _lastBadCode = DateTime.now();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.scanBadCode)),
        );
      }
      return;
    }
    _connect(code);
  }

  Future<void> _connect(JoinCode code) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = context.l.scanConnecting;
    });
    _controller?.pauseCamera();

    final service = SessionService(
      token: code.token,
      deviceName: await DeviceApi.deviceName(),
    );

    try {
      await service.start();

      // already on the same network (router Wi-Fi, or the receiver's hotspot)?
      var ok = await service.tryConnect(code.ips, code.port, timeout: const Duration(seconds: 2));

      // otherwise join the receiver's hotspot, then retry while the link comes up
      if (!ok && code.wifi != null) {
        if (mounted) setState(() => _status = context.l.scanJoining);
        await WifiApi.joinWifi(code.wifi!);

        if (mounted) setState(() => _status = context.l.scanConnecting);
        for (var i = 0; i < 10 && !ok && mounted; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          ok = await service.tryConnect(code.ips, code.port, timeout: const Duration(seconds: 2));
        }
      }

      if (!ok) throw const WifiException('unreachable');

      if (!mounted) {
        await service.leave();
        service.dispose();
        return;
      }
      // the session page now owns the service, the Wi-Fi link and its cleanup
      await SessionScreen.replace(context, service, initial: widget.pending);
    } catch (_) {
      await service.leave();
      service.dispose();
      try {
        await WifiApi.leaveWifi();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
        _error = context.l.scanFailed;
      });
      _controller?.resumeCamera();
    }
  }

  Future<void> _enterCode() async {
    final controller = TextEditingController();
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (clip != null && JoinCode.parse(clip) != null) controller.text = clip;
    if (!mounted) return;

    final raw = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(c.l.scanEnterCode),
        content: TextField(
          controller: controller,
          maxLines: 3,
          minLines: 2,
          decoration: InputDecoration(hintText: c.l.receivePasteCode),
        ),
        actions: [
          DialogTextButton(c.l.generalClose, () => Navigator.of(c).pop()),
          DialogTextButton(c.l.receiveJoin, () => Navigator.of(c).pop(controller.text)),
        ],
      ),
    );
    controller.dispose();

    if (raw != null && raw.trim().isNotEmpty && mounted) _handleRaw(raw);
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
                  context.l.scanTitle,
                  style: GoogleFonts.getFont(
                    context.l.fontComfortaa,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              context.l.scanHint,
              style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    QRView(
                      key: _qrKey,
                      onQRViewCreated: _onCreated,
                      onPermissionSet: (_, granted) {
                        if (!granted && mounted) setState(() => _cameraDenied = true);
                      },
                      overlay: QrScannerOverlayShape(
                        borderColor: Colors.deepPurple.shade300,
                        borderRadius: 14,
                        borderLength: 28,
                        borderWidth: 8,
                        cutOutSize: 240,
                      ),
                    ),
                    if (_cameraDenied)
                      Container(
                        color: Colors.black87,
                        padding: const EdgeInsets.all(24),
                        alignment: Alignment.center,
                        child: Text(
                          context.l.scanCameraDenied,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ),
                    if (_busy)
                      Container(
                        color: Colors.black54,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              _status ?? '',
                              style: const TextStyle(color: Colors.white, fontSize: 17),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                _error!,
                style: GoogleFonts.getFont(
                  context.l.fontAndika,
                  fontSize: 15,
                  color: Colors.red.shade400,
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: TransparentButton(
                Center(
                  child: Text(
                    context.l.scanEnterCode,
                    style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
                  ),
                ),
                _busy ? () {} : _enterCode,
                TransparentButtonBackground.def,
                border: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

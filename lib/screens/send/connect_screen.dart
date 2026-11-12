import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../components/buttons.dart';
import '../../logic/wifi_bridge.dart';
import '../../utils/helper.dart';
import 'selection_widgets.dart';

/// Step before choosing what to send (like SHAREit): both phones must be on the
/// same network. If this phone is already on Wi-Fi / sharing a hotspot the screen
/// closes at once. Otherwise it offers: create a hotspot with a QR code, open the
/// Wi-Fi settings, or open the hotspot settings.
///
/// Pops `true` when it is fine to continue.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen();

  static Future<bool> open(BuildContext context) async {
    final ok = await Navigator.of(context).push<bool>(
      PageRouteBuilder<bool>(
        transitionDuration: motion(context, 280),
        reverseTransitionDuration: motion(context, 240),
        pageBuilder: (_, __, ___) => const ConnectScreen(),
        transitionsBuilder: (_, animation, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
    return ok ?? false;
  }

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

enum _Phase { checking, options, starting, hotspotReady }

class _ConnectScreenState extends State<ConnectScreen> with WidgetsBindingObserver {
  _Phase _phase = _Phase.checking;
  String? _error;
  WifiCredentials? _hotspot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // coming back from the system Wi-Fi / hotspot settings
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _phase == _Phase.options) _check();
  }

  Future<void> _check() async {
    final lan = await LocalNetwork.detect();
    if (!mounted) return;
    if (lan != null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _phase = _Phase.options);
    }
  }

  Future<void> _startHotspot() async {
    setState(() {
      _phase = _Phase.starting;
      _error = null;
    });

    try {
      if (!await WifiApi.hasLocationPermission() &&
          !await WifiApi.requestLocationPermission()) {
        throw const WifiException('permission');
      }
      if (!await WifiApi.isLocationEnabled()) {
        throw const WifiException('location_off');
      }

      final before = await LocalNetwork.interfaceNames();
      final creds = await WifiApi.startHotspot();

      // the hotspot shows up as a new network interface: remember it for the sharing screen
      String? iface;
      for (var i = 0; i < 8 && iface == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final now = await LocalNetwork.interfaceNames();
        final added = now.difference(before);
        if (added.isNotEmpty) iface = added.first;
      }

      HotspotSession.current = creds;
      HotspotSession.interfaceName = iface;

      if (!mounted) {
        await HotspotSession.stop();
        return;
      }
      setState(() {
        _hotspot = creds;
        _phase = _Phase.hotspotReady;
      });
    } on WifiException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.options;
        _error = e.code == 'permission'
            ? context.l.connectNeedLocationPermission
            : e.code == 'location_off'
                ? context.l.connectLocationOff
                : context.l.connectHotspotFailed;
      });
      if (e.code == 'location_off') WifiApi.openSettings('location');
    }
  }

  Future<void> _back() async {
    if (_phase == _Phase.hotspotReady) {
      await HotspotSession.stop();
      if (!mounted) return;
      setState(() {
        _hotspot = null;
        _phase = _Phase.options;
      });
    } else {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _back();
        return false;
      },
      child: Scaffold(
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
                    _back,
                    TransparentButtonBackground.purpleDark,
                  ),
                  Expanded(
                    child: Text(
                      context.l.connectTitle,
                      style: GoogleFonts.getFont(
                        context.l.fontComfortaa,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: motion(context, 220),
                child: KeyedSubtree(key: ValueKey(_phase), child: _body(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (_phase) {
      case _Phase.checking:
        return _busy(context.l.connectChecking);
      case _Phase.starting:
        return _busy(context.l.connectStarting);
      case _Phase.options:
        return _options(context);
      case _Phase.hotspotReady:
        return _hotspotReady(context);
    }
  }

  Widget _busy(String text) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation(
                context.t.colorScheme.secondary.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 16),
            Text(text, style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16)),
          ],
        ),
      );

  Widget _option(IconData icon, String title, String hint, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PressScale(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.deepPurple.shade400,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, size: 30, color: Colors.grey.shade100),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.getFont(
                        context.l.fontAndika,
                        color: Colors.grey.shade100,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hint,
                      style: GoogleFonts.getFont(
                        context.l.fontAndika,
                        color: Colors.grey.shade200,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _options(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Text(
          context.l.connectIntro,
          style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _error!,
              style: GoogleFonts.getFont(
                context.l.fontAndika,
                fontSize: 15,
                color: Colors.red.shade400,
              ),
            ),
          ),
        const SizedBox(height: 18),
        _option(
          LucideIcons.qrCode,
          context.l.connectCreateHotspot,
          context.l.connectCreateHotspotHint,
          _startHotspot,
        ),
        _option(
          LucideIcons.wifi,
          context.l.connectOpenWifi,
          context.l.connectOpenWifiHint,
          () => WifiApi.openSettings('wifi'),
        ),
        _option(
          LucideIcons.upload,
          context.l.connectOpenHotspot,
          context.l.connectOpenHotspotHint,
          () => WifiApi.openSettings('hotspot'),
        ),
      ],
    );
  }

  Widget _hotspotReady(BuildContext context) {
    final h = _hotspot!;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Text(
                '$label: ',
                style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 15),
              ),
              Expanded(
                child: SelectableText(
                  value,
                  style: GoogleFonts.jetBrainsMono(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Text(
          context.l.connectScanHint,
          style: GoogleFonts.getFont(context.l.fontAndika, fontSize: 16),
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImage(data: h.code, size: 220, backgroundColor: Colors.white),
          ),
        ),
        const SizedBox(height: 16),
        row(context.l.connectNetwork, h.ssid),
        row(context.l.connectPassword, h.password),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TransparentButton(
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
                  await Clipboard.setData(ClipboardData(text: h.code));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l.connectCopied)),
                  );
                },
                TransparentButtonBackground.def,
                border: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        PrimaryButton(
          height: 56,
          fontSize: 20,
          onClick: () => Navigator.of(context).pop(true),
          text: context.l.connectContinue,
        ),
      ],
    );
  }
}

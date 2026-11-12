import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../components/buttons.dart';
import '../logic/wifi_bridge.dart';
import '../utils/helper.dart';

/// Receiver side of the QR flow: paste the code copied from the sender (or typed
/// from its screen) and join its network. Pops `true` once connected.
class JoinCodeDialog extends StatefulWidget {
  const JoinCodeDialog();

  @override
  State<JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<JoinCodeDialog> {
  final _controller = TextEditingController();
  bool _joining = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _prefillFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && WifiCredentials.parse(text) != null && mounted) {
      setState(() => _controller.text = text);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && mounted) setState(() => _controller.text = data!.text!);
  }

  Future<void> _join() async {
    final creds = WifiCredentials.parse(_controller.text);
    if (creds == null) {
      setState(() => _error = context.l.receiveJoinInvalid);
      return;
    }

    setState(() {
      _joining = true;
      _error = null;
    });

    try {
      await WifiApi.joinWifi(creds);
      if (mounted) Navigator.of(context).pop(true);
    } on WifiException {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = context.l.receiveJoinFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      scrollable: true,
      title: Text(
        context.l.receiveJoinWithCode,
        style: GoogleFonts.getFont(
          context.l.fontComfortaa,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            enabled: !_joining,
            maxLines: 3,
            minLines: 2,
            decoration: InputDecoration(hintText: context.l.receivePasteCode),
            onChanged: (_) => setState(() => _error = null),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: GoogleFonts.getFont(
                  context.l.fontAndika,
                  fontSize: 14,
                  color: Colors.red.shade400,
                ),
              ),
            ),
          if (_joining)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      actions: [
        DialogTextButton(context.l.generalClose, _joining ? null : () => Navigator.of(context).pop(false)),
        DialogTextButton(context.l.receivePaste, _joining ? null : _paste),
        DialogTextButton(
          context.l.receiveJoin,
          _joining || _controller.text.trim().isEmpty ? null : _join,
        ),
      ],
    );
  }
}

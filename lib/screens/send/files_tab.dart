import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../dialogs/open_dialog.dart';
import '../../dialogs/share_text.dart';
import '../../logic/send_selection.dart';
import '../../logic/sharing_object.dart';
import '../../utils/helper.dart';
import 'selection_widgets.dart';

/// Any other file (system picker) and text. Picked files stay listed here so
/// they can be un-ticked.
class FilesTab extends StatefulWidget {
  /// called when the user typed a text: text cannot be mixed with files, so
  /// the Send screen closes right away with it
  final void Function(SharingObject text) onText;

  const FilesTab({required this.onText});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab>
    with AutomaticKeepAliveClientMixin<FilesTab> {
  @override
  bool get wantKeepAlive => true;

  Future<void> _pickFiles() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null || !mounted) return;
    final items = await itemsFromPaths(res.paths);
    if (!mounted) return;
    context.read<SendSelection>().addAll(items);
  }

  Future<void> _typeText() async {
    final text = await openDialog(context, ShareTextDialog());
    if (text != null) widget.onText(text);
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) {
    return PressScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.deepPurple.shade400.withOpacity(0.5)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.deepPurple.shade400),
            const SizedBox(width: 12),
            Text(
              label,
              style: GoogleFonts.getFont(
                context.l.fontAndika,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _action(LucideIcons.file, context.l.sendChooseFiles, _pickFiles),
        const SizedBox(height: 10),
        _action(LucideIcons.fileText, context.l.homeSelectText, _typeText),
        const SizedBox(height: 14),
        // APKs picked in the Apps tab are listed there, not here
        PickedFilesList(filter: (i) => !i.isApk),
      ],
    );
  }
}

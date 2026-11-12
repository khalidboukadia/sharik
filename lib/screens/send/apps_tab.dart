import 'package:device_apps/device_apps.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../logic/native_bridge.dart';
import '../../logic/send_selection.dart';
import '../../utils/format.dart';
import '../../utils/helper.dart';
import 'selection_widgets.dart';

/// All launchable apps of the phone (system apps included) + a shortcut to pick
/// an .apk file that is not installed. Every app is ONE row, whatever its splits.
class AppsTab extends StatefulWidget {
  const AppsTab();

  @override
  State<AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends State<AppsTab>
    with AutomaticKeepAliveClientMixin<AppsTab> {
  List<ApplicationWithIcon>? _apps;
  Map<String, int> _sizes = {};
  String _search = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final arr = await DeviceApps.getInstalledApplications(
      onlyAppsWithLaunchIntent: true,
      includeSystemApps: true,
      includeAppIcons: true,
    );
    final apps = arr.cast<ApplicationWithIcon>()
      ..sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));

    if (!mounted) return;
    setState(() => _apps = apps);

    // sizes (base + splits) come from native code in one call; the list is already visible
    try {
      final sizes =
          await AppPackageApi.getAppSizes(apps.map((e) => e.packageName).toList());
      if (mounted) setState(() => _sizes = sizes);
    } catch (_) {
      // sizes are cosmetic: the list still works without them
    }
  }

  Future<void> _pickApk() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
      allowMultiple: true,
    );
    if (res == null || !mounted) return;
    final items = await itemsFromPaths(res.paths);
    if (!mounted) return;
    context.read<SendSelection>().addAll(items);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final apps = _apps;
    final query = _search.trim().toLowerCase();
    final shown = apps == null
        ? const <ApplicationWithIcon>[]
        : query.isEmpty
            ? apps
            : apps
                .where((a) =>
                    a.appName.toLowerCase().contains(query) ||
                    a.packageName.toLowerCase().contains(query))
                .toList();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      // header (pick apk + picked apks + search) is item 0
      itemCount: shown.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _header(context, loading: apps == null);

        final app = shown[index - 1];
        final size = _sizes[app.packageName];

        return SelectableRow(
          selectionKey: SelectedItem.appKey(app.packageName),
          item: () => SelectedItem.app(
            packageName: app.packageName,
            label: app.appName,
            size: size,
          ),
          leading: Image.memory(
            app.icon,
            width: 40,
            height: 40,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
          title: app.appName,
          subtitle: size != null ? formatBytes(size) : app.packageName,
        );
      },
    );
  }

  Widget _header(BuildContext context, {required bool loading}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PressScale(
          onTap: _pickApk,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.deepPurple.shade400.withOpacity(0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.binary, color: Colors.deepPurple.shade400),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l.sendPickApk,
                        style: GoogleFonts.getFont(
                          context.l.fontAndika,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        context.l.sendPickApkHint,
                        style: GoogleFonts.getFont(
                          context.l.fontAndika,
                          fontSize: 13,
                          color: context.t.dividerColor.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        PickedFilesList(filter: (i) => i.isApk),
        TextField(
          onChanged: (v) => setState(() => _search = v),
          decoration: InputDecoration(
            hintText: context.l.selectAppSearch,
            prefixIcon: const Icon(LucideIcons.search, size: 20),
          ),
        ),
        const SizedBox(height: 8),
        if (loading)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation(
                  context.t.colorScheme.secondary.withOpacity(0.8),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

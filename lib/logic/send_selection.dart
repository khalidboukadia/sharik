import 'dart:io';

import 'package:flutter/foundation.dart';

import '../conf.dart';
import '../utils/format.dart';
import 'native_bridge.dart';
import 'session/session_models.dart';
import 'sharing_object.dart';

enum SelectedKind { app, file }

class SelectedItem {
  final SelectedKind kind;

  /// `app:<packageName>` for apps, the absolute path for files
  final String key;
  final String label;

  /// only for files
  final String? path;

  /// only for apps
  final String? packageName;

  final int? size;

  const SelectedItem._({
    required this.kind,
    required this.key,
    required this.label,
    this.path,
    this.packageName,
    this.size,
  });

  factory SelectedItem.app({
    required String packageName,
    required String label,
    int? size,
  }) =>
      SelectedItem._(
        kind: SelectedKind.app,
        key: appKey(packageName),
        label: label,
        packageName: packageName,
        size: size,
      );

  factory SelectedItem.file({
    required String path,
    String? label,
    int? size,
  }) =>
      SelectedItem._(
        kind: SelectedKind.file,
        key: path,
        label: label ?? basename(path),
        path: path,
        size: size,
      );

  static String appKey(String packageName) => 'app:$packageName';

  bool get isApk => kind == SelectedKind.file && key.toLowerCase().endsWith('.apk');
}

/// Everything the user ticked across all tabs of the Send screen.
class SendSelection extends ChangeNotifier {
  final Map<String, SelectedItem> _items = {};

  List<SelectedItem> get items => _items.values.toList();
  int get count => _items.length;
  bool get isEmpty => _items.isEmpty;

  bool contains(String key) => _items.containsKey(key);

  void toggle(SelectedItem item) {
    if (_items.remove(item.key) == null) {
      _items[item.key] = item;
    }
    notifyListeners();
  }

  void addAll(Iterable<SelectedItem> items) {
    for (final i in items) {
      _items[i.key] = i;
    }
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }

  /// Resolves every selected app to ALL of its APK files (base + splits) and
  /// builds the object handed to the existing sharing flow.
  Future<SharingObject> toSharingObject() async {
    final paths = <String>[];
    final names = <String>[];

    for (final item in _items.values) {
      if (item.kind == SelectedKind.app) {
        final info = await AppPackageApi.getAppPackage(item.packageName!);
        paths.addAll(info.files.map((f) => f.path));
        names.add(info.appName);
      } else {
        paths.add(item.path!);
        names.add(item.label);
      }
    }

    final onlyApps = _items.values.every((i) => i.kind == SelectedKind.app);
    final n = _items.length;

    return SharingObject(
      type: onlyApps ? SharingObjectType.app : SharingObjectType.file,
      data: paths.join(multipleFilesDelimiter),
      name: '${n == 1 ? '' : '$n: '}${names.join(' ')}',
    );
  }
}

/// What the Send screen hands back: ticked items and/or a typed text.
class SendResult {
  final List<SelectedItem> items;
  final String? text;

  const SendResult({this.items = const [], this.text});

  /// Turns the selection into things the session can offer. Every app becomes ONE item
  /// carrying its base APK and all splits.
  Future<List<OutgoingSpec>> toSpecs() async {
    final specs = <OutgoingSpec>[];

    final t = text;
    if (t != null && t.isNotEmpty) {
      specs.add(OutgoingSpec(
        kind: ItemKind.text,
        title: t.length > 60 ? '${t.substring(0, 60)}...' : t,
        text: t,
      ));
    }

    for (final i in items) {
      if (i.kind == SelectedKind.app) {
        final info = await AppPackageApi.getAppPackage(i.packageName!);
        specs.add(OutgoingSpec(
          kind: ItemKind.app,
          title: info.appName,
          packageName: info.packageName,
          versionName: info.versionName,
          files: [
            for (final f in info.files)
              TransferFile(name: f.name, size: f.size, path: f.path),
          ],
        ));
      } else {
        final file = File(i.path!);
        specs.add(OutgoingSpec(
          kind: ItemKind.file,
          title: i.label,
          files: [TransferFile(name: basename(i.path!), size: await file.length(), path: i.path)],
        ));
      }
    }
    return specs;
  }
}

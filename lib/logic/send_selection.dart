import 'package:flutter/foundation.dart';

import '../conf.dart';
import '../utils/format.dart';
import 'native_bridge.dart';
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

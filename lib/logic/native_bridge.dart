import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Thin Dart wrappers around the Android MethodChannels (see AppPackagePlugin.kt / MediaPlugin.kt).
/// Android only: callers must check `Platform.isAndroid` first.

enum MediaKind { images, videos, audio }

class MediaItem {
  final int id;
  final String name;
  final String path;
  final int size;
  final int durationMs;
  final String? artist;

  const MediaItem({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.durationMs,
    this.artist,
  });

  factory MediaItem.fromMap(Map<dynamic, dynamic> m) => MediaItem(
        id: (m['id'] as num).toInt(),
        name: m['name'] as String,
        path: m['path'] as String,
        size: (m['size'] as num?)?.toInt() ?? 0,
        durationMs: (m['duration'] as num?)?.toInt() ?? 0,
        artist: m['artist'] as String?,
      );
}

class ApkFile {
  final String name;
  final String path;
  final int size;

  const ApkFile({required this.name, required this.path, required this.size});
}

/// An installed app described as ONE item: base APK first, then every split.
class AppPackageInfo {
  final String packageName;
  final String appName;
  final String versionName;
  final int versionCode;
  final List<ApkFile> files;

  const AppPackageInfo({
    required this.packageName,
    required this.appName,
    required this.versionName,
    required this.versionCode,
    required this.files,
  });

  int get totalSize => files.fold(0, (sum, f) => sum + f.size);
}

class AppPackageApi {
  static const _channel = MethodChannel('dev.marchello.sharik/app_package');

  /// Total size (base + splits) per package name. Packages that cannot be read are omitted.
  static Future<Map<String, int>> getAppSizes(List<String> packages) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'getAppSizes',
      {'packages': packages},
    );
    return {
      for (final e in (res ?? <String, dynamic>{}).entries)
        e.key: (e.value as num).toInt()
    };
  }

  static Future<AppPackageInfo> getAppPackage(String packageName) async {
    final m = await _channel.invokeMapMethod<String, dynamic>(
      'getAppPackage',
      {'packageName': packageName},
    );
    return AppPackageInfo(
      packageName: m!['packageName'] as String,
      appName: m['appName'] as String,
      versionName: m['versionName'] as String,
      versionCode: (m['versionCode'] as num).toInt(),
      files: [
        for (final f in (m['files'] as List<dynamic>))
          ApkFile(
            name: (f as Map)['name'] as String,
            path: f['path'] as String,
            size: (f['size'] as num).toInt(),
          )
      ],
    );
  }
}

class MediaApi {
  static const _channel = MethodChannel('dev.marchello.sharik/media');

  static Future<bool> hasPermission() async =>
      (await _channel.invokeMethod<bool>('hasPermission')) ?? false;

  static Future<bool> requestPermission() async =>
      (await _channel.invokeMethod<bool>('requestPermission')) ?? false;

  static Future<List<MediaItem>> list(MediaKind kind) async {
    final res = await _channel.invokeListMethod<dynamic>(
      'list',
      {'kind': kind.name},
    );
    return [
      for (final e in (res ?? <dynamic>[])) MediaItem.fromMap(e as Map),
    ];
  }

  /// JPEG thumbnail bytes, or null when the system has none.
  static Future<Uint8List?> thumbnail(MediaKind kind, int id) =>
      _channel.invokeMethod<Uint8List>('thumbnail', {
        'kind': kind.name,
        'id': id,
      });
}

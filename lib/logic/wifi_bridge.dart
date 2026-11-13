import 'dart:io';

import 'package:flutter/services.dart';

/// Wrappers around WifiPlugin.kt (Android only: callers check `Platform.isAndroid`).

class WifiException implements Exception {
  /// permission | location_off | unsupported | hotspot_failed | join_failed | ...
  final String code;
  final String? message;

  const WifiException(this.code, [this.message]);

  @override
  String toString() => 'WifiException($code, $message)';
}

class WifiCredentials {
  final String ssid;
  final String password;

  const WifiCredentials(this.ssid, this.password);

  /// Standard Wi-Fi QR format: the phone camera understands it too.
  String get code =>
      'WIFI:T:${password.isEmpty ? 'nopass' : 'WPA'};S:${_esc(ssid)};P:${_esc(password)};;';

  static String _esc(String v) => v.replaceAllMapped(
        RegExp(r'([\;,:"])'),
        (m) => '\\${m[1]}',
      );

  /// Parses `WIFI:T:WPA;S:name;P:pass;;` (with `\;` style escapes). Null when it is not one.
  static WifiCredentials? parse(String raw) {
    final text = raw.trim();
    if (!text.toUpperCase().startsWith('WIFI:')) return null;

    final fields = <String, String>{};
    final buf = StringBuffer();
    String? key;
    var i = 5;

    void flush() {
      if (key != null) fields[key!] = buf.toString();
      key = null;
      buf.clear();
    }

    while (i < text.length) {
      final c = text[i];
      if (c == '\\' && i + 1 < text.length) {
        buf.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (key == null && c == ':') {
        key = buf.toString().toUpperCase();
        buf.clear();
      } else if (c == ';') {
        flush();
      } else {
        buf.write(c);
      }
      i++;
    }
    flush();

    final ssid = fields['S'];
    if (ssid == null || ssid.isEmpty) return null;
    return WifiCredentials(ssid, fields['P'] ?? '');
  }
}

class WifiApi {
  static const _channel = MethodChannel('dev.marchello.sharik/wifi');

  static Future<T> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      final r = await _channel.invokeMethod<T>(method, args);
      return r as T;
    } on PlatformException catch (e) {
      throw WifiException(e.code, e.message);
    }
  }

  static Future<bool> hasLocationPermission() => _call<bool>('hasLocationPermission');
  static Future<bool> requestLocationPermission() => _call<bool>('requestLocationPermission');
  static Future<bool> isLocationEnabled() => _call<bool>('isLocationEnabled');

  /// Starts a local-only hotspot (no internet) and returns its name/password.
  static Future<WifiCredentials> startHotspot() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('startHotspot');
      return WifiCredentials(m!['ssid'] as String, m['password'] as String);
    } on PlatformException catch (e) {
      throw WifiException(e.code, e.message);
    }
  }

  static Future<void> stopHotspot() => _call<void>('stopHotspot');

  /// kind: wifi | hotspot | location
  static Future<bool> openSettings(String kind) =>
      _call<bool>('openSettings', {'kind': kind});

  static Future<void> joinWifi(WifiCredentials c) =>
      _call<bool>('joinWifi', {'ssid': c.ssid, 'password': c.password});

  static Future<void> leaveWifi() => _call<void>('leaveWifi');
}

/// Names of Wi-Fi / hotspot / ethernet interfaces on Android and desktop (not mobile data).
final RegExp _lanInterface =
    RegExp(r'^(wlan|swlan|ap\d|p2p|eth|en\d|rndis|bridge|wi-?fi|hotspot|local area)', caseSensitive: false);

class LocalNetwork {
  /// Name of the first interface that has a local IPv4 address, or null when the
  /// phone is on neither Wi-Fi nor hotspot.
  static Future<String?> detect() async {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final i in list) {
      if (_lanInterface.hasMatch(i.name) && i.addresses.isNotEmpty) return i.name;
    }
    return null;
  }

  /// Every local IPv4 address of Wi-Fi / hotspot interfaces. [preferred] (the hotspot
  /// interface, when known) goes first.
  static Future<List<String>> addresses({String? preferred}) async {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final first = <String>[];
    final rest = <String>[];
    for (final i in list) {
      if (i.name != preferred && !_lanInterface.hasMatch(i.name)) continue;
      for (final a in i.addresses) {
        (i.name == preferred ? first : rest).add(a.address);
      }
    }
    return [...first, ...rest];
  }

  static Future<Set<String>> interfaceNames() async => (await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
          .map((e) => e.name)
          .toSet();
}

/// The hotspot started by the Send flow, so the sharing screen can pick its IP and stop it later.
class HotspotSession {
  static WifiCredentials? current;
  static String? interfaceName;

  static Future<void> stop() async {
    if (current == null) return;
    current = null;
    interfaceName = null;
    try {
      await WifiApi.stopHotspot();
    } catch (_) {}
  }
}

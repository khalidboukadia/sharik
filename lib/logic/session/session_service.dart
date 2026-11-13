import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../native_bridge.dart';
import 'session_models.dart';

/// A live connection between two phones. Both sides run the same code:
///  - each phone runs a small HTTP server (offers are pushed, files are pulled)
///  - `hello` introduces the scanner to the phone that showed the QR code
///  - `offer` announces an item; the other phone downloads it right away
///  - `file/<id>/<n>` streams one file of an offered item (never loaded in RAM)
/// Either phone can offer more items at any time, no new scan needed.
class SessionService extends ChangeNotifier {
  final String token;
  final String deviceName;

  SessionService({required this.token, required this.deviceName});

  static String newToken() => _randomHex(8);

  HttpServer? _server;
  Peer? peer;
  bool peerLeft = false;
  bool peerLost = false;
  bool ended = false;
  bool _disposed = false;

  /// newest first
  final List<TransferItem> items = [];
  final Map<String, TransferItem> _outgoing = {};
  final Map<String, HttpClient> _downloads = {};

  final StreamController<Peer> _peerJoined = StreamController<Peer>.broadcast();
  Stream<Peer> get onPeerJoined => _peerJoined.stream;

  Future<void> _downloadChain = Future<void>.value();
  Timer? _tickTimer;
  bool _dirty = false;
  Timer? _pingTimer;
  int _pingFails = 0;

  int get port => _server?.port ?? 0;
  bool get connected => peer != null && !peerLost && !peerLeft && !ended;

  // ------------------------------------------------------------------ server

  Future<void> start() async {
    for (final p in [50500, 50050, 0]) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        break;
      } on SocketException {
        continue;
      }
    }
    if (_server == null) throw StateError('Could not open a port');
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.headers.value('x-sharik-token') != token) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }

      final seg = req.uri.pathSegments;
      switch (seg.isEmpty ? '' : seg[0]) {
        case 'hello':
          await _onHello(req);
          break;
        case 'offer':
          await _onOffer(req);
          break;
        case 'file':
          await _onFile(req, seg);
          break;
        case 'ping':
          await _json(req, {});
          break;
        case 'bye':
          peerLeft = true;
          notifyListeners();
          await _json(req, {});
          break;
        default:
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
      }
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    return text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _json(HttpRequest req, Map<String, dynamic> body) async {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _onHello(HttpRequest req) async {
    final b = await _readJson(req);
    final ip = req.connectionInfo!.remoteAddress.address;
    _setPeer(Peer(ip, (b['port'] as num).toInt(), (b['name'] as String?) ?? ''));
    await _json(req, {'name': deviceName});
  }

  Future<void> _onOffer(HttpRequest req) async {
    final b = await _readJson(req);
    final kind = ItemKind.values.firstWhere(
      (k) => k.name == b['kind'],
      orElse: () => ItemKind.file,
    );

    final item = TransferItem(
      id: b['id'] as String,
      direction: TransferDirection.incoming,
      kind: kind,
      title: (b['title'] as String?) ?? '',
      files: [
        for (final f in (b['files'] as List<dynamic>? ?? <dynamic>[]))
          TransferFile.fromJson(f as Map),
      ],
      packageName: b['packageName'] as String?,
      versionName: b['versionName'] as String?,
      text: b['text'] as String?,
    );

    items.insert(0, item);
    if (kind == ItemKind.text) {
      item.state = TransferState.done;
    } else {
      // one download at a time keeps the link fast and the progress readable
      _downloadChain = _downloadChain.then((_) => _download(item));
    }
    notifyListeners();
    await _json(req, {});
  }

  Future<void> _onFile(HttpRequest req, List<String> seg) async {
    final item = seg.length >= 3 ? _outgoing[seg[1]] : null;
    final idx = seg.length >= 3 ? int.tryParse(seg[2]) ?? -1 : -1;

    if (item == null || idx < 0 || idx >= item.files.length) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final file = File(item.files[idx].path!);
    if (!await file.exists()) {
      item.state = TransferState.failed;
      item.error = 'missing';
      notifyListeners();
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    if (item.state == TransferState.waiting) item.state = TransferState.active;
    req.response.headers.contentType = ContentType.binary;
    req.response.contentLength = await file.length();

    try {
      await req.response.addStream(file.openRead().map((chunk) {
        item.bytes += chunk.length;
        _touch();
        return chunk;
      }));
      await req.response.close();
    } catch (_) {
      // the other phone stopped reading (cancel, lost link)
      if (item.state != TransferState.done) {
        item.state = TransferState.failed;
        item.error = 'interrupted';
      }
      notifyListeners();
      return;
    }

    if (item.bytes >= item.total) {
      item.state = TransferState.done;
      _outgoing.remove(item.id);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ client

  Future<Map<String, dynamic>> _post(
    Peer p,
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .postUrl(Uri.parse('http://${p.ip}:${p.port}/$path'))
          .timeout(timeout);
      req.headers.set('x-sharik-token', token);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));

      final resp = await req.close().timeout(timeout);
      final text = await utf8.decoder.bind(resp).join();
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('status ${resp.statusCode}');
      }
      return text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  /// Scanner side: introduce this phone to the one that showed the QR code.
  /// Tries every advertised address. Returns false when none answers.
  Future<bool> tryConnect(
    List<String> ips,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    for (final ip in ips) {
      try {
        final p = Peer(ip, port, '');
        final r = await _post(
          p,
          'hello',
          {'name': deviceName, 'port': this.port},
          timeout: timeout,
        );
        p.name = (r['name'] as String?) ?? '';
        _setPeer(p);
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  void _setPeer(Peer p) {
    final first = peer == null;
    peer = p;
    peerLost = false;
    peerLeft = false;
    _pingFails = 0;

    _pingTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => _ping());
    if (first) _peerJoined.add(p);
    notifyListeners();
  }

  Future<void> _ping() async {
    final p = peer;
    if (p == null || ended || peerLeft) return;
    try {
      await _post(p, 'ping', {}, timeout: const Duration(seconds: 3));
      _pingFails = 0;
      if (peerLost) {
        peerLost = false;
        notifyListeners();
      }
    } catch (_) {
      _pingFails++;
      if (_pingFails >= 3 && !peerLost) {
        peerLost = true;
        notifyListeners();
      }
    }
  }

  // ------------------------------------------------------------------ sending

  /// Announces items to the other phone, which starts downloading them at once.
  Future<void> offer(List<OutgoingSpec> specs) async {
    final p = peer;
    if (p == null) return;

    for (final s in specs) {
      final item = TransferItem(
        id: _randomHex(6),
        direction: TransferDirection.outgoing,
        kind: s.kind,
        title: s.title,
        files: s.files,
        packageName: s.packageName,
        versionName: s.versionName,
        text: s.text,
      );
      items.insert(0, item);
      if (item.kind != ItemKind.text) _outgoing[item.id] = item;
      notifyListeners();

      try {
        await _post(p, 'offer', {
          'id': item.id,
          'kind': item.kind.name,
          'title': item.title,
          'files': item.files.map((f) => f.toJson()).toList(),
          if (item.packageName != null) 'packageName': item.packageName,
          if (item.versionName != null) 'versionName': item.versionName,
          if (item.text != null) 'text': item.text,
        });
        if (item.kind == ItemKind.text) item.state = TransferState.done;
      } catch (e) {
        item.state = TransferState.failed;
        item.error = '$e';
        _outgoing.remove(item.id);
      }
      notifyListeners();
    }
  }

  void cancel(TransferItem item) {
    if (!item.isActive) return;
    item.cancelRequested = true;
    item.state = TransferState.canceled;

    if (item.isIncoming) {
      _downloads[item.id]?.close(force: true);
    } else {
      _outgoing.remove(item.id);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ receiving

  Future<void> _download(TransferItem item) async {
    if (item.cancelRequested || ended) return;
    final p = peer;
    if (p == null) return;

    item.state = TransferState.active;
    notifyListeners();

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _downloads[item.id] = client;
    Directory? dir;

    try {
      final root = await DeviceApi.receiveDir();
      dir = Directory('$root/${item.id}');
      await dir.create(recursive: true);
      item.dir = dir.path;

      for (var i = 0; i < item.files.length; i++) {
        final f = item.files[i];
        final req = await client.getUrl(Uri.parse('http://${p.ip}:${p.port}/file/${item.id}/$i'));
        req.headers.set('x-sharik-token', token);
        final resp = await req.close();
        if (resp.statusCode != HttpStatus.ok) {
          throw HttpException('status ${resp.statusCode}');
        }

        final dest = File('${dir.path}/${_safeName(f.name, i)}');
        final sink = dest.openWrite();
        try {
          await for (final chunk in resp) {
            sink.add(chunk);
            item.bytes += chunk.length;
            _touch();
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        if (await dest.length() != f.size) throw const FormatException('size mismatch');
        f.path = dest.path;
      }

      if (item.kind == ItemKind.file) {
        // to the public Downloads/Sharik folder; the app-private copy is then removed
        try {
          final saved = await DeviceApi.saveToDownloads(item.files.map((f) => f.path!).toList());
          if (saved == item.files.length) {
            item.savedToDownloads = true;
            await dir.delete(recursive: true);
            item.dir = null;
          }
        } catch (_) {
          // keep the files where they are: still received, just not in Downloads
        }
      }

      item.state = TransferState.done;
    } catch (e) {
      item.state = item.cancelRequested ? TransferState.canceled : TransferState.failed;
      item.error = item.cancelRequested ? null : '$e';
      try {
        await dir?.delete(recursive: true);
      } catch (_) {}
      item.dir = null;
    } finally {
      _downloads.remove(item.id);
      client.close(force: true);
      notifyListeners();
    }
  }

  String _safeName(String name, int index) {
    final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return clean.isEmpty ? 'file_$index' : clean;
  }

  /// Installs a received app (base APK + all splits in one PackageInstaller session).
  Future<void> install(TransferItem item) async {
    if (item.dir == null || item.packageName == null) return;
    item.installState = InstallState.installing;
    item.installMessage = null;
    notifyListeners();

    final r = await DeviceApi.install(item.dir!, item.packageName!);
    item.installState = r.success ? InstallState.installed : InstallState.failed;
    item.installMessage = r.message;
    notifyListeners();
  }

  // ------------------------------------------------------------------ lifecycle

  Future<void> leave() async {
    if (ended) return;
    ended = true;
    _pingTimer?.cancel();

    final p = peer;
    if (p != null && !peerLost && !peerLeft) {
      try {
        await _post(p, 'bye', {}, timeout: const Duration(seconds: 2));
      } catch (_) {}
    }

    for (final c in _downloads.values) {
      c.close(force: true);
    }
    _downloads.clear();
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  void _touch() {
    _dirty = true;
    _tickTimer ??= Timer(const Duration(milliseconds: 120), () {
      _tickTimer = null;
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tickTimer?.cancel();
    _pingTimer?.cancel();
    _peerJoined.close();
    super.dispose();
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

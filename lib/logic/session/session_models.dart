import '../wifi_bridge.dart';

enum TransferDirection { outgoing, incoming }

enum TransferState { waiting, active, done, failed, canceled }

enum ItemKind { file, app, text }

enum InstallState { none, installing, installed, failed }

class TransferFile {
  final String name;
  final int size;

  /// outgoing: where the file is read from. incoming: where it was written.
  String? path;

  TransferFile({required this.name, required this.size, this.path});

  Map<String, dynamic> toJson() => {'name': name, 'size': size};

  factory TransferFile.fromJson(Map<dynamic, dynamic> m) => TransferFile(
        name: m['name'] as String,
        size: (m['size'] as num).toInt(),
      );
}

/// One thing sent or received. An app is ONE item whatever its number of split APKs.
class TransferItem {
  final String id;
  final TransferDirection direction;
  final ItemKind kind;
  final String title;
  final List<TransferFile> files;
  final String? packageName;
  final String? versionName;
  final String? text;

  int bytes = 0;
  TransferState state = TransferState.waiting;
  String? error;

  /// incoming files: copied to Downloads/Sharik
  bool savedToDownloads = false;

  /// incoming: folder holding the received files (kept for apps, so they can be installed)
  String? dir;

  InstallState installState = InstallState.none;
  String? installMessage;
  bool cancelRequested = false;

  TransferItem({
    required this.id,
    required this.direction,
    required this.kind,
    required this.title,
    required this.files,
    this.packageName,
    this.versionName,
    this.text,
  });

  int get total => files.fold(0, (sum, f) => sum + f.size);

  double get progress {
    if (state == TransferState.done) return 1;
    final t = total;
    return t == 0 ? 0 : (bytes / t).clamp(0.0, 1.0).toDouble();
  }

  bool get isIncoming => direction == TransferDirection.incoming;
  bool get isActive =>
      state == TransferState.active || state == TransferState.waiting;
}

/// What the user asked to send, before it gets an id and a direction.
class OutgoingSpec {
  final ItemKind kind;
  final String title;
  final List<TransferFile> files;
  final String? packageName;
  final String? versionName;
  final String? text;

  const OutgoingSpec({
    required this.kind,
    required this.title,
    this.files = const [],
    this.packageName,
    this.versionName,
    this.text,
  });
}

class Peer {
  final String ip;
  final int port;
  String name;

  Peer(this.ip, this.port, this.name);
}

/// The content of the QR code shown by the receiver:
/// `sharik://join?ip=..&port=..&t=..&n=..[&s=ssid&p=password]`
class JoinCode {
  /// every address the receiver may be reached on (the scanner tries them in turn)
  final List<String> ips;
  final int port;
  final String token;
  final String name;
  final WifiCredentials? wifi;

  const JoinCode({
    required this.ips,
    required this.port,
    required this.token,
    required this.name,
    this.wifi,
  });

  String get uri => Uri(
        scheme: 'sharik',
        host: 'join',
        queryParameters: {
          'ip': ips.join(','),
          'port': '$port',
          't': token,
          'n': name,
          if (wifi != null) 's': wifi!.ssid,
          if (wifi != null) 'p': wifi!.password,
        },
      ).toString();

  static JoinCode? parse(String raw) {
    try {
      final u = Uri.parse(raw.trim());
      if (u.scheme != 'sharik' || u.host != 'join') return null;
      final q = u.queryParameters;

      final ips = (q['ip'] ?? '').split(',').where((e) => e.isNotEmpty).toList();
      final port = int.tryParse(q['port'] ?? '');
      final token = q['t'];
      if (ips.isEmpty || port == null || token == null || token.isEmpty) {
        return null;
      }

      final ssid = q['s'];
      return JoinCode(
        ips: ips,
        port: port,
        token: token,
        name: q['n'] ?? '',
        wifi: ssid == null || ssid.isEmpty
            ? null
            : WifiCredentials(ssid, q['p'] ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}

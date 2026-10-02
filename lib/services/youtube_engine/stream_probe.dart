import 'package:dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';

/// TEMPORARY diagnostics for the iOS stream 403 investigation.
///
/// Logs, for every request the playback proxy sends to a stream URL: which use
/// of that URL it is, how old the URL is, the host and path, the NAMES of the
/// query parameters (values only for a short list of harmless ones), the
/// User-Agent and Range sent, and the status that came back. Nothing that
/// identifies a session is logged: no full URL, no signature/token values, no
/// cookies.
class StreamProbe {
  static const _tag = '[403probe]';

  /// Query parameters whose values are not secret and help tell streams apart.
  static const _plain = {
    'c',
    'itag',
    'mime',
    'ratebypass',
    'source',
    'requiressl',
    'clen',
    'dur',
  };

  static final _firstSeen = <int, DateTime>{};
  static final _uses = <int, int>{};

  static String describe(String url) {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return 'unparseable-url';
    }
    final p = uri.queryParameters;
    final expire = int.tryParse(p['expire'] ?? '');
    final expireIn = expire == null
        ? '-'
        : '${expire - DateTime.now().millisecondsSinceEpoch ~/ 1000}s';
    final shown = {
      for (final k in _plain)
        if (p.containsKey(k)) k: p[k],
    };
    final names = p.keys.toList()..sort();
    return 'host=${uri.host} path=${uri.path} $shown expireIn=$expireIn '
        'has(n)=${p.containsKey('n')} has(pot)=${p.containsKey('pot')} '
        'has(sig)=${p.containsKey('sig')} has(sabr)=${p.containsKey('sabr')} '
        'paramNames=$names';
  }

  /// "use#<n> age=<s>s": which use of this URL this is (a request counts it,
  /// its response does not) and how long ago the URL was first seen.
  static String _use(String url, {bool count = true}) {
    final key = url.hashCode;
    final now = DateTime.now();
    final first = _firstSeen.putIfAbsent(key, () => now);
    final n = count
        ? _uses.update(key, (v) => v + 1, ifAbsent: () => 1)
        : (_uses[key] ?? 0);
    return 'use#$n age=${now.difference(first).inSeconds}s';
  }

  static void manifest(String clients, Iterable<Uri> urls) {
    final list = urls.toList();
    AppLogger.log.i(
      '$_tag manifest clients=$clients streams=${list.length}'
      '${list.isEmpty ? '' : ' first: ${describe(list.first.toString())}'}',
    );
  }

  static void note(String message) => AppLogger.log.i('$_tag $message');

  static void request(RequestOptions o) {
    final h = o.headers;
    AppLogger.log.i(
      '$_tag → ${o.method} ${_use(o.uri.toString())} ${describe(o.uri.toString())} '
      'ua="${h['user-agent'] ?? '<dart default>'}" range="${h['range'] ?? '-'}" '
      'accept="${h['accept'] ?? '-'}" headerNames=${h.keys.toList()..sort()}',
    );
  }

  static void response(RequestOptions o, int? status, {Object? error}) {
    AppLogger.log.i(
      '$_tag ← ${o.method} status=$status${error == null ? '' : ' error=$error'} '
      '${_use(o.uri.toString(), count: false)} ua="${o.headers['user-agent'] ?? '<dart default>'}"',
    );
  }

  static Interceptor get interceptor => InterceptorsWrapper(
        onRequest: (o, handler) {
          request(o);
          handler.next(o);
        },
        onResponse: (r, handler) {
          response(r.requestOptions, r.statusCode);
          handler.next(r);
        },
        onError: (e, handler) {
          response(e.requestOptions, e.response?.statusCode, error: e.type);
          handler.next(e);
        },
      );
}

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/stream_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real sockets, to a local server

  final secrets = [
    'SIGSECRET',
    'NSECRET',
    'POTSECRET',
    'IPSECRET',
    'LSIGSECRET'
  ];
  String url(String host) => 'http://$host/videoplayback?c=ANDROID&itag=251'
      '&mime=audio%2Fwebm&ratebypass=yes&expire=${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 21000}'
      '&sig=SIGSECRET&n=NSECRET&pot=POTSECRET&ip=IPSECRET&lsig=LSIGSECRET';

  test('describe keeps secrets out and shows what matters', () {
    final text = StreamProbe.describe(url('rr1.googlevideo.com'));
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains('host=rr1.googlevideo.com'));
    expect(text, contains('c: ANDROID'));
    expect(text, contains('itag: 251'));
    expect(text, contains('has(n)=true'));
    expect(text, contains('has(pot)=true'));
    expect(text, contains('expireIn='));
  });

  test('the interceptor logs request and status, without secrets', () async {
    AppLogger.initialize(false);
    final lines = <String>[];
    void listen(OutputEvent e) => lines.addAll(e.lines);
    Logger.addOutputListener(listen);
    addTearDown(() => Logger.removeOutputListener(listen));

    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) {
      req.response.statusCode = req.method == 'HEAD' ? 403 : 200;
      req.response.close();
    });
    final dio = Dio()..interceptors.add(StreamProbe.interceptor);
    final u = url('127.0.0.1:${server.port}');
    await dio
        .head(u,
            options:
                Options(headers: {'user-agent': 'UA-A', 'range': 'bytes=0-'}))
        .catchError(
            (_) => Response(requestOptions: RequestOptions(), statusCode: 0));
    await dio.get(u, options: Options(headers: {'user-agent': null}));
    await server.close(force: true);

    final text = lines.join('\n');
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains('→ HEAD use#1'));
    expect(text, contains('ua="UA-A"'));
    expect(text, contains('← HEAD status=403'));
    expect(text,
        isNot(contains('use#2 age=0s ua="UA-A"'))); // a response is not a use
    expect(text, contains('→ GET use#2'));
    expect(text, contains('→ GET use#'));
    expect(text, contains('ua="<dart default>"'));
    expect(text, contains('← GET status=200'));
  });
}

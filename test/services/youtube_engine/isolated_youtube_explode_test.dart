import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// No network is used: an invalid video id is rejected by YoutubeExplode before
/// any request is made, which is enough to make a request throw inside the
/// worker isolate.
void main() {
  late IsolatedYoutubeExplode isolated;

  setUpAll(() async {
    await IsolatedYoutubeExplode.initialize();
    isolated = IsolatedYoutubeExplode.instance;
  });

  tearDownAll(() => isolated.dispose());

  test('a request that throws in the isolate fails instead of waiting forever',
      () async {
    await expectLater(
      // The timeout only makes a hang fail this test quickly.
      isolated.manifest('not a video id').timeout(const Duration(seconds: 10)),
      throwsA(isA<YoutubeExplodeException>()),
    );
  });

  test('the isolate still answers after a request failed', () async {
    for (final request in [
      () => isolated.manifest('not a video id'),
      () => isolated.video('not a video id'),
      () => isolated.manifest('still not a video id'),
    ]) {
      await expectLater(
        request().timeout(const Duration(seconds: 10)),
        throwsA(isA<YoutubeExplodeException>()),
      );
    }
  });
}

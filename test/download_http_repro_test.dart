import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/modules/download/download_module.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const baseline = bool.fromEnvironment('BASELINE');
  late Directory root;
  late HttpServer server;
  late List<int> sample;
  final requests = <String>[];
  final evidence = <String>[];
  late String origin;

  setUpAll(() async {
    root = await Directory('../verification')
        .createTemp('m3u8-http-${baseline ? 'baseline' : 'fixed'}-');
    PathProviderPlatform.instance = _Paths(root.absolute.path);
    Hive.init('${root.path}/hive');
    await GStorage.init();
    sample = await File('../verification/m3u8-check/sample.ts').readAsBytes();
    expect(sample.length, greaterThan(188));
    expect(sample.first, 0x47);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final target = request.uri.toString();
      requests.add(target);
      String? playlist;
      if (target == '/control/main.m3u8') {
        playlist = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n';
      } else if (target == '/query/main.m3u8?token=a/b') {
        playlist = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n';
      } else if (target == '/cdn/main.m3u8') {
        playlist = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\n//127.0.0.1:${server.port}/cdn/segment.ts\n#EXT-X-ENDLIST\n';
      } else if (target == '/master/main.m3u8') {
        playlist = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\n//127.0.0.1:${server.port}/control/main.m3u8\n';
      }
      if (playlist != null) {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write(playlist);
      } else if (['/control/segment.ts', '/query/segment.ts', '/cdn/segment.ts'].contains(target)) {
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.add(sample);
      } else {
        request.response.statusCode = 404;
        request.response.write('unexpected resource');
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    await Hive.close();
    await File('${root.path}/evidence.txt').writeAsString(evidence.join('\n'));
    print('Evidence and downloaded files: ${root.absolute.path}');
  });

  for (final scenario in ['control', 'query', 'cdn', 'master']) {
    test('actual DownloadManager HTTP download: $scenario', () async {
      requests.clear();
      final episode = DownloadEpisode(1, scenario, 0, DownloadStatus.pending,
          0, 0, 0, '', '', '', null, '', 0, '');
      final manager = DownloadManager();
      final done = Completer<void>();
      manager.onProgress = (_, __, ep, ___) {
        if ((ep.status == DownloadStatus.completed || ep.status == DownloadStatus.failed) && !done.isCompleted) {
          done.complete();
        }
      };
      final url = '$origin/$scenario/main.m3u8${scenario == 'query' ? '?token=a/b' : ''}';
      await manager.enqueue(DownloadRequest(recordKey: scenario, bangumiId: 1,
          pluginName: scenario, episodeNumber: 1, m3u8Url: url,
          httpHeaders: {}, adBlockerEnabled: false, episode: episode));
      await done.future.timeout(const Duration(seconds: 45));
      final expectedSuccess = !baseline || scenario == 'control';
      final line = '$scenario status=${episode.status} bytes=${episode.totalBytes} error=${episode.errorMessage} requests=$requests';
      print(line);
      evidence.add(line);
      expect(episode.status, expectedSuccess ? DownloadStatus.completed : DownloadStatus.failed);
      if (expectedSuccess) {
        final saved = File('${episode.downloadDirectory}/seg_00000.ts');
        expect(await saved.readAsBytes(), orderedEquals(sample));
        expect(await File(episode.localM3u8Path).readAsString(), contains('seg_00000.ts'));
        expect(episode.totalBytes, sample.length);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}

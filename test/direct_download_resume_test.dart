import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late HttpOverrides? originalHttpOverrides;
  late HttpServer server;
  late List<int> payload;
  final ranges = <String?>[];
  const prefixLength = 1024;

  setUpAll(() async {
    Logger.level = Level.off;
    originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('kazumi_direct_resume_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
    final fixture = Platform.environment['DOWNLOAD_TEST_VIDEO'];
    payload = fixture == null
        ? List.generate(16384, (index) => index % 251)
        : await File(fixture).readAsBytes();
    expect(payload.length, greaterThan(prefixLength));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final response = request.response;
      response.headers.contentType = ContentType('video', 'mp4');
      if (request.uri.path == '/partial.mp4' && range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $prefixLength-${payload.length - 1}/${payload.length}',
        );
        response.contentLength = payload.length - prefixLength;
        response.add(payload.sublist(prefixLength));
      } else if (request.uri.path == '/unsatisfiable.mp4' && range != null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${payload.length}',
        );
      } else {
        response.contentLength = payload.length;
        response.add(payload);
      }
      await response.close();
    });
  });

  setUp(() => ranges.clear());

  tearDownAll(() async {
    DioFactory.reset();
    await server.close(force: true);
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalHttpOverrides;
    expect(
      root.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      isTrue,
    );
    expect(
      root.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('kazumi_direct_resume_'),
    );
    await root.delete(recursive: true);
  });

  Future<void> download(String scenario, {required bool resume}) async {
    final directory = await Directory('${root.path}/$scenario').create();
    if (resume) {
      await File('${directory.path}/video.mp4.tmp')
          .writeAsBytes(payload.sublist(0, prefixLength));
    }
    final episode = DownloadEpisode(
      1,
      scenario,
      0,
      DownloadStatus.paused,
      0,
      0,
      0,
      '',
      directory.path,
      '',
      null,
      '',
      0,
      '',
    );
    final request = DownloadRequest(
      recordKey: scenario,
      bangumiId: 1,
      pluginName: scenario,
      episodeNumber: 1,
      m3u8Url: 'http://127.0.0.1:${server.port}/$scenario.mp4',
      httpHeaders: {},
      adBlockerEnabled: false,
      episode: episode,
    );
    final manager = DownloadManager();
    final finished = Completer<void>();
    manager.onProgress = (_, _, current, _) {
      if ((current.status == DownloadStatus.completed ||
              current.status == DownloadStatus.failed) &&
          !finished.isCompleted) {
        finished.complete();
      }
    };
    if (resume) {
      await manager.resume(request);
    } else {
      await manager.enqueue(request);
    }
    await finished.future.timeout(const Duration(seconds: 20));
    expect(
      episode.status,
      DownloadStatus.completed,
      reason: episode.errorMessage,
    );
    expect(
      ranges,
      resume
          ? [
              null,
              'bytes=$prefixLength-',
              if (scenario == 'unsatisfiable') null,
            ]
          : [null, null],
    );
    final saved = File(episode.localM3u8Path);
    final evidenceDirectory = Platform.environment['DOWNLOAD_TEST_OUTPUT'];
    if (evidenceDirectory != null) {
      await Directory(evidenceDirectory).create(recursive: true);
      await saved.copy('$evidenceDirectory/$scenario.mp4');
    }
    expect(await saved.length(), payload.length);
    expect(await saved.readAsBytes(), orderedEquals(payload));
    expect(episode.totalBytes, payload.length);
    expect(episode.progressPercent, 1.0);
    expect(await File('${directory.path}/video.mp4.tmp').exists(), isFalse);
  }

  test(
    'fresh full response downloads the exact file',
    () => download('fresh', resume: false),
  );
  test(
    '206 response resumes without duplicating the prefix',
    () => download('partial', resume: true),
  );
  test(
    '200 response to Range replaces the incomplete file',
    () => download('ignored', resume: true),
  );
  test(
    '416 response retries from the beginning',
    () => download('unsatisfiable', resume: true),
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('queued video completes but loses already fetched offline comments', () async {
    Logger.level = Level.off;
    final previousHttp = HttpOverrides.current;
    final previousPaths = PathProviderPlatform.instance;
    HttpOverrides.global = null;
    final root = await Directory.systemTemp.createTemp('kazumi_queue_probe_');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.downloadParallelEpisodes, 1);
    await GStorage.putSetting(SettingsKeys.downloadDanmaku, true);
    final payload = await File(Platform.environment['DOWNLOAD_TEST_TS']!)
        .readAsBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final slowStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final commentsFetched = <int, DateTime>{};
    var offline = false;
    final repository = DownloadRepository();
    final manager = DownloadManager();
    final plugins = PluginsController()
      ..pluginList.add(
        Plugin.fromJson({
          'name': 'queue-probe',
          'baseURL': 'http://127.0.0.1:${server.port}',
        }),
      );
    final controller = DownloadController(repository, manager, plugins);
    final completed = Completer<void>();
    final notifications = <String>[];
    const recordKey = 'queue-probe_123';

    DioFactory.apiDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (offline) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'verification: network disconnected',
              ),
            );
            return;
          }
          if (options.uri.host != 'api.dandanplay.net') {
            handler.reject(DioException(requestOptions: options));
            return;
          }
          if (options.uri.path.contains('/bgmtv/')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'bangumi': {'animeId': 456, 'episodes': []},
                  'errorCode': 0,
                  'success': true,
                  'errorMessage': '',
                },
              ),
            );
          } else {
            final episode = int.parse(options.uri.path.split('/').last) % 10000;
            commentsFetched[episode] = DateTime.now();
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'comments': [
                    {
                      'm': 'episode $episode comment',
                      'p': '1,1,16777215,probe',
                    },
                  ],
                },
              ),
            );
          }
        },
      ),
    );
    VideoWebviewControllerFactory.verificationFactory = () =>
        _ResolvedWebView();
    server.listen((request) async {
      if (request.uri.path.endsWith('.m3u8')) {
        final segment = request.uri.path.startsWith('/1')
            ? 'first.ts'
            : 'second.ts';
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
          '#EXTINF:2,\n$segment\n#EXT-X-ENDLIST\n',
        );
      } else {
        request.response.contentLength = payload.length;
        if (request.uri.path == '/first.ts') {
          if (!slowStarted.isCompleted) slowStarted.complete();
          var sent = 0;
          // Keep the connection active while the second episode waits in queue.
          while (!releaseFirst.isCompleted) {
            request.response.add(payload.sublist(sent, sent + 16));
            sent += 16;
            await request.response.flush();
            await Future.any([
              releaseFirst.future,
              Future<void>.delayed(const Duration(seconds: 2)),
            ]);
          }
          request.response.add(payload.sublist(sent));
        } else {
          request.response.add(payload);
        }
      }
      await request.response.close();
    });
    try {
      await controller.init();
      final controllerProgress = manager.onProgress!;
      manager.onProgress = (key, number, episode, speed) {
        controllerProgress(key, number, episode, speed);
        notifications.add('$number:${episode.status}');
        if (episode.status == DownloadStatus.failed && !completed.isCompleted) {
          completed.completeError(StateError(episode.errorMessage));
        }
        if (number == 2 &&
            episode.status == DownloadStatus.completed &&
            !completed.isCompleted) {
          completed.complete();
        }
      };
      Future<void> start(int number) => controller.startDownload(
        bangumiId: 123,
        bangumiName: 'queue reproduction',
        bangumiCover: '',
        pluginName: 'queue-probe',
        episodeNumber: number,
        episodeName: 'episode $number',
        road: 0,
        episodePageUrl: '/$number.m3u8',
      );
      await start(1);
      await slowStarted.future.timeout(const Duration(seconds: 10));
      await start(2);
      await _until(() => commentsFetched.length == 2);
      await _until(() {
        final first = repository.getRecord(recordKey)?.episodes[1];
        return first != null &&
            File('${first.downloadDirectory}/danmaku.json').existsSync();
      });
      final fetchedAt = commentsFetched[2]!;
      final remaining =
          const Duration(seconds: 33) - DateTime.now().difference(fetchedAt);
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      final queued = repository.getRecord(recordKey)!.episodes[2]!;
      expect(queued.status, DownloadStatus.pending);
      expect(queued.downloadDirectory, isEmpty);
      releaseFirst.complete();
      await completed.future.timeout(const Duration(seconds: 15));
      final record = repository.getRecord(recordKey)!;
      for (final number in [1, 2]) {
        expect(record.episodes[number]!.status, DownloadStatus.completed);
        expect(
          await File(
            '${record.episodes[number]!.downloadDirectory}/seg_00000.ts',
          ).readAsBytes(),
          payload,
        );
      }
      final firstComments = await controller.getCachedDanmakus(
        123,
        'queue-probe',
        1,
      );
      final secondComments = await controller.getCachedDanmakus(
        123,
        'queue-probe',
        2,
      );
      expect(firstComments?.single.message, 'episode 1 comment');
      expect(secondComments, isNull);
      offline = true;
      final player = PlayerDanmakuController(
        isLocalPlayback: () => true,
        downloadController: controller,
      );
      final firstPlayback = await player.fetchDanmaku(123, 'queue-probe', 1);
      final secondPlayback = await player.fetchDanmaku(123, 'queue-probe', 2);
      expect(firstPlayback.status, DanmakuLoadStatus.success);
      expect(secondPlayback.status, DanmakuLoadStatus.failed);
      final evidence = {
        'upstream': '4e821e48282d0e8e3753fd6266bb1d15e4dc0f02',
        'queueWaitSeconds':
            DateTime.now().difference(fetchedAt).inMilliseconds / 1000,
        'apiCommentResponses': commentsFetched.length,
        'firstVideoCompleted':
            record.episodes[1]!.status == DownloadStatus.completed,
        'secondVideoCompleted':
            record.episodes[2]!.status == DownloadStatus.completed,
        'firstOfflineDanmakuStatus': firstPlayback.status.name,
        'secondOfflineDanmakuStatus': secondPlayback.status.name,
        'firstCachedComments': firstComments?.length ?? 0,
        'secondCachedComments': secondComments?.length ?? 0,
        'notifications': notifications,
        'limitations': 'WebView URL resolution and DanDan API responses are substituted; controller, resolver pool, manager, Dio video downloads, Hive and filesystem are production code.',
      };
      final output = Platform.environment['DOWNLOAD_TEST_OUTPUT']!;
      await Directory(output).create(recursive: true);
      await File('$output/result.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
      for (final number in [1, 2]) {
        final dir = record.episodes[number]!.downloadDirectory;
        for (final file in Directory(dir).listSync().whereType<File>()) {
          await file.copy(
            '$output/episode-$number-${file.uri.pathSegments.last}',
          );
        }
      }
      // Diagnostic reproduction, not a regression test expecting correct behavior.
      // ignore: avoid_print
      print(jsonEncode(evidence));
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      manager.cancel(recordKey, 1);
      manager.cancel(recordKey, 2);
      VideoWebviewControllerFactory.verificationFactory = null;
      DioFactory.reset();
      await server.close(force: true);
      await Hive.close();
      PathProviderPlatform.instance = previousPaths;
      HttpOverrides.global = previousHttp;
      expect(
        root.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        isTrue,
      );
      expect(
        root.uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('kazumi_queue_probe_'),
      );
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline))
      throw StateError('probe setup timed out');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final String directory;
  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

class _ResolvedWebView extends VideoWebviewController<Object> {
  @override
  Future<void> init() async {}
  @override
  Future<void> loadUrl(
    String url,
    bool useLegacyParser, {
    int offset = 0,
  }) async {
    // Emit after the production resolver attaches its stream listener.
    Timer.run(() => notifyVideoSourceResolved(url));
  }

  @override
  Future<void> unloadPage() async {}
  @override
  Future<void> dispose() async => disposeEventControllers();
}

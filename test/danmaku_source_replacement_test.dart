import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late PlayerDanmakuController controller;
  late _CommentsAdapter adapter;
  late DanmakuEntry previous;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_danmaku_switch_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.putSetting(SettingsKeys.danmakuDeduplication, false);
    DioFactory.reset();
    adapter = _CommentsAdapter();
    DioFactory.apiDio.httpClientAdapter.close();
    DioFactory.apiDio.httpClientAdapter = adapter;
    controller = PlayerDanmakuController(
      isLocalPlayback: () => false,
      downloadController: _UnusedDownloads(),
    );
    previous = DanmakuEntry(
      message: 'previous-source',
      time: 10,
      type: 1,
      color: Colors.white,
      source: '[BiliBili]',
    );
    controller.danDanmakus[10] = [previous];
    controller.setDanmakuEnabled(true);
  });

  tearDownAll(() async {
    DioFactory.apiDio.close(force: true);
    DioFactory.reset();
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      isTrue,
    );
    expect(
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('kazumi_danmaku_switch_'),
    );
    await directory.delete(recursive: true);
  });

  test(
    'failed source request preserves current comments and permits retry',
    () async {
      adapter.respond = (_) async => ResponseBody.fromString('', 503);
      await expectLater(
        controller.getDanDanmakuByEpisodeID(1),
        throwsA(isA<NetworkException>()),
      );

      expect(controller.danDanmakus.keys, [10]);
      expect(controller.danDanmakus[10]!.single, same(previous));
      expect(controller.danmakuOn, isTrue);
      expect(controller.danmakuLoading, isFalse);

      adapter.respond = (_) async => _comments();
      expect(await controller.getDanDanmakuByEpisodeID(2), isTrue);
      expect(controller.danDanmakus.keys, [20]);
      expect(controller.danDanmakus[20]!.single.message, 'replacement-source');
      expect(controller.danmakuLoading, isFalse);
    },
  );

  test(
    'pending source request retains old comments until it completes',
    () async {
      final entered = Completer<void>();
      final response = Completer<ResponseBody>();
      adapter.respond = (_) {
        entered.complete();
        return response.future;
      };
      final pending = controller.getDanDanmakuByEpisodeID(1);
      await entered.future;
      expect(controller.danmakuLoading, isTrue);
      expect(controller.danDanmakus[10]!.single, same(previous));

      response.complete(_comments());
      expect(await pending, isTrue);
      expect(controller.danDanmakus.keys, [20]);
      expect(controller.danmakuLoading, isFalse);
    },
  );

  test(
    'successful empty source clears old comments and returns false',
    () async {
      adapter.respond = (_) async => _comments(empty: true);
      expect(await controller.getDanDanmakuByEpisodeID(1), isFalse);
      expect(controller.danDanmakus, isEmpty);
      expect(controller.danmakuLoading, isFalse);
    },
  );
}

ResponseBody _comments({bool empty = false}) => ResponseBody.fromString(
  jsonEncode({
    'comments': empty
        ? <Map<String, String>>[]
        : [
            {'m': 'replacement-source', 'p': '20,1,16777215,[BiliBili]'},
          ],
  }),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _CommentsAdapter implements HttpClientAdapter {
  Future<ResponseBody> Function(RequestOptions) respond = (_) async =>
      _comments();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => respond(options);

  @override
  void close({bool force = false}) {}
}

class _UnusedDownloads implements DownloadController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

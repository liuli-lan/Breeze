import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/utils/github_proxy.dart';

/// 下载源档位。
///
/// 依据方案 §5.1：**镜像做成可配置，不硬编码**。硬编码镜像在镜像站失效时会变成
/// 新的故障源，而部分用户挂着代理时反而直连更快。
enum MangaJaNaiDownloadSource {
  /// 自动：优先镜像，失败自动切官方源重试（用户不需要自己试）。
  auto,

  /// 官方源：pypi.org / download.pytorch.org / github.com。
  official,

  /// 镜像源：清华 TUNA（PyPI + pytorch-wheels）与 gh-proxy（GitHub Release）。
  mirror;

  String get label => switch (this) {
    MangaJaNaiDownloadSource.auto => t.realSr.mangaJaNaiDownloadSourceAuto,
    MangaJaNaiDownloadSource.official =>
      t.realSr.mangaJaNaiDownloadSourceOfficial,
    MangaJaNaiDownloadSource.mirror => t.realSr.mangaJaNaiDownloadSourceMirror,
  };

  String get description => switch (this) {
    MangaJaNaiDownloadSource.auto => t.realSr.mangaJaNaiDownloadSourceAutoNote,
    MangaJaNaiDownloadSource.official =>
      t.realSr.mangaJaNaiDownloadSourceOfficialNote,
    MangaJaNaiDownloadSource.mirror =>
      t.realSr.mangaJaNaiDownloadSourceMirrorNote,
  };

  /// 是否优先用镜像。
  bool get preferMirror => this != MangaJaNaiDownloadSource.official;

  /// 镜像失败后是否允许回退官方源。
  ///
  /// 「镜像」档也允许回退：用户选它多半是因为官方源不通，若镜像恰好失效，
  /// 直接失败会让用户彻底无法安装，而回退只多花一次重试。
  bool get allowOfficialFallback => this != MangaJaNaiDownloadSource.official;
}

/// 镜像与源地址配置（用户可覆写，落在 [RealSrSettings] 里）。
class MangaJaNaiMirrorConfig {
  const MangaJaNaiMirrorConfig({
    required this.pypiIndexUrl,
    required this.torchIndexUrl,
    required this.useGithubMirror,
  });

  /// 与容器 Dockerfile 里 `PIP_INDEX_URL` 对齐的默认镜像（纯一致性问题）。
  static const String defaultPypiIndexUrl =
      'https://pypi.tuna.tsinghua.edu.cn/simple';

  /// torch 的镜像：官方 `download.pytorch.org` 没有国内镜像，TUNA 的
  /// pytorch-wheels 是已知可行的替代。**cu128 覆盖情况需实测**，因此这里只是
  /// 默认值，用户可改；失败时「自动/镜像」档会自动回退官方索引。
  static const String defaultTorchIndexUrl =
      'https://mirrors.tuna.tsinghua.edu.cn/pytorch-wheels/cu128';

  static const String officialPypiIndexUrl = 'https://pypi.org/simple';
  static const String officialTorchIndexUrl =
      'https://download.pytorch.org/whl/cu128';

  final String pypiIndexUrl;
  final String torchIndexUrl;

  /// GitHub Release 是否走 `mirrorBaseUrls`（复用应用既有的 gh-proxy 列表）。
  final bool useGithubMirror;

  static const MangaJaNaiMirrorConfig defaults = MangaJaNaiMirrorConfig(
    pypiIndexUrl: defaultPypiIndexUrl,
    torchIndexUrl: defaultTorchIndexUrl,
    useGithubMirror: true,
  );

  /// pip 依赖阶段的候选 `--index-url` 列表，按顺序尝试。
  List<String> pypiIndexCandidates(MangaJaNaiDownloadSource source) {
    final mirror = pypiIndexUrl.trim();
    return switch (source) {
      MangaJaNaiDownloadSource.official => const [officialPypiIndexUrl],
      _ => [
        if (mirror.isNotEmpty && mirror != officialPypiIndexUrl) mirror,
        if (source.allowOfficialFallback) officialPypiIndexUrl,
      ],
    };
  }

  /// torch / torchvision 阶段的候选 `--index-url` 列表，按顺序尝试。
  List<String> torchIndexCandidates(MangaJaNaiDownloadSource source) {
    final mirror = torchIndexUrl.trim();
    return switch (source) {
      MangaJaNaiDownloadSource.official => const [officialTorchIndexUrl],
      _ => [
        if (mirror.isNotEmpty && mirror != officialTorchIndexUrl) mirror,
        if (source.allowOfficialFallback) officialTorchIndexUrl,
      ],
    };
  }

  /// GitHub 直链是否需要展开成「镜像 → 直连」的候选列表。
  bool githubMirrorEnabledFor(MangaJaNaiDownloadSource source) =>
      useGithubMirror && source.preferMirror;
}

/// 安装被用户取消。
class MangaJaNaiInstallCancelled implements Exception {
  const MangaJaNaiInstallCancelled();

  @override
  String toString() => '已取消';
}

/// 取消令牌。
///
/// 两个作用点：阶段之间（[throwIfCancelled]）与下载中（[addListener] 让下载器
/// 强制关闭连接，`.part` 保留下来供下次续传）。
class MangaJaNaiCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // 复制一份再回调：监听器可能在回调里自我移除。
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } on Object catch (e) {
        logger.w('取消回调失败', error: e);
      }
    }
    _listeners.clear();
  }

  /// 注册取消回调，返回注销函数。
  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const MangaJaNaiInstallCancelled();
  }
}

/// 失败分类（方案 §5 第 6 条：失败信息要能分类，而不是把原始异常直接抛给用户）。
enum MangaJaNaiFailureKind {
  /// 网络 / 连接 / HTTP 状态码。
  network,

  /// 磁盘（空间不足、写入失败）。
  disk,

  /// 显卡驱动 / CUDA。
  driver,

  /// 权限（文件被占用、无写入权限）。
  permission,

  /// 用户取消。
  cancelled,

  /// 其余。
  unknown,
}

/// 安装/下载失败的统一异常，供 UI 按 [kind] 给出可读结论。
class MangaJaNaiInstallException implements Exception {
  const MangaJaNaiInstallException({
    required this.kind,
    required this.message,
    this.detail,
  });

  final MangaJaNaiFailureKind kind;
  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

/// 把任意异常归类成 [MangaJaNaiInstallException]。
///
/// 判定以异常类型为主、文本为辅：Windows 的磁盘满 / 权限问题在不同 API 下分别
/// 表现为 `FileSystemException`、`OSError(112)`、`ProcessException`，
/// 光看类型区分不了。
MangaJaNaiInstallException classifyInstallError(
  Object error, {
  String? detail,
}) {
  if (error is MangaJaNaiInstallCancelled) {
    return const MangaJaNaiInstallException(
      kind: MangaJaNaiFailureKind.cancelled,
      message: '安装已取消',
    );
  }
  if (error is MangaJaNaiInstallException) return error;

  final text = '$error${detail == null ? '' : '\n$detail'}'.toLowerCase();

  if (error is SocketException ||
      error is HttpException ||
      error is TimeoutException ||
      error is HandshakeException ||
      text.contains('connection') ||
      text.contains('timed out') ||
      text.contains('http ') ||
      text.contains('socket')) {
    return MangaJaNaiInstallException(
      kind: MangaJaNaiFailureKind.network,
      message: '网络错误：下载或连接失败',
      detail: '$error',
    );
  }

  if (text.contains('no space') ||
      text.contains('disk full') ||
      text.contains('not enough space') ||
      text.contains('os error 112')) {
    return MangaJaNaiInstallException(
      kind: MangaJaNaiFailureKind.disk,
      message: '磁盘空间不足',
      detail: '$error',
    );
  }

  if (text.contains('access is denied') ||
      text.contains('permission denied') ||
      text.contains('being used by another process') ||
      text.contains('os error 5') ||
      text.contains('os error 32')) {
    return MangaJaNaiInstallException(
      kind: MangaJaNaiFailureKind.permission,
      message: '文件被占用或无写入权限',
      detail: '$error',
    );
  }

  // 注意：不要只匹配 'nvml' —— `pynvml` 只是一个普通 PyPI 包名，
  // pip 输出里出现它并不代表 GPU/CUDA 初始化失败。
  if (text.contains('cuda init') ||
      text.contains('cuda error') ||
      text.contains('nvidia driver') ||
      text.contains('cudnn')) {
    return MangaJaNaiInstallException(
      kind: MangaJaNaiFailureKind.driver,
      message: 'CUDA / 显卡环境异常',
      detail: '$error',
    );
  }

  return MangaJaNaiInstallException(
    kind: MangaJaNaiFailureKind.unknown,
    message: '安装失败',
    detail: '$error',
  );
}

/// 断点续传下载器。
///
/// ## 为什么不用 `WindHttp().download`
///
/// `WindHttp` 走 Rust 侧 reqwest，支持进度但**不支持续传**：它不暴露响应码，
/// 也就无法判断服务器是否接受了 `Range` —— 而「服务器忽略 Range」时若仍按追加
/// 写入，会把两次响应拼成一个坏文件。这里改用 `dart:io` 的 [HttpClient]：
///
/// - 能显式发 `Range` 并读响应码：`206` → 追加，`200` → 从头写（安全）；
/// - `flutter_socks_proxy` 的 `SocksProxy.initProxy` 同样作用于纯 `dart:io`
///   `HttpClient`（见 `main.dart` 的注释），所以应用里配的代理依然生效；
/// - 先写 `<savePath>.part`，**大小校验通过**才改名为正式文件 ——
///   中断/取消留下的 `.part` 就是下次续传的起点。
///
/// ## 适用范围（不要误用）
///
/// 只用于**我们自己发起的直链下载**（Python embeddable、后端 7z、模型 zip）。
/// pip 安装的 wheel 由 pip 自己下载，无法续传 —— 那条路靠镜像配置与 pip 自带重试。
class MangaJaNaiDownloader {
  MangaJaNaiDownloader._();

  /// 连接超时。
  static const Duration _connectTimeout = Duration(seconds: 30);

  /// 空闲超时：大文件下载期间不能按整体时长计时，只能按「两次数据之间的间隔」。
  static const Duration _idleTimeout = Duration(seconds: 60);

  /// 把 GitHub Release 直链展开成「镜像… → 直连」的候选列表；其它 URL 原样返回。
  static List<String> candidateUrls(
    String url, {
    required bool useGithubMirror,
  }) {
    final githubRelease = RegExp(
      r'^https://github\.com/[\w.-]+/[\w.-]+/releases/download/[\w.-]+/.*$',
      caseSensitive: false,
    );
    if (!useGithubMirror || !githubRelease.hasMatch(url)) return [url];
    return [...mirrorBaseUrls.map((base) => '$base$url'), url];
  }

  /// 下载 [url] 到 [savePath]。
  ///
  /// [savePath] 已存在时直接复用（调用方负责在需要重下时先删除）。
  /// 每个候选通道都**接着同一个 `.part` 续传**，因此切换镜像不会丢掉已下载的进度。
  static Future<File> download(
    String url,
    String savePath, {
    required bool useGithubMirror,
    void Function(int received, int total)? onProgress,
    MangaJaNaiCancelToken? cancelToken,
  }) async {
    final target = File(savePath);
    if (target.existsSync()) return target;

    final candidates = candidateUrls(url, useGithubMirror: useGithubMirror);
    Object? lastError;

    for (final candidate in candidates) {
      cancelToken?.throwIfCancelled();
      try {
        if (candidate != url) {
          logger.d('MangaJaNai 下载通道（镜像）：$candidate');
        }
        return await _downloadOnce(
          candidate,
          savePath,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      } on MangaJaNaiInstallCancelled {
        rethrow;
      } on MangaJaNaiInstallException catch (e) {
        // 磁盘 / 权限问题换通道也没用，直接上报，避免白重试几次。
        if (e.kind == MangaJaNaiFailureKind.disk ||
            e.kind == MangaJaNaiFailureKind.permission) {
          rethrow;
        }
        lastError = e;
        logger.w('MangaJaNai 下载通道失败（$candidate）：$e');
      } on Object catch (e) {
        lastError = e;
        logger.w('MangaJaNai 下载通道失败（$candidate）：$e');
      }
    }

    throw MangaJaNaiInstallException(
      kind: MangaJaNaiFailureKind.network,
      message: '所有下载通道均失败',
      detail: '$lastError',
    );
  }

  static Future<File> _downloadOnce(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
    MangaJaNaiCancelToken? cancelToken,
  }) async {
    final partFile = File('$savePath.part');
    await partFile.parent.create(recursive: true);

    var existing = partFile.existsSync() ? await partFile.length() : 0;
    final client = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..idleTimeout = _idleTimeout;

    final removeCancelListener = cancelToken?.addListener(() {
      // 强制关闭连接：进行中的 `await for` 会抛异常，`.part` 保留供续传。
      try {
        client.close(force: true);
      } on Object catch (_) {
        // 已关闭
      }
    });

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      if (existing > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      }
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw MangaJaNaiInstallException(
          kind: MangaJaNaiFailureKind.network,
          message: '下载失败：HTTP ${response.statusCode}',
          detail: url,
        );
      }

      // 关键判断：只有 206 才允许追加。收到 200 说明服务器忽略了 Range
      // （或 `.part` 已过期），此时必须从头写，否则会把文件拼坏。
      final append =
          response.statusCode == HttpStatus.partialContent && existing > 0;
      if (!append) {
        existing = 0;
        if (partFile.existsSync()) await partFile.delete();
      }

      final remaining = response.contentLength;
      final total = remaining > 0 ? existing + remaining : -1;
      var received = existing;
      onProgress?.call(received, total);

      final sink = partFile.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response) {
          cancelToken?.throwIfCancelled();
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (total > 0 && received != total) {
        throw MangaJaNaiInstallException(
          kind: MangaJaNaiFailureKind.network,
          message: '下载不完整（$received/$total 字节）',
          detail: url,
        );
      }

      if (partFile.existsSync()) {
        final file = File(savePath);
        if (file.existsSync()) await file.delete();
        await partFile.rename(savePath);
      }
      return File(savePath);
    } on MangaJaNaiInstallCancelled {
      rethrow;
    } on Object catch (e) {
      // 取消导致的连接中断会以 SocketException / HttpException 的形式冒出来，
      // 这里还原成「已取消」，否则用户会看到一条莫名其妙的网络错误。
      cancelToken?.throwIfCancelled();
      throw classifyInstallError(e);
    } finally {
      removeCancelListener?.call();
      client.close(force: true);
    }
  }

  /// 未完成下载已缓存的字节数（0 表示没有可续传的残留）。
  static Future<int> partialBytes(String savePath) async {
    final partFile = File('$savePath.part');
    return partFile.existsSync() ? partFile.length() : 0;
  }

  /// 删除未完成的 `.part` 残留（卸载 / 强制重下时调用）。
  static Future<void> discardPartial(String savePath) async {
    final partFile = File('$savePath.part');
    if (!partFile.existsSync()) return;
    try {
      await partFile.delete();
    } on Object catch (e) {
      logger.w('删除未完成下载残留失败：${partFile.path}', error: e);
    }
  }

  /// 大文件的可读大小，例如 `2.5 GB`。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 下载缓存目录（`<cache>/mangajanai-download`）。
  static Future<String> cacheDir(String cacheRoot) async =>
      p.join(cacheRoot, 'mangajanai-download');
}

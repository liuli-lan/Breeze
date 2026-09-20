import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_downloader.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_engine.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_preflight.dart';
import 'package:zephyr/page/setting/real_sr/service/mjn_local_service.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_super_resolution.dart';
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/util/get_path.dart';

/// 引导安装阶段。
enum MangaJaNaiInstallStage {
  /// 安装前预检（磁盘空间 / NVIDIA 显卡）。
  preflight,

  /// Python embeddable + pip。
  python,

  /// 其余 PyPI 依赖（chainner_ext / pyvips / sanic 等）。
  deps,

  /// torch / torchvision（pytorch 官方 cu128 索引）。
  torch,

  /// chaiNNer 后端源码包。
  backend,

  /// 官方模型包。
  models,

  /// 常驻服务代码释放（asset → `<files>/mangajanai/service/`）。
  service,
}

/// 安装进度回调；[received]/[total] 仅在可统计的阶段（文件下载）有值，
/// [detail] 为阶段内的细节文本（pip 输出行等）。
typedef MangaJaNaiInstallProgress =
    void Function(
      MangaJaNaiInstallStage stage, {
      int? received,
      int? total,
      String? detail,
    });

/// MangaJaNai 引擎在线引导安装器（仅 Windows）。
///
/// 目标：目标机**无需安装 MangaJaNaiConverterGui**，全部内容从官方源获取：
/// - Python embeddable（python.org）+ get-pip（bootstrap.pypa.io）
/// - PyPI 依赖与 torch（pypi.org / download.pytorch.org）
/// - chaiNNer 后端源码包（Breeze 发布渠道，GPL 源码单独打包）
/// - 模型（the-database/MangaJaNai 官方 Release 的整包 zip，**不由 Breeze
///   再分发**，规避 CC BY-NC 4.0 的再分发问题——用户直接从官方源获取）
///
/// 安装布局与 GUI 保持同构（`python/python`、`backend/src`、`models`），
/// 落在 `<files>/mangajanai/`，由 `MangaJaNaiEngine` 的路径兜底自动识别，
/// 因此安装完成后无需任何额外配置。
///
/// 各阶段幂等：已就绪的阶段自动跳过，失败后重跑只会补齐缺失部分
/// （pip 本身对已满足的依赖也会跳过）。
class MangaJaNaiBootstrap {
  MangaJaNaiBootstrap._();

  static const _pythonVersion = '3.12.10';
  static const _pythonVersionKey = '312';
  static const _pythonEmbeddableUrl =
      'https://www.python.org/ftp/python/$_pythonVersion/'
      'python-$_pythonVersion-embed-amd64.zip';
  static const _getPipUrl = 'https://bootstrap.pypa.io/get-pip.py';

  /// embed 包缓存名带版本：换了 Python 版本后旧缓存必须失效。
  static const _pythonEmbeddableCacheName =
      'mangajanai-python-embed-$_pythonVersionKey.zip';

  /// 版本与后端 `pyproject.toml` 锁定一致。torch 系必须从 pytorch 官方 cu128
  /// 索引安装（PyPI 上的 Windows torch wheel 不含 CUDA）；pyproject 里写的
  /// cu121 已失效——该索引中已无任何 torch 发行版（实测），GUI 实装的是 cu128。
  ///
  /// Python 固定用 3.12：`chainner_ext==0.3.10` 的 Windows wheel 只发布到
  /// cp312；用 3.13 会落入 sdist，并因缺 `maturin` 构建失败。
  static const _torchVersion = '2.9.1';
  static const _torchvisionVersion = '0.24.1';

  /// 其余依赖：后端 `pyproject.toml` 锁定的版本，均为 PyPI 正式包
  /// （torch / torchvision 之外的全部）。
  ///
  /// `pyvips` 不在这里：它在 PyPI 只有 sdist（无 Windows wheel），需要
  /// `--no-build-isolation` 单独安装，见 [_pyvipsRequirement]。
  ///
  /// `spandrel*` 也不在这里：它们声明 `torch` / `torchvision`，若与其它依赖
  /// 同批安装，pip 会先拉一个 PyPI 上的 CPU 版 torch（实测 124MB），随后又被
  /// 第 3 阶段的 cu128 版覆盖。拆到 torch 之后安装，pip 看到依赖已满足就不会
  /// 再动它。见 [_torchDependentRequirements]。
  static const List<String> _pypiRequirements = [
    'chainner_ext==0.3.10',
    'numpy==2.2.5',
    'opencv-python==4.11.0.86',
    'packaging==25.0',
    'psutil==6.0.0',
    'pynvml==11.5.3',
    'pyvips-binary==8.16.1',
    'rarfile==4.2',
    'sanic==24.6.0',
  ];

  /// 依赖 torch / torchvision 的包，必须在 cu128 torch 装好之后再装。
  static const List<String> _torchDependentRequirements = [
    'spandrel==0.4.1',
    'spandrel_extra_arches==0.2.0',
  ];

  /// 纯 Python、只发布 sdist 的依赖，必须用 `--no-build-isolation` 装。
  ///
  /// 嵌入式 Python 的 `._pth` 会替换默认 sys.path，pip 的隔离构建环境拿不到
  /// `setuptools.build_meta`，于是 `pyvips` 现场构建必失败。解法是先装好
  /// [_buildTools] 再关掉隔离，本机实测可成功产出 wheel。
  static const String _pyvipsRequirement = 'pyvips==3.0.0';

  /// 供 sdist 现场构建用的构建工具。
  static const List<String> _buildTools = ['setuptools', 'wheel'];

  /// 后端源码归档（约 1 MB）：直接使用上游官方仓库 main 分支 ZIP。
  ///
  /// 历史上的 Breeze Release 后端包只是占位链接（从未上传）；上游源码包
  /// 已含完整 `backend/`，能省掉一次私自打包发布。ZIP 顶层含仓库目录名，
  /// 解压后必须归一化。
  static const _backendArchiveUrl =
      'https://github.com/the-database/MangaJaNaiConverterGui/archive/'
      'refs/heads/main.zip';

  /// 模型包：官方 Release 整包 zip。共约 600MB（zip 内含 Breeze 用不到的
  /// 变体，解压后只提取链需要的文件）。
  static const List<(String, String)> _modelPackages = [
    (
      'https://github.com/the-database/MangaJaNai/releases/download/1.0.0/'
          'MangaJaNai_V1_ModelsOnly.zip',
      'MangaJaNai_V1_ModelsOnly.zip',
    ),
    (
      'https://github.com/the-database/MangaJaNai/releases/download/3.0.0/'
          'IllustrationJaNai_V3denoise.zip',
      'IllustrationJaNai_V3denoise.zip',
    ),
  ];

  /// pip 安装兜底超时：torch wheel ~2.5GB，慢网络下可能需要很久。
  static const _pipTimeout = Duration(minutes: 90);

  /// 离线包内必须存在的顶层目录（与 GUI 安装同构）。
  ///
  /// 导入时按目录做**整体替换**，因此这里也决定了「换掉哪几块」。少一个目录
  /// 不算致命（例如只补模型），但一个都没有就是包选错了。
  static const List<String> archiveTopLevelDirs = [
    'python',
    'models',
    'backend',
  ];

  static Future<String> _installRoot() async =>
      p.join(await getFilePath(), 'mangajanai');

  static Future<String> _pythonDir() async =>
      p.join(await _installRoot(), 'python', 'python');

  /// 引擎安装目录（`<files>/mangajanai/`）。公开给设置页做预检与展示。
  static Future<String> installRoot() => _installRoot();

  /// 引擎是否已通过引导安装，且 Python 运行时版本正确。
  static Future<bool> get isBootstrapped => _pythonRuntimeMatches();

  /// 已装 Python 运行时是否是当前 [_pythonVersion]。
  ///
  /// 旧版本（3.13）的 embed 目录同样有 `python.exe`，但 `chainner_ext` 没有
  /// cp313 Windows wheel，继续复用只会稳定地落到 sdist 构建失败。这里用
  /// `._pth` 文件名与核心 DLL 判定，两者都是 embed 包自带的版本标志。
  static Future<bool> _pythonRuntimeMatches() async {
    final dir = Directory(await _pythonDir());
    if (!dir.existsSync()) return false;
    final hasPth = File(
      p.join(dir.path, 'python$_pythonVersionKey._pth'),
    ).existsSync();
    if (!hasPth) return false;
    final listed = await dir.list().map((e) => p.basename(e.path)).toList();
    return listed.any(
      (name) =>
          name.startsWith('python$_pythonVersionKey.') &&
          name.toLowerCase().endsWith('.dll'),
    );
  }

  /// 当前正在运行的安装子进程（pip / zipfile），供 [MangaJaNaiCancelToken] 终止。
  static Process? _activeProcess;

  /// 执行完整安装；已就绪的阶段自动跳过。
  ///
  /// P3 强化点（方案 §5）：
  /// - **预检**：先查磁盘空间（不足直接拦下）与 NVIDIA 显卡（无卡只警告）；
  /// - **镜像源**：[source] / [mirrors] 决定 pip 索引与 GitHub 通道，失败自动切换；
  /// - **断点续传**：直链下载走 `MangaJaNaiDownloader`（`.part` + Range）；
  /// - **可取消**：[cancelToken] 在阶段之间与下载中都能中断；
  /// - **失败分类**：所有异常统一转成 [MangaJaNaiInstallException]；
  /// - **阶段 6**：把随应用分发的常驻服务代码释放到 `service/`。
  static Future<void> install({
    MangaJaNaiInstallProgress? onProgress,
    MangaJaNaiCancelToken? cancelToken,
    MangaJaNaiDownloadSource source = MangaJaNaiDownloadSource.auto,
    MangaJaNaiMirrorConfig mirrors = MangaJaNaiMirrorConfig.defaults,
    bool forceRedownload = false,
  }) async {
    try {
      await _install(
        onProgress: onProgress,
        cancelToken: cancelToken,
        source: source,
        mirrors: mirrors,
        forceRedownload: forceRedownload,
      );
    } on Object catch (e) {
      throw classifyInstallError(e);
    } finally {
      _activeProcess = null;
    }
  }

  static Future<void> _install({
    required MangaJaNaiInstallProgress? onProgress,
    required MangaJaNaiCancelToken? cancelToken,
    required MangaJaNaiDownloadSource source,
    required MangaJaNaiMirrorConfig mirrors,
    required bool forceRedownload,
  }) async {
    final root = await _installRoot();
    final pythonDir = await _pythonDir();
    final pythonExe = p.join(pythonDir, 'python.exe');
    final cache = await getCachePath();
    final useGithubMirror = mirrors.githubMirrorEnabledFor(source);

    void checkCancel() => cancelToken?.throwIfCancelled();

    // ---- 阶段 0 前置：旧 Python 运行时替换 ----
    //
    // 历史版本用过 3.13，装了 3.13 引擎的机器重跑「在线安装」时
    // `python.exe` 已存在，旧逻辑会直接跳到 pip，于是在错误的解释器上
    // 反复失败。这里先判定版本；不匹配就只删运行时目录，保留 models /
    // backend 等已下载成果。pip 阶段随后会在新解释器上重装依赖。
    if (File(pythonExe).existsSync() && !await _pythonRuntimeMatches()) {
      onProgress?.call(
        MangaJaNaiInstallStage.python,
        detail: '检测到旧版 Python 运行时，正在替换为 $_pythonVersion…',
      );
      final oldPythonRoot = Directory(p.join(root, 'python'));
      if (oldPythonRoot.existsSync()) {
        await oldPythonRoot.delete(recursive: true);
      }
      _quietDelete(p.join(cache, 'mangajanai-python-embed.zip'));
    }

    // ---- 阶段 0：预检 ----
    //
    // 10 GB 硬门槛只在「真的要装 Python（= 全量安装）」时拉起：已装好引擎的
    // 重新安装多半只是补模型（zip ~600 MB）或跑一次 no-op 的 pip，拿全量门槛
    // 拦人等于把「修复」堵在门外。Python 已存在时的磁盘不足会在具体写入/pip
    // 阶段以 disk 类失败暴露，同样能被 UI 分类展示。
    if (!File(pythonExe).existsSync()) {
      onProgress?.call(MangaJaNaiInstallStage.preflight);
      final report = await MangaJaNaiPreflight.check(targetPath: root);
      if (!report.diskOk) {
        throw MangaJaNaiInstallException(
          kind: MangaJaNaiFailureKind.disk,
          message:
              '磁盘空间不足：${report.driveLabel} 需至少 '
              '${MangaJaNaiDownloader.formatBytes(MangaJaNaiPreflightReport.requiredBytes)}'
              ' 空闲，当前仅 '
              '${MangaJaNaiDownloader.formatBytes(report.freeBytes ?? 0)}',
        );
      }
      onProgress?.call(
        MangaJaNaiInstallStage.preflight,
        detail: report.hasNvidiaGpu
            ? '检测到 ${report.gpu}'
            : '未检测到 NVIDIA 显卡（CPU 模式会慢 20~27 倍）',
      );
      checkCancel();
    }

    // ---- 阶段 1：Python embeddable + pip ----
    if (!File(pythonExe).existsSync()) {
      onProgress?.call(MangaJaNaiInstallStage.python);
      final zipPath = p.join(cache, _pythonEmbeddableCacheName);
      if (forceRedownload) await MangaJaNaiDownloader.discardPartial(zipPath);
      await MangaJaNaiDownloader.download(
        _pythonEmbeddableUrl,
        zipPath,
        useGithubMirror: useGithubMirror,
        cancelToken: cancelToken,
        onProgress: (r, t) {
          onProgress?.call(
            MangaJaNaiInstallStage.python,
            received: r,
            total: t,
          );
        },
      );
      await Directory(pythonDir).create(recursive: true);
      await _extractZipSmall(zipPath, pythonDir);

      // embeddable 默认禁用 site-packages：重写 ._pth 放开，否则 pip 装的
      // 包全部 import 不到。文件名为 python<major><minor>._pth（如 3.13 →
      // python312._pth）；内容与 GUI 实际写入的版本一致（不存在的路径会被
      // 忽略，pip 装完后 Lib/site-packages 自然生效）。
      final versionKey = _pythonVersion.split('.').take(2).join();
      await File(
        p.join(pythonDir, 'python$versionKey._pth'),
      ).writeAsString('python312.zip\nDLLs\nLib\n.\nLib/site-packages\n');

      final getPipPath = p.join(pythonDir, 'get-pip.py');
      await MangaJaNaiDownloader.download(
        _getPipUrl,
        getPipPath,
        useGithubMirror: false,
        cancelToken: cancelToken,
      );
      await _runProcess(
        pythonExe,
        [getPipPath, '--no-warn-script-location'],
        workingDirectory: pythonDir,
        stage: MangaJaNaiInstallStage.python,
        onProgress: onProgress,
        timeout: const Duration(minutes: 10),
        cancelToken: cancelToken,
      );
    }
    checkCancel();

    // ---- 阶段 2：PyPI 依赖（小包先装，快速失败）----
    onProgress?.call(MangaJaNaiInstallStage.deps);
    await _runPipWithFallback(
      pythonExe: pythonExe,
      packages: _pypiRequirements,
      indexCandidates: mirrors.pypiIndexCandidates(source),
      workingDirectory: pythonDir,
      onProgress: onProgress,
      stage: MangaJaNaiInstallStage.deps,
      cancelToken: cancelToken,
    );
    checkCancel();

    // pyvips 只有 sdist：先备好构建工具，再关掉构建隔离单独装。
    // 少了这两步，嵌入式 Python 上会以
    // `BackendUnavailable: Cannot import 'setuptools.build_meta'` 收场。
    await _runPipWithFallback(
      pythonExe: pythonExe,
      packages: _buildTools,
      indexCandidates: mirrors.pypiIndexCandidates(source),
      workingDirectory: pythonDir,
      onProgress: onProgress,
      stage: MangaJaNaiInstallStage.deps,
      cancelToken: cancelToken,
    );
    checkCancel();
    await _runPipWithFallback(
      pythonExe: pythonExe,
      packages: const [_pyvipsRequirement],
      indexCandidates: mirrors.pypiIndexCandidates(source),
      workingDirectory: pythonDir,
      onProgress: onProgress,
      stage: MangaJaNaiInstallStage.deps,
      cancelToken: cancelToken,
      extraArgs: const ['--no-build-isolation'],
    );
    checkCancel();

    // ---- 阶段 3：torch / torchvision（大头，~2.5GB）----
    //
    // 注意：pip 自己下载 wheel，**无法断点续传**（方案 §5 第 4 条只对我们的
    // 直链下载生效）。这里能做的就是把镜像做成候选索引，失败自动换源。
    onProgress?.call(MangaJaNaiInstallStage.torch);
    await _runPipWithFallback(
      pythonExe: pythonExe,
      packages: ['torch==$_torchVersion', 'torchvision==$_torchvisionVersion'],
      indexCandidates: mirrors.torchIndexCandidates(source),
      workingDirectory: pythonDir,
      onProgress: onProgress,
      stage: MangaJaNaiInstallStage.torch,
      cancelToken: cancelToken,
    );
    checkCancel();

    // spandrel* 声明依赖 torch / torchvision。放到 cu128 之后装，pip 看到
    // 依赖已满足就不会再解析出 PyPI 的 CPU 版 torch。
    await _runPipWithFallback(
      pythonExe: pythonExe,
      packages: _torchDependentRequirements,
      indexCandidates: mirrors.pypiIndexCandidates(source),
      workingDirectory: pythonDir,
      onProgress: onProgress,
      stage: MangaJaNaiInstallStage.torch,
      cancelToken: cancelToken,
    );
    checkCancel();

    // ---- 阶段 4：后端源码包 ----
    final backendScript = p.join(root, 'backend', 'src', 'run_upscale.py');
    if (!File(backendScript).existsSync()) {
      onProgress?.call(MangaJaNaiInstallStage.backend);
      final archivePath = p.join(cache, 'mangajanai-backend-main.zip');
      if (forceRedownload) {
        await MangaJaNaiDownloader.discardPartial(archivePath);
      }
      await MangaJaNaiDownloader.download(
        _backendArchiveUrl,
        archivePath,
        useGithubMirror: useGithubMirror,
        cancelToken: cancelToken,
      );
      // 上游 ZIP 顶层是仓库目录，先解到临时目录，再归一化到 backend/。
      final extractDir = Directory(
        p.join(cache, 'mangajanai-backend-${const Uuid().v4()}'),
      );
      try {
        await extractDir.create(recursive: true);
        await _extractZipSmall(archivePath, extractDir.path);

        // 不要假设仓库 ZIP 的目录层数：上游实际是
        // `<repo>-main/<repo>/backend/...`（两层），早期只剥一层会直接失败。
        // 这里按内容递归定位 `backend/src/run_upscale.py`，层级变了也不受影响。
        final backendSource = _findBackendDir(extractDir.path);
        if (backendSource == null) {
          throw StateError('上游后端源码包缺少 backend/src/run_upscale.py');
        }

        final backendDest = Directory(p.join(root, 'backend'));
        if (backendDest.existsSync()) {
          await backendDest.delete(recursive: true);
        }
        await _moveDirectory(backendSource, backendDest);
      } finally {
        _quietDeleteDir(extractDir.path);
        _quietDelete(archivePath);
      }
    }
    checkCancel();

    // ---- 阶段 5：模型 ----
    final modelsDir = p.join(root, 'models');
    final required = MangaJaNaiEngine.requiredModelFiles();
    final missingModels = required
        .where((name) => !File(p.join(modelsDir, name)).existsSync())
        .toList();
    if (missingModels.isNotEmpty) {
      onProgress?.call(MangaJaNaiInstallStage.models);
      await Directory(modelsDir).create(recursive: true);

      for (final (url, name) in _modelPackages) {
        final zipPath = p.join(cache, name);
        if (forceRedownload) {
          await MangaJaNaiDownloader.discardPartial(zipPath);
        }
        await MangaJaNaiDownloader.download(
          url,
          zipPath,
          useGithubMirror: useGithubMirror,
          cancelToken: cancelToken,
          onProgress: (r, t) {
            onProgress?.call(
              MangaJaNaiInstallStage.models,
              received: r,
              total: t,
            );
          },
        );

        // 用刚装好的 Python 解 zip：流式解压不占 Dart 内存，
        // 也避免为 zip 引入直接的 archive 依赖。
        final extractDir = Directory(
          p.join(cache, 'mangajanai-models-${const Uuid().v4()}'),
        );
        await extractDir.create(recursive: true);
        final result = await _runProcess(
          pythonExe,
          ['-m', 'zipfile', '-e', zipPath, extractDir.path],
          workingDirectory: pythonDir,
          stage: MangaJaNaiInstallStage.models,
          onProgress: onProgress,
          timeout: const Duration(minutes: 30),
          cancelToken: cancelToken,
        );
        if (result.exitCode != 0) {
          throw StateError(
            '模型包解压失败: $name\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}',
          );
        }

        // zip 内部结构不保证平铺，递归按文件名提取链需要的模型。
        await for (final entity in extractDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final baseName = p.basename(entity.path);
          if (required.contains(baseName)) {
            await entity.copy(p.join(modelsDir, baseName));
          }
        }
        _quietDeleteDir(extractDir.path);
        _quietDelete(zipPath);
      }

      final stillMissing = required
          .where((name) => !File(p.join(modelsDir, name)).existsSync())
          .toList();
      if (stillMissing.isNotEmpty) {
        throw StateError('官方模型包中未找到以下文件: $stillMissing');
      }
    }

    // ---- 阶段 6：常驻服务代码释放 ----
    //
    // 与引擎本体解耦：服务代码是 asset（约 55 KB），安装完成后顺手落到
    // `<files>/mangajanai/service/`，这样「装完就能起服务」不需要再等一次启动。
    onProgress?.call(MangaJaNaiInstallStage.service);
    try {
      await MjnLocalService.instance.releaseServiceCode();
    } on Object catch (e, s) {
      // 服务代码释放失败不该让整个安装判失败（CLI 路径仍然可用），
      // 但必须记日志 —— 否则用户会只看到「服务起不来」而无从溯源。
      logger.w('常驻服务代码释放失败（引擎本身可用）', error: e, stackTrace: s);
    }

    logger.d('MangaJaNai bootstrap install finished: $root');
  }

  /// 删除通过引导安装的引擎目录（不影响本机 GUI 安装）。
  ///
  /// 顺带清掉下载缓存里的 `.part` 残留，避免「卸载后重装」从旧的不完整文件续传。
  static Future<void> uninstall({bool keepDownloadCache = true}) async {
    final root = await _installRoot();
    final dir = Directory(root);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    if (keepDownloadCache) return;

    final cache = await getCachePath();
    for (final name in [
      _pythonEmbeddableCacheName,
      // 3.13 时代的缓存名，卸载时一并清掉。
      'mangajanai-python-embed.zip',
      'mangajanai-backend-main.zip',
      for (final (_, fileName) in _modelPackages) fileName,
    ]) {
      await MangaJaNaiDownloader.discardPartial(p.join(cache, name));
    }
  }

  // ------------------------------------------------------------------
  // 通道 ③：导入离线运行环境包（方案 §12）
  // ------------------------------------------------------------------

  /// 导入用户自己获取的 `mangajanai-win.7z`。
  ///
  /// 流程与 NCNN 的 `importModelArchive()` 同构，这是方案 §12.3 特意复用的
  /// 「解到临时目录 → 内容校验 → 全部通过才替换」安全骨架：
  ///
  /// 1. 校验 7z 魔数（复用 NCNN 路径的实现，纯格式判断）；
  /// 2. 解压到缓存里的临时目录（不用引擎自己的目录，避免解到一半污染现有安装）；
  /// 3. 校验内容：`python/python/python.exe`、`backend/src/run_upscale.py`、
  ///    `backend/ImageMagick/`、以及链需要的 16 个模型文件；
  /// 4. 按顶层目录**整体替换**（python / models / backend）。
  ///
  /// [onProgress] 的 `detail` 会带上当前步骤，便于 UI 显示单行进度。
  static Future<void> importArchive(
    String archivePath, {
    MangaJaNaiInstallProgress? onProgress,
    MangaJaNaiCancelToken? cancelToken,
  }) async {
    try {
      await _importArchive(
        archivePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } on Object catch (e) {
      throw classifyInstallError(e);
    }
  }

  static Future<void> _importArchive(
    String archivePath, {
    required MangaJaNaiInstallProgress? onProgress,
    required MangaJaNaiCancelToken? cancelToken,
  }) async {
    void checkCancel() => cancelToken?.throwIfCancelled();

    final archiveFile = File(archivePath);
    if (!archiveFile.existsSync()) {
      throw MangaJaNaiInstallException(
        kind: MangaJaNaiFailureKind.unknown,
        message: '所选压缩包不存在',
        detail: archivePath,
      );
    }
    final isSevenZ = await RealSrSuperResolution.isSevenZArchive(archiveFile);
    final isZip = await _isZipArchive(archiveFile);
    if (!isSevenZ && !isZip) {
      throw const MangaJaNaiInstallException(
        kind: MangaJaNaiFailureKind.unknown,
        message: '不是有效的压缩包（支持 7z 离线包或上游 Portable ZIP）',
      );
    }

    final cache = await getCachePath();
    final tempDir = Directory(
      p.join(cache, 'mangajanai-import-${const Uuid().v4()}'),
    );
    final extracted = Directory(p.join(tempDir.path, 'extracted'));

    try {
      onProgress?.call(
        MangaJaNaiInstallStage.backend,
        detail: '正在解压离线包（约 3 GB，需要几分钟）…',
      );
      await extracted.create(recursive: true);
      if (isSevenZ) {
        await decompress7Z(archivePath: archivePath, destPath: extracted.path);
      } else {
        await _extractZipSmall(archivePath, extracted.path);
      }
      checkCancel();

      final missing = await MangaJaNaiArchiveValidator.validate(extracted.path);
      if (missing.isNotEmpty) {
        throw MangaJaNaiInstallException(
          kind: MangaJaNaiFailureKind.unknown,
          message: '压缩包内容不完整，已放弃导入（现有安装未被修改）',
          detail: missing.take(8).join('\n'),
        );
      }

      onProgress?.call(MangaJaNaiInstallStage.models, detail: '校验通过，正在替换现有安装…');
      final root = await _installRoot();
      // ⚠️ 校验与复制必须用同一个根：包可能多套一层目录（校验器会归一化），
      // 复制还用原始解压目录的话会出现「校验通过但什么都没复制」的静默空导入。
      final sourceRoot = MangaJaNaiArchiveValidator.normalizeRoot(
        extracted.path,
      );
      await Directory(root).create(recursive: true);

      // 替换前先把现有目录整体改名挪走（同卷 rename 几乎零成本）：全部移入成功
      // 才删备份；中途失败把还没替换的目录原样改回 —— 现有安装不会被破坏。
      final backups = <String, Directory>{};
      try {
        for (final name in archiveTopLevelDirs) {
          final dest = Directory(p.join(root, name));
          if (dest.existsSync()) {
            final backup = Directory(
              '${dest.path}.bak-${DateTime.now().millisecondsSinceEpoch}',
            );
            await dest.rename(backup.path);
            backups[name] = backup;
          }
        }
        for (final name in archiveTopLevelDirs) {
          checkCancel();
          final source = Directory(p.join(sourceRoot, name));
          if (!source.existsSync()) continue;
          await _moveDirectory(source, Directory(p.join(root, name)));
        }
      } on Object {
        for (final entry in backups.entries) {
          final dest = Directory(p.join(root, entry.key));
          if (dest.existsSync()) {
            // 这个目录已经换成了新内容，回退不了 —— 备份留在原地不删，至少不丢数据。
            logger.w(
              '导入中断：${entry.key} 已替换为新内容，'
              '旧内容备份保留在 ${entry.value.path}',
            );
            continue;
          }
          try {
            await entry.value.rename(dest.path);
          } on Object catch (e) {
            logger.w('导入回滚失败，备份保留在 ${entry.value.path}', error: e);
          }
        }
        rethrow;
      }
      // 全部成功：现在才允许删掉旧内容。
      for (final backup in backups.values) {
        _quietDeleteDir(backup.path);
      }
    } finally {
      try {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } on Object catch (e) {
        logger.w('导入临时目录清理失败：${tempDir.path}', error: e);
      }
    }

    onProgress?.call(MangaJaNaiInstallStage.service);
    try {
      await MjnLocalService.instance.releaseServiceCode();
    } on Object catch (e, s) {
      logger.w('常驻服务代码释放失败（引擎本身可用）', error: e, stackTrace: s);
    }
  }

  /// 识别 ZIP 魔数；上游 Portable 分发是 ZIP，而自打离线包是 7z。
  static Future<bool> _isZipArchive(File file) async {
    final raf = await file.open();
    try {
      final bytes = await raf.read(4);
      return bytes.length >= 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
          (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08);
    } finally {
      await raf.close();
    }
  }

  /// 在解压结果里递归找出 `backend/`（其下含 `src/run_upscale.py`）。
  ///
  /// 上游仓库 ZIP 的包装层数不固定，按内容定位比按固定层级更稳。
  /// 找不到返回 null，由调用方给出可读错误。
  static Directory? _findBackendDir(String rootPath) {
    final root = Directory(rootPath);
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (p.basename(entity.path) != 'run_upscale.py') continue;
      // 期望 .../backend/src/run_upscale.py
      final srcDir = p.dirname(entity.path);
      if (p.basename(srcDir) != 'src') continue;
      final backendDir = Directory(p.dirname(srcDir));
      if (p.basename(backendDir.path) != 'backend') continue;
      return backendDir;
    }
    return null;
  }

  /// 把目录移动到目标位置；跨磁盘/分区失败时退回复制后删除。
  static Future<void> _moveDirectory(Directory from, Directory to) async {
    try {
      await from.rename(to.path);
    } on FileSystemException {
      await to.create(recursive: true);
      await for (final entity in from.list(
        recursive: true,
        followLinks: false,
      )) {
        final relative = p.relative(entity.path, from: from.path);
        final target = p.join(to.path, relative);
        if (entity is Directory) {
          await Directory(target).create(recursive: true);
        } else if (entity is File) {
          await File(entity.path).copy(target);
        }
      }
      await from.delete(recursive: true);
    }
  }

  /// 小 zip（Python embeddable ~11MB）直接内存解压。
  static Future<void> _extractZipSmall(String zipPath, String destDir) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      final outPath = p.join(destDir, entry.name);
      if (entry.isFile) {
        final file = File(outPath);
        await file.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
  }

  /// 装 pip 依赖，按 [indexCandidates] 依次尝试索引。
  ///
  /// 「自动 / 镜像」档会拿到「镜像 → 官方」两个候选，镜像挂了或版本不全时自动
  /// 换官方源重试 —— 方案 §5.1 要求的「不要让用户自己去试」，就落在这里。
  /// `--index-url` 是**覆盖**而非追加，所以换源重试是干净的，不会有半路换源的
  /// 解析不确定性。
  static Future<void> _runPipWithFallback({
    required String pythonExe,
    required List<String> packages,
    required List<String> indexCandidates,
    required String workingDirectory,
    required MangaJaNaiInstallProgress? onProgress,
    required MangaJaNaiInstallStage stage,
    required MangaJaNaiCancelToken? cancelToken,
    List<String> extraArgs = const [],
  }) async {
    final candidates = indexCandidates.isEmpty
        ? <String?>[null]
        : indexCandidates;
    Object? lastError;

    for (final index in candidates) {
      cancelToken?.throwIfCancelled();
      final args = [
        '-m',
        'pip',
        'install',
        '--no-warn-script-location',
        '--progress-bar',
        'off',
        ...extraArgs,
        if (index != null) ...['--index-url', index],
        ...packages,
      ];
      try {
        if (index != null) {
          onProgress?.call(stage, detail: 'pip 索引：$index');
        }
        await _runProcess(
          pythonExe,
          args,
          workingDirectory: workingDirectory,
          stage: stage,
          onProgress: onProgress,
          timeout: _pipTimeout,
          cancelToken: cancelToken,
        );
        return;
      } on Object catch (e) {
        lastError = e;
        logger.w('pip 安装失败（索引 ${index ?? '默认'}）：$e');
        if (e is MangaJaNaiInstallCancelled) rethrow;
      }
    }

    throw classifyInstallError(lastError ?? StateError('pip 安装失败（无可用索引）'));
  }

  /// 启动并等待一个子进程。
  ///
  /// 返回 `ProcessResult`，因为调用方（模型包解压）需要 stdout；
  /// [cancelToken] 会在用户点击「取消」时立即杀掉进程 —— 否则 90 分钟的 pip
  /// 超时会让取消形同虚设。
  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required MangaJaNaiInstallStage stage,
    required MangaJaNaiInstallProgress? onProgress,
    required Duration timeout,
    MangaJaNaiCancelToken? cancelToken,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    _activeProcess = process;

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    // 逐行转发输出作为细节进度；pip 的进度条已用 --progress-bar off 关闭，
    // 每个 "Collecting/Successfully installed" 行都是有用的阶段信息。
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stdoutBuffer.writeln(line);
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            onProgress?.call(stage, detail: trimmed);
          }
        })
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderrBuffer.writeln(line);
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            onProgress?.call(stage, detail: trimmed);
          }
        })
        .asFuture<void>();

    final removeCancelListener = cancelToken?.addListener(() {
      // 取消要立刻生效：先杀进程，再让等待中的 exitCode 抛出取消异常。
      try {
        process.kill(ProcessSignal.sigkill);
      } on Object catch (_) {
        // 进程可能已退出
      }
    });

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
      throw StateError('进程超时未结束: ${arguments.first}');
    } finally {
      removeCancelListener?.call();
      if (identical(_activeProcess, process)) _activeProcess = null;
    }
    await Future.wait([stdoutDone, stderrDone]);

    // 取消导致的非零退出码，语义上是「已取消」而不是「命令失败」。
    cancelToken?.throwIfCancelled();

    if (exitCode != 0) {
      throw StateError(
        '命令失败 (exitCode=$exitCode): $executable ${arguments.join(' ')}\n'
        '${_tail('$stdoutBuffer\n$stderrBuffer')}',
      );
    }

    return ProcessResult(
      process.pid,
      exitCode,
      stdoutBuffer.toString(),
      stderrBuffer.toString(),
    );
  }

  /// 截取进程输出末尾用于错误信息，避免超长日志刷屏。
  /// （与 `MangaJaNaiEngine._tail` 同一语义，各自私有。）
  static String _tail(String text, [int maxLength = 2000]) {
    final trimmed = text.trim();
    if (trimmed.length <= maxLength) return trimmed;
    return '...${trimmed.substring(trimmed.length - maxLength)}';
  }

  static void _quietDelete(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      logger.w('临时文件清理失败: $path', error: e);
    }
  }

  static void _quietDeleteDir(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (e) {
      logger.w('临时目录清理失败: $path', error: e);
    }
  }
}

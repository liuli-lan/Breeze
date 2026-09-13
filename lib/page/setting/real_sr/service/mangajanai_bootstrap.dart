import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_engine.dart';
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/util/get_path.dart';

/// 引导安装阶段。
enum MangaJaNaiInstallStage {
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

  static const _pythonVersion = '3.13.9';
  static const _pythonEmbeddableUrl =
      'https://www.python.org/ftp/python/$_pythonVersion/'
      'python-$_pythonVersion-embed-amd64.zip';
  static const _getPipUrl = 'https://bootstrap.pypa.io/get-pip.py';

  /// 版本与后端 `pyproject.toml` 锁定一致。torch 系必须从 pytorch 官方 cu128
  /// 索引安装（PyPI 上的 Windows torch wheel 不含 CUDA）；pyproject 里写的
  /// cu121 已失效——该索引中已无任何 torch 发行版（实测），GUI 实装的是 cu128。
  static const _torchVersion = '2.9.1';
  static const _torchvisionVersion = '0.24.1';
  static const _torchIndexUrl = 'https://download.pytorch.org/whl/cu128';

  /// 其余依赖：后端 `pyproject.toml` 锁定的版本，均为 PyPI 正式包
  /// （torch / torchvision 之外的全部）。
  static const List<String> _pypiRequirements = [
    'chainner_ext==0.3.10',
    'numpy==2.2.5',
    'opencv-python==4.11.0.86',
    'packaging==25.0',
    'psutil==6.0.0',
    'pynvml==11.5.3',
    'pyvips==3.0.0',
    'pyvips-binary==8.16.1',
    'rarfile==4.2',
    'sanic==24.6.0',
    'spandrel_extra_arches==0.2.0',
    'spandrel==0.4.1',
  ];

  /// 后端源码包（~1.5MB）：`script/pack_mangajanai_windows.py --backend-only`
  /// 产出，上传到 Breeze 的发布渠道。后端为 GPL 源码，包内附许可说明。
  static const _backendArchiveUrl =
      'https://github.com/liuli-lan/Breeze/releases/download/'
      'mangajanai-engine-v1/mangajanai-backend.7z';

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

  static Future<String> _installRoot() async =>
      p.join(await getFilePath(), 'mangajanai');

  static Future<String> _pythonDir() async =>
      p.join(await _installRoot(), 'python', 'python');

  /// 引擎是否已通过引导安装（python.exe 存在即视为装过）。
  static Future<bool> get isBootstrapped async =>
      File(p.join(await _pythonDir(), 'python.exe')).existsSync();

  /// 执行完整安装；已就绪的阶段自动跳过。
  static Future<void> install({MangaJaNaiInstallProgress? onProgress}) async {
    final root = await _installRoot();
    final pythonDir = await _pythonDir();
    final pythonExe = p.join(pythonDir, 'python.exe');
    final cache = await getCachePath();

    // ---- 阶段 1：Python embeddable + pip ----
    if (!File(pythonExe).existsSync()) {
      onProgress?.call(MangaJaNaiInstallStage.python);
      final zipPath = p.join(cache, 'mangajanai-python-embed.zip');
      await _download(_pythonEmbeddableUrl, zipPath, (r, t) {
        onProgress?.call(MangaJaNaiInstallStage.python, received: r, total: t);
      });
      await Directory(pythonDir).create(recursive: true);
      await _extractZipSmall(zipPath, pythonDir);

      // embeddable 默认禁用 site-packages：重写 ._pth 放开，否则 pip 装的
      // 包全部 import 不到。文件名为 python<major><minor>._pth（如 3.13 →
      // python313._pth）；内容与 GUI 实际写入的版本一致（不存在的路径会被
      // 忽略，pip 装完后 Lib/site-packages 自然生效）。
      final versionKey = _pythonVersion.split('.').take(2).join();
      await File(
        p.join(pythonDir, 'python$versionKey._pth'),
      ).writeAsString('python313.zip\nDLLs\nLib\n.\nLib/site-packages\n');

      final getPipPath = p.join(pythonDir, 'get-pip.py');
      await _download(_getPipUrl, getPipPath, null);
      await _runProcess(
        pythonExe,
        [getPipPath, '--no-warn-script-location'],
        workingDirectory: pythonDir,
        stage: MangaJaNaiInstallStage.python,
        onProgress: onProgress,
        timeout: const Duration(minutes: 10),
      );
    }

    // ---- 阶段 2：PyPI 依赖（小包先装，快速失败）----
    onProgress?.call(MangaJaNaiInstallStage.deps);
    await _runPip(
      pythonExe,
      _pypiRequirements,
      pythonDir,
      onProgress,
      MangaJaNaiInstallStage.deps,
    );

    // ---- 阶段 3：torch / torchvision（大头，~2.5GB）----
    onProgress?.call(MangaJaNaiInstallStage.torch);
    await _runPip(
      pythonExe,
      [
        'torch==$_torchVersion',
        'torchvision==$_torchvisionVersion',
        '--index-url',
        _torchIndexUrl,
      ],
      pythonDir,
      onProgress,
      MangaJaNaiInstallStage.torch,
    );

    // ---- 阶段 4：后端源码包 ----
    final backendScript = p.join(root, 'backend', 'src', 'run_upscale.py');
    if (!File(backendScript).existsSync()) {
      onProgress?.call(MangaJaNaiInstallStage.backend);
      final archivePath = p.join(cache, 'mangajanai-backend.7z');
      await _download(_backendArchiveUrl, archivePath, null);
      // 包内顶层即 backend/，解到引擎根目录。
      await decompress7Z(archivePath: archivePath, destPath: root);
      _quietDelete(archivePath);
    }

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
        if (!File(zipPath).existsSync()) {
          await _download(url, zipPath, (r, t) {
            onProgress?.call(
              MangaJaNaiInstallStage.models,
              received: r,
              total: t,
            );
          });
        }

        // 用刚装好的 Python 解 zip：流式解压不占 Dart 内存，
        // 也避免为 zip 引入直接的 archive 依赖。
        final extractDir = Directory(
          p.join(cache, 'mangajanai-models-${const Uuid().v4()}'),
        );
        await extractDir.create(recursive: true);
        final result = await Process.run(pythonExe, [
          '-m',
          'zipfile',
          '-e',
          zipPath,
          extractDir.path,
        ]);
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

    logger.d('MangaJaNai bootstrap install finished: $root');
  }

  /// 删除通过引导安装的引擎目录（不影响本机 GUI 安装）。
  static Future<void> uninstall() async {
    final root = await _installRoot();
    final dir = Directory(root);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  // ------------------------------------------------------------------

  static Future<void> _download(
    String url,
    String savePath,
    void Function(int received, int total)? onProgress,
  ) async {
    await WindHttp().download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received, total);
      },
    );
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

  static Future<void> _runPip(
    String pythonExe,
    List<String> packages,
    String workingDirectory,
    MangaJaNaiInstallProgress? onProgress,
    MangaJaNaiInstallStage stage,
  ) async {
    await _runProcess(
      pythonExe,
      [
        '-m',
        'pip',
        'install',
        '--no-warn-script-location',
        '--progress-bar',
        'off',
        ...packages,
      ],
      workingDirectory: workingDirectory,
      stage: stage,
      onProgress: onProgress,
      timeout: _pipTimeout,
    );
  }

  static Future<void> _runProcess(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required MangaJaNaiInstallStage stage,
    required MangaJaNaiInstallProgress? onProgress,
    required Duration timeout,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );

    // 逐行转发输出作为细节进度；pip 的进度条已用 --progress-bar off 关闭，
    // 每个 "Collecting/Successfully installed" 行都是有用的阶段信息。
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            onProgress?.call(stage, detail: trimmed);
          }
        });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {});

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
      throw StateError('进程超时未结束: ${arguments.first}');
    }

    if (exitCode != 0) {
      throw StateError(
        '命令失败 (exitCode=$exitCode): $executable ${arguments.join(' ')}',
      );
    }
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

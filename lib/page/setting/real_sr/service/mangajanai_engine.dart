import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';
import 'package:zephyr/util/get_path.dart';

/// 本地 MangaJaNai 超分引擎（仅 Windows）。
///
/// 复用本机已安装的 [MangaJaNaiConverterGui](https://github.com/the-database/MangaJaNaiConverterGui)
/// 内置的 chaiNNer Python 后端：生成 settings JSON 后调用
/// `run_upscale.py --settings <json>` 完成超分。
///
/// 两种执行模式：
/// - [upscale]：单文件模式，一次调用处理一张图。
/// - [upscaleFolder]：文件夹批量模式，一次调用处理整个目录，模型只加载一次。
///
/// 实际调用路径由 `MangaJaNaiBatchScheduler` 决定：它把短时间窗内到达的图片
/// 攒成一批后统一提交，批内只有一张时退回单文件模式。该调度器串行执行，
/// 保证同一时刻只有一个 MangaJaNai 进程在跑（单线程）。
///
/// 前提：用户至少在 GUI 里运行过一次任务（Python 运行时与全套模型才会就绪）。
///
/// 链配置抄自 GUI 默认工作流「Upscale Manga (Default)」：
/// - 彩色页按目标倍率自动分流到 IllustrationJaNai V3 模型；
/// - 黑白页按原图高度分档选择 MangaJaNai V1 ESRGAN 模型（自动灰度判定 +
///   AutoAdjustLevels）；
/// - 目标倍率与链模型倍率不一致时，由后端在保存前重采样到目标尺寸。
class MangaJaNaiEngine {
  MangaJaNaiEngine._();

  static const _appName = 'MangaJaNaiConverterGui';
  static const _cliScriptName = 'run_upscale.py';

  /// GUI 默认安装位置下的关键路径（基于 %APPDATA% / %LOCALAPPDATA%）。
  ///
  /// 非 Windows 平台或环境变量缺失时返回 null（引擎仅在 Windows 可选）。
  static String? get defaultPythonPath =>
      _appDataPath(const ['python', 'python', 'python.exe']);

  static String? get defaultBackendSrcDir =>
      _localAppDataPath(const ['current', 'backend', 'src']);

  static String? get defaultModelsDir => _appDataPath(const ['models']);

  static String? _appDataPath(List<String> segments) {
    final base = Platform.environment['APPDATA'];
    if (base == null || base.isEmpty) return null;
    return p.joinAll([base, _appName, ...segments]);
  }

  static String? _localAppDataPath(List<String> segments) {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null || base.isEmpty) return null;
    return p.joinAll([base, _appName, ...segments]);
  }

  /// Breeze 自带的 MangaJaNai 引擎包根目录（`<files>/mangajanai/`）。
  ///
  /// 由 `script/pack_mangajanai_windows.py` 产出的 `mangajanai-win.7z` 解压而来，
  /// 目录结构与 GUI 安装同构（`python/python`、`backend/src`、`models`），
  /// 用于未安装 MangaJaNaiConverterGui 的机器：下载解压后即可用，无需先装 GUI。
  static Future<String?> _bundledRoot() async {
    final dir = Directory(p.join(await getFilePath(), 'mangajanai'));
    return dir.existsSync() ? dir.path : null;
  }

  /// 解析实际生效的路径。
  ///
  /// 优先级：用户覆写 > 本机 GUI 安装（存在时）> Breeze 自带引擎包。
  /// 两者都缺失时返回 GUI 默认路径字符串，让 `missingRequirements`
  /// 如实报告缺失项。
  static Future<({String pythonPath, String backendSrcDir, String modelsDir})>
  _resolvePaths() async {
    final python = await RealSrSettings.loadMangaJaNaiPythonPath();
    final backend = await RealSrSettings.loadMangaJaNaiBackendSrcDir();
    final models = await RealSrSettings.loadMangaJaNaiModelsDir();
    final bundled = await _bundledRoot();

    String pick(String custom, String? guiDefault, String bundledRelative) {
      if (custom.isNotEmpty) return custom;
      final gui = guiDefault ?? '';
      final guiExists =
          gui.isNotEmpty &&
          (File(gui).existsSync() || Directory(gui).existsSync());
      if (guiExists) return gui;
      if (bundled != null) return p.join(bundled, bundledRelative);
      return gui;
    }

    return (
      pythonPath: pick(
        python,
        defaultPythonPath,
        p.join('python', 'python', 'python.exe'),
      ),
      backendSrcDir: pick(
        backend,
        defaultBackendSrcDir,
        p.join('backend', 'src'),
      ),
      modelsDir: pick(models, defaultModelsDir, 'models'),
    );
  }

  /// 公开的路径解析入口，供**本机常驻服务宿主**复用同一套优先级逻辑
  /// （用户覆写 > GUI 安装 > Breeze 自带引擎包）。
  ///
  /// 服务需要的东西与 CLI 路径完全一致：`python.exe`（跑服务端）、后端目录
  /// （`run_upscale.py` 所在）、模型目录。复用这里可以避免两处解析逻辑漂移 ——
  /// 一旦分叉，会出现「CLI 能用但服务起不来」这种极难排查的不一致。
  static Future<({String pythonPath, String backendSrcDir, String modelsDir})>
  resolvePaths() => _resolvePaths();

  /// 引擎依赖的全部链模型文件名（与 [_buildChains] 一一对应）。
  static List<String> requiredModelFiles() {
    return [
      _colorModel2x,
      _colorModel4x,
      for (final bucket in _grayBuckets) ...[
        '2x_MangaJaNai_${bucket.model}_V1_ESRGAN_${bucket.iterations2x}.pth',
        '4x_MangaJaNai_${bucket.model}_V1_ESRGAN_${bucket.iterations4x}.pth',
      ],
    ];
  }

  /// 检查本地 MangaJaNai CLI 后端是否就绪。
  ///
  /// 返回缺失组件描述列表；空列表表示就绪。
  static Future<List<String>> missingRequirements() async {
    if (!Platform.isWindows) {
      return const ['MangaJaNai engine requires Windows'];
    }

    final paths = await _resolvePaths();
    final missing = <String>[];

    if (paths.pythonPath.isEmpty || !File(paths.pythonPath).existsSync()) {
      missing.add(paths.pythonPath.isEmpty ? 'python.exe' : paths.pythonPath);
    }

    final script = p.join(paths.backendSrcDir, _cliScriptName);
    if (!File(script).existsSync()) {
      missing.add(script);
    }

    if (paths.modelsDir.isEmpty || !Directory(paths.modelsDir).existsSync()) {
      missing.add(paths.modelsDir.isEmpty ? 'models' : paths.modelsDir);
    } else {
      for (final model in requiredModelFiles()) {
        final modelPath = p.join(paths.modelsDir, model);
        if (!File(modelPath).existsSync()) {
          missing.add(model);
        }
      }
    }

    return missing;
  }

  static Future<bool> get isAvailable async =>
      (await missingRequirements()).isEmpty;

  /// 对单张图片执行超分，结果（WebP）写入 [outputPath]。
  ///
  /// [inputPath] 需为 PNG（上层超分主流程已统一转换）。
  /// [scale] 为目标放大倍率（2 或 4）；[grayscaleThreshold] 为灰度判定阈值。
  static Future<void> upscale({
    required String inputPath,
    required String outputPath,
    required int scale,
    required int grayscaleThreshold,
  }) async {
    final paths = await _resolvePaths();
    if (paths.pythonPath.isEmpty ||
        paths.backendSrcDir.isEmpty ||
        paths.modelsDir.isEmpty) {
      throw StateError('MangaJaNai 路径未配置且默认安装位置不存在');
    }
    final script = p.join(paths.backendSrcDir, _cliScriptName);
    if (!File(script).existsSync()) {
      throw StateError('MangaJaNai CLI 后端不存在: $script');
    }

    final cachePath = await getCachePath();
    final workDir = Directory(
      p.normalize(p.join(cachePath, 'mangajanai-upscale', const Uuid().v4())),
    );
    final outDir = p.join(workDir.path, 'out');

    final settingsFile = File(p.join(workDir.path, 'settings.json'));
    try {
      await Directory(outDir).create(recursive: true);
      await settingsFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          _buildSettings(
            inputFilePath: inputPath,
            outputDir: outDir,
            scale: scale,
            grayscaleThreshold: grayscaleThreshold,
            modelsDir: paths.modelsDir,
          ),
        ),
      );

      logger.d('MangaJaNai upscale: $inputPath -> $outputPath (scale=$scale)');

      // run_upscale.py 会把 stdout 重新配置为 UTF-8，这里显式按 UTF-8 解码。
      final result = await Process.run(
        paths.pythonPath,
        [_cliScriptName, '--settings', settingsFile.path],
        workingDirectory: paths.backendSrcDir,
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      // 单文件模式下输出固定为 <outDir>/<输入文件名去扩展名>.png。
      final expectedOutput = File(
        p.join(outDir, '${p.basenameWithoutExtension(inputPath)}.png'),
      );

      if (result.exitCode != 0 || !expectedOutput.existsSync()) {
        throw StateError(
          'MangaJaNai CLI 失败 (exitCode=${result.exitCode})\n'
          'stdout: ${_tail(result.stdout as String)}\n'
          'stderr: ${_tail(result.stderr as String)}',
        );
      }

      await expectedOutput.copy(outputPath);
    } finally {
      try {
        if (workDir.existsSync()) {
          workDir.deleteSync(recursive: true);
        }
      } catch (e) {
        logger.w('MangaJaNai 工作目录清理失败: ${workDir.path}', error: e);
      }
    }
  }

  /// 对一整个目录执行超分（后端文件夹模式），结果（WebP）写入 [outputDir]。
  ///
  /// 与 [upscale] 的区别在于**一次 Python 调用处理整批图片**：后端用
  /// `loaded_models` 缓存已加载的模型，因此模型只加载一次，省掉了逐张重启
  /// 解释器（torch / CUDA 初始化）与重复载入模型的固定开销。
  ///
  /// 后端批内本身是串行的（单个 upscale 线程 + `Queue(maxsize=1)`），
  /// 不会出现多张图同时抢 GPU。批量调度见 `MangaJaNaiBatchScheduler`。
  ///
  /// [inputDir] 应为仅含 PNG 的平铺目录；输出文件名为 `<输入名>.webp`。
  ///
  /// [timeout] 为整批超时。文件夹模式对损坏图片没有容错：后端预处理线程抛异常
  /// 时不会投递结束哨兵，超分线程会永久阻塞在队列上、进程不退出。这里超时后
  /// 强制杀进程并抛出异常，避免整个批量链路卡死。
  static Future<void> upscaleFolder({
    required String inputDir,
    required String outputDir,
    required int scale,
    required int grayscaleThreshold,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    if (!Platform.isWindows) {
      throw StateError('MangaJaNai engine requires Windows');
    }

    final paths = await _resolvePaths();
    if (paths.pythonPath.isEmpty ||
        paths.backendSrcDir.isEmpty ||
        paths.modelsDir.isEmpty) {
      throw StateError('MangaJaNai 路径未配置且默认安装位置不存在');
    }
    final script = p.join(paths.backendSrcDir, _cliScriptName);
    if (!File(script).existsSync()) {
      throw StateError('MangaJaNai CLI 后端不存在: $script');
    }

    final cachePath = await getCachePath();
    final workDir = Directory(
      p.normalize(p.join(cachePath, 'mangajanai-upscale', const Uuid().v4())),
    );
    final settingsFile = File(p.join(workDir.path, 'settings.json'));

    try {
      await workDir.create(recursive: true);
      await settingsFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          _buildSettings(
            outputDir: outputDir,
            inputFolderPath: inputDir,
            scale: scale,
            grayscaleThreshold: grayscaleThreshold,
            modelsDir: paths.modelsDir,
          ),
        ),
      );

      logger.d(
        'MangaJaNai batch upscale: $inputDir -> $outputDir (scale=$scale)',
      );

      final process = await Process.start(
        paths.pythonPath,
        [_cliScriptName, '--settings', settingsFile.path],
        workingDirectory: paths.backendSrcDir,
        runInShell: false,
      );

      // run_upscale.py 会把 stdout 重新配置为 UTF-8，这里显式按 UTF-8 解码；
      // 允许非法字节，避免解码失败中断整批任务。
      const decoder = Utf8Decoder(allowMalformed: true);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutDone = process.stdout
          .transform(decoder)
          .listen(stdoutBuffer.write)
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(decoder)
          .listen(stderrBuffer.write)
          .asFuture<void>();

      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        logger.w('MangaJaNai 批量超分超时（${timeout.inMinutes} 分钟），强制终止进程');
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (e) {
          logger.w('MangaJaNai 进程终止失败', error: e);
        }
        try {
          await process.exitCode.timeout(const Duration(seconds: 10));
        } catch (_) {}
        throw StateError('MangaJaNai 批量超分超时（${timeout.inMinutes} 分钟）');
      }

      await Future.wait([stdoutDone, stderrDone]);

      if (exitCode != 0) {
        throw StateError(
          'MangaJaNai CLI 失败 (exitCode=$exitCode)\n'
          'stdout: ${_tail(stdoutBuffer.toString())}\n'
          'stderr: ${_tail(stderrBuffer.toString())}',
        );
      }
    } finally {
      try {
        if (workDir.existsSync()) {
          workDir.deleteSync(recursive: true);
        }
      } catch (e) {
        logger.w('MangaJaNai 工作目录清理失败: ${workDir.path}', error: e);
      }
    }
  }

  // =========================================================
  // settings JSON 构建
  // =========================================================

  /// 交给后端的模型分块大小。
  ///
  /// 后端 `ModelTileSize` 接受 `"Auto (Estimate)"` / `"Maximum"` /
  /// `"No Tiling"` / 十进制字符串。这里**刻意不用 ESTIMATE**：后端的估算只读设备
  /// **总**显存（`torch.cuda.mem_get_info` 返回的 free 值在 `upscale_image.py`
  /// 里被丢弃），按 `total * 0.75 * 0.8` 推算预算；与其它应用共享 GPU 时会高估
  /// 可用显存，取到过大的分块 → OOM，或触发 CUDA 系统内存回退（后者慢一个数量级）。
  ///
  /// Breeze 常在后台与用户的游戏/应用共享 GPU，故取固定值。512 为实测基线：
  /// 2x、1300p 档下单张 0.57s、显存峰值 4.5GB。
  static const _mangaJaNaiTileSize = '512';

  static const _colorModel2x =
      '2x_IllustrationJaNai_V3denoise_FDAT_M_unshuffle_30k_fp16.safetensors';
  static const _colorModel4x =
      '4x_IllustrationJaNai_V3denoise_FDAT_M_47k_fp16.safetensors';

  /// 黑白模型按原图高度分档（抄自 GUI 默认工作流）。
  ///
  /// [minHeight]/[maxHeight] 为 `0x0` 格式的分辨率区间（0 表示不限制）；
  /// [model] 为模型档位名；不同倍率的 ESRGAN 训练迭代数不同，需分别指定。
  static const _grayBuckets = [
    (
      minHeight: '0x0',
      maxHeight: '0x1250',
      model: '1200p',
      iterations2x: '70k',
      iterations4x: '70k',
    ),
    (
      minHeight: '0x1251',
      maxHeight: '0x1350',
      model: '1300p',
      iterations2x: '75k',
      iterations4x: '75k',
    ),
    (
      minHeight: '0x1351',
      maxHeight: '0x1450',
      model: '1400p',
      iterations2x: '70k',
      iterations4x: '105k',
    ),
    (
      minHeight: '0x1451',
      maxHeight: '0x1550',
      model: '1500p',
      iterations2x: '90k',
      iterations4x: '105k',
    ),
    (
      minHeight: '0x1551',
      maxHeight: '0x1760',
      model: '1600p',
      iterations2x: '90k',
      iterations4x: '70k',
    ),
    (
      minHeight: '0x1761',
      maxHeight: '0x1984',
      model: '1920p',
      iterations2x: '70k',
      iterations4x: '105k',
    ),
    (
      minHeight: '0x1985',
      maxHeight: '0x0',
      model: '2048p',
      iterations2x: '95k',
      iterations4x: '70k',
    ),
  ];

  /// 构建后端 settings JSON。
  ///
  /// [inputFilePath] 与 [inputFolderPath] 二选一：前者为单文件模式
  /// （`SelectedTabIndex = 0`），后者为文件夹批量模式（`SelectedTabIndex = 1`）。
  static Map<String, Object> _buildSettings({
    required String outputDir,
    required int scale,
    required int grayscaleThreshold,
    required String modelsDir,
    String inputFilePath = '',
    String inputFolderPath = '',
  }) {
    final isBatch = inputFolderPath.isNotEmpty;
    return {
      // 后端语义：0 = CPU；非 0 = 非 CPU 设备列表中的位置（单卡机即 GPU）。
      'SelectedDeviceIndex': 1,
      'UseFp16': true,
      'ModelsDirectory': modelsDir,
      'SelectedWorkflowIndex': 0,
      'Workflows': {
        r'$values': [
          {
            'WorkflowName': isBatch ? 'Breeze Upscale Batch' : 'Breeze Upscale',
            'WorkflowIndex': 0,
            // 0 = 单文件标签页，1 = 文件夹标签页（后端据此选择处理函数）。
            'SelectedTabIndex': isBatch ? 1 : 0,
            'InputFilePath': inputFilePath,
            'InputFolderPath': inputFolderPath,
            'OutputFilename': '%filename%',
            'OutputFolderPath': outputDir,
            // 批量模式必须保持 true：单文件模式下输出已存在时会直接 return
            // 而不投递结束哨兵，导致后端超分线程永久阻塞。
            'OverwriteExistingFiles': true,
            'UpscaleImages': true,
            'UpscaleArchives': false,
            'ResizeHeightAfterUpscale': 0,
            'ResizeWidthAfterUpscale': 0,
            // 直接输出 WebP（q90）：省掉「后端编码 PNG → Dart 侧解码再编码
            // WebP」的一次完整往返。PNG 是无损容器，编码慢且体积是 WebP 的
            // 数倍，这条路在批量场景下开销可观。
            'WebpSelected': true,
            'AvifSelected': false,
            'PngSelected': false,
            'JpegSelected': false,
            'UseLosslessCompression': false,
            'LossyCompressionQuality': 90,
            'ShowLossySettings': false,
            'ModeScaleSelected': true,
            'UpscaleScaleFactor': scale,
            'ModeWidthSelected': false,
            'ModeHeightSelected': false,
            'ModeFitToDisplaySelected': false,
            'DisplayDevice': '',
            'DisplayDeviceWidth': 0,
            'DisplayDeviceHeight': 0,
            'DisplayPortraitSelected': false,
            'ShowAdvancedSettings': false,
            'GrayscaleDetectionThreshold': grayscaleThreshold,
            'Chains': {r'$values': _buildChains()},
          },
        ],
      },
    };
  }

  /// 构建 GUI 官方默认的 16 条链（与倍率无关，链匹配按目标倍率自动选择）。
  static List<Object> _buildChains() {
    final chains = <Object>[
      _chain(
        number: '1',
        minResolution: '0x0',
        maxResolution: '0x0',
        isGrayscale: false,
        minScaleFactor: 0,
        maxScaleFactor: 2,
        modelFilePath: _colorModel2x,
      ),
      _chain(
        number: '2',
        minResolution: '0x0',
        maxResolution: '0x0',
        isGrayscale: false,
        minScaleFactor: 2,
        maxScaleFactor: 0,
        modelFilePath: _colorModel4x,
      ),
    ];

    var chainNumber = 3;
    for (final bucket in _grayBuckets) {
      chains.add(
        _chain(
          number: '${chainNumber++}',
          minResolution: bucket.minHeight,
          maxResolution: bucket.maxHeight,
          isGrayscale: true,
          minScaleFactor: 0,
          maxScaleFactor: 2,
          modelFilePath:
              '2x_MangaJaNai_${bucket.model}_V1_ESRGAN_${bucket.iterations2x}.pth',
        ),
      );
      chains.add(
        _chain(
          number: '${chainNumber++}',
          minResolution: bucket.minHeight,
          maxResolution: bucket.maxHeight,
          isGrayscale: true,
          minScaleFactor: 2,
          maxScaleFactor: 0,
          modelFilePath:
              '4x_MangaJaNai_${bucket.model}_V1_ESRGAN_${bucket.iterations4x}.pth',
        ),
      );
    }

    return chains;
  }

  /// 单条链配置；字段名与后端 `UpscaleChain` 模型严格一致，不可增删。
  static Map<String, Object> _chain({
    required String number,
    required String minResolution,
    required String maxResolution,
    required bool isGrayscale,
    required int minScaleFactor,
    required int maxScaleFactor,
    required String modelFilePath,
  }) {
    return {
      'ChainNumber': number,
      'MinResolution': minResolution,
      'MaxResolution': maxResolution,
      'IsGrayscale': isGrayscale,
      'IsColor': !isGrayscale,
      'MinScaleFactor': minScaleFactor,
      'MaxScaleFactor': maxScaleFactor,
      'ModelFilePath': modelFilePath,
      'ModelTileSize': _mangaJaNaiTileSize,
      'AutoAdjustLevels': isGrayscale,
      'ResizeHeightBeforeUpscale': 0,
      'ResizeWidthBeforeUpscale': 0,
      'ResizeFactorBeforeUpscale': 100.0,
    };
  }

  /// 截取进程输出末尾用于错误信息，避免超长日志刷屏。
  static String _tail(String text, [int maxLength = 2000]) {
    final trimmed = text.trim();
    if (trimmed.length <= maxLength) return trimmed;
    return '...${trimmed.substring(trimmed.length - maxLength)}';
  }
}

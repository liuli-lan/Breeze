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
/// 内置的 chaiNNer Python 后端：为单张图片生成 settings JSON，
/// 然后调用 `run_upscale.py --settings <json>` 完成超分。
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

  /// 解析实际生效的路径（用户覆写优先，留空回退默认值）。
  static Future<({String pythonPath, String backendSrcDir, String modelsDir})>
  _resolvePaths() async {
    final python = await RealSrSettings.loadMangaJaNaiPythonPath();
    final backend = await RealSrSettings.loadMangaJaNaiBackendSrcDir();
    final models = await RealSrSettings.loadMangaJaNaiModelsDir();
    return (
      pythonPath: python.isNotEmpty ? python : (defaultPythonPath ?? ''),
      backendSrcDir: backend.isNotEmpty
          ? backend
          : (defaultBackendSrcDir ?? ''),
      modelsDir: models.isNotEmpty ? models : (defaultModelsDir ?? ''),
    );
  }

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
    if (!Platform.isWindows)
      return const ['MangaJaNai engine requires Windows'];

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

  /// 对单张图片执行超分，结果（PNG）写入 [outputPath]。
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
            inputPath: inputPath,
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

  // =========================================================
  // settings JSON 构建
  // =========================================================

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

  static Map<String, Object> _buildSettings({
    required String inputPath,
    required String outputDir,
    required int scale,
    required int grayscaleThreshold,
    required String modelsDir,
  }) {
    return {
      // 后端语义：0 = CPU；非 0 = 非 CPU 设备列表中的位置（单卡机即 GPU）。
      'SelectedDeviceIndex': 1,
      'UseFp16': true,
      'ModelsDirectory': modelsDir,
      'SelectedWorkflowIndex': 0,
      'Workflows': {
        r'$values': [
          {
            'WorkflowName': 'Breeze Upscale',
            'WorkflowIndex': 0,
            'SelectedTabIndex': 0,
            'InputFilePath': inputPath,
            'InputFolderPath': '',
            'OutputFilename': '%filename%',
            'OutputFolderPath': outputDir,
            'OverwriteExistingFiles': true,
            'UpscaleImages': true,
            'UpscaleArchives': false,
            'ResizeHeightAfterUpscale': 0,
            'ResizeWidthAfterUpscale': 0,
            // 统一输出 PNG，后续由应用自身转 WebP，保持与其他引擎一致。
            'WebpSelected': false,
            'AvifSelected': false,
            'PngSelected': true,
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
      'ModelTileSize': 'Auto (Estimate)',
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

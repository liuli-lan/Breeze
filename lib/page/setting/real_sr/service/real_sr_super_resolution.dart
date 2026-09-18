import 'dart:io';
import 'dart:ui' as ui;

import 'package:coreml_upscale/coreml_upscale.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pool/pool.dart';
import 'package:uuid/uuid.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/comic_info/method/export_comic.dart';
import 'package:zephyr/page/setting/real_sr/service/android_ncnn_model_config.dart';
import 'package:zephyr/page/setting/real_sr/service/desktop_ncnn_model_config.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_batch.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_engine.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_remote.dart';
import 'package:zephyr/page/setting/real_sr/service/mjn_local_service.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';
import 'package:zephyr/src/rust/api/image.dart';
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/util/coreml_model_config.dart';
import 'package:zephyr/util/coreml_model_loader.dart';
import 'package:zephyr/util/event/image_upscaled_event.dart';
import 'package:zephyr/util/get_path.dart';
import 'package:zephyr/widgets/toast.dart';

/// Breeze 内置 RealSR / Real-CUGAN / CoreML 超分封装
///
/// - Android：调用 bundled 的 waifu2x-ncnn CLI
/// - iOS / macOS：从 `deretame/breeze-binary` 下载 `MacOS-iOS.7z` 后，
///   调用 `CoreMLUpscale` 使用用户选择的 waifu2x / Real-CUGAN 模型
/// - Windows / Linux：从 `deretame/breeze-binary` 下载模型后，
///   调用 `getFilePath()/super_resolution/` 下的 waifu2x-ncnn-vulkan
///   或 realcugan-ncnn-vulkan
class RealSrSuperResolution {
  RealSrSuperResolution._();

  static const MethodChannel _channel = MethodChannel(
    'realsr_super_resolution',
  );

  /// GitHub 上存放桌面端模型压缩包的仓库。
  static const String _binaryRepoBaseUrl =
      'https://github.com/deretame/breeze-binary/raw/main';

  /// 最大并发超分任务数，默认 1（单线程）。
  ///
  /// 仅约束 NCNN / CoreML 路径；MangaJaNai 引擎由 `MangaJaNaiBatchScheduler`
  /// 串行调度，不经过本并发池。
  ///
  /// 修改后会立即影响新任务：setter 会重建池对象，因此**已在执行以及已排队**的
  /// 任务都留在旧池中按旧并发跑完。
  static int get maxConcurrency {
    if (_maxConcurrency != null) return _maxConcurrency!;
    return RealSrSettings.defaultConcurrency;
  }

  static set maxConcurrency(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'maxConcurrency', 'must be >= 1');
    }
    _maxConcurrency = value;
    _pool = Pool(value);
  }

  static int? _maxConcurrency;
  static Pool _pool = Pool(maxConcurrency);

  /// 桌面端模型下载/解压目录：`<getFilePath()>/super_resolution`
  static Future<String> get _modelDirectory async {
    return p.join(await getFilePath(), 'super_resolution');
  }

  /// 当前设备是否支持内置超分（包含模型/可执行文件是否已就绪）。
  ///
  /// 先看用户选定的引擎，再看平台：
  /// - 远程 MangaJaNai：探活局域网服务端（任意平台可用）
  /// - 本地 MangaJaNai：检查本机 CLI 后端与模型，仅 Windows
  /// - Android：arm64-v8a 且 NCNN 模型已下载并解压
  /// - iOS / macOS：CoreML 模型已下载并解压
  /// - Windows / Linux：存在对应平台的 realcugan-ncnn-vulkan 可执行文件
  static Future<bool> get isAvailable async {
    final engine = await RealSrSettings.loadSrEngine();

    // 远程服务端与平台无关；探活带 30s 缓存，热路径上开销可忽略。
    if (engine.isRemote) {
      return MangaJaNaiRemoteEngine.isAvailable;
    }

    // 本地 MangaJaNai CLI 后端仅 Windows 有安装约定。非 Windows 上该枚举项
    // 不会出现在设置页，但配置可能被同步/迁移过来，这里兜底拒绝。
    if (engine.isLocalCli) {
      if (!Platform.isWindows) return false;

      // 优先看**本机常驻服务**是否就绪：就绪时它比 CLI 路径快约 5 倍
      // （实测单页 1.19 s vs 5.79~6.02 s）。
      //
      // 这里刻意**只读状态、不触发启动**：本方法在每张图超分前都会被调用，
      // 在这里启动服务会让首个请求白等一次进程拉起，失败时更会反复重试。
      // 启动时机交给设置页（主动）与超分主流程（后台预热），见 requestStartInBackground。
      if (MjnLocalService.instance.isReady) return true;

      // 回退：CLI 路径就绪也算可用。
      // **这条回退是必须的** —— 服务可能因为端口冲突、Python 异常、崩溃超限等原因
      // 起不来，此时超分能力不应该整个消失，只是退回原来的速度。
      return MangaJaNaiEngine.isAvailable;
    }

    if (Platform.isAndroid) {
      try {
        // 内置 NCNN 需要 arm64-v8a（bundled 的 waifu2x CLI 只打包了该 ABI）。
        //
        // 这里刻意不用 isDeviceSupported —— 那个判断的语义是「要不要展示超分设置
        // 入口」，已放宽成「Android 恒 true」（好让非 arm64 设备也能进去配置远程
        // 服务器）。拿它当 NCNN 的可用性门槛，会让入口的放宽失去意义。
        if (!await _isAndroidNcnnDeviceSupported) return false;
        return await _isAndroidNcnnAvailable(
          variant: AndroidNcnnModelConfig.variantFor(
            mode: AndroidNcnnModelConfig.defaultMode,
            noise: AndroidNcnnModelConfig.defaultNoise,
          ),
        );
      } catch (_) {
        return false;
      }
    }

    if (Platform.isIOS || Platform.isMacOS) {
      return _isCoreMLAvailable;
    }

    if (Platform.isWindows || Platform.isLinux) {
      final modelRoot = await _modelDirectory;
      final mode = await RealSrSettings.loadDesktopNcnnMode();
      final exeName = DesktopNcnnModelConfig.executableNameFor(mode);
      return File(p.join(modelRoot, exeName)).existsSync();
    }

    return false;
  }

  /// 当前平台是否提供超分能力，用于决定设置页入口是否显示。
  ///
  /// **不检查模型是否就绪**，只回答「这个平台上有没有超分这回事」。
  ///
  /// Android 上恒为 true：原先的「必须 arm64-v8a」门槛只对内置 NCNN 成立，
  /// 而远程引擎把算力放在服务端、与本机架构无关。继续拿 CPU 架构当入口门槛，
  /// 会让 32 位设备连「配置远程服务器」的入口都看不到（进不去设置页就无从切换
  /// 引擎，等于把远程这条路彻底堵死）。非 arm64 设备上内置 NCNN 不可用的情况，
  /// 由 [isAvailable] 表达，并在设置页里以「不可用」提示呈现。
  static Future<bool> get isDeviceSupported async {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux;
  }

  /// Android 设备是否支持内置 NCNN 超分（需要 arm64-v8a）。
  ///
  /// bundled 的 waifu2x CLI 只提供 arm64-v8a 版本，非该 ABI 的设备上
  /// `nativeLibraryDir` 里找不到可执行文件。
  static Future<bool> get _isAndroidNcnnDeviceSupported async {
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.supportedAbis.contains('arm64-v8a');
    } catch (_) {
      return false;
    }
  }

  /// 检查 Android NCNN 模型是否已就绪。
  static Future<bool> _isAndroidNcnnAvailable({
    required NcnnModelVariant variant,
  }) async {
    final modelRoot = await _modelDirectory;
    final modelDir = p.join(modelRoot, variant.modelDir);
    final modelFiles = _androidModelFilesFor(variant);
    for (final relative in modelFiles) {
      if (!File(p.join(modelDir, relative)).existsSync()) {
        return false;
      }
    }
    return true;
  }

  /// 返回指定 Android NCNN 变体所需的模型文件相对路径列表。
  static List<String> _androidModelFilesFor(NcnnModelVariant variant) {
    final modelDir = variant.modelDir.toLowerCase();
    final isWaifu2x =
        modelDir.contains('models-cunet') || modelDir.contains('models-upconv');

    if (!isWaifu2x) {
      final suffix = variant.noise == -1
          ? 'conservative'
          : variant.noise == 0
          ? 'no-denoise'
          : 'denoise${variant.noise}x';
      return [
        'up${variant.scale}x-$suffix.param',
        'up${variant.scale}x-$suffix.bin',
      ];
    }

    if (isWaifu2x) {
      if (variant.noise == -1) {
        return ['scale2.0x_model.param', 'scale2.0x_model.bin'];
      }
      if (variant.scale == 1) {
        return [
          'noise${variant.noise}_model.param',
          'noise${variant.noise}_model.bin',
        ];
      }
      return [
        'noise${variant.noise}_scale2.0x_model.param',
        'noise${variant.noise}_scale2.0x_model.bin',
      ];
    }

    return [];
  }

  /// 检查 iOS / macOS 的 CoreML 模型是否已就绪。
  static Future<bool> get _isCoreMLAvailable async {
    final results = await Future.wait([
      CoreMLModelLoader.isModelAvailable(
        CoreMLModelConfig.defaultVariant.fileName,
      ),
      CoreMLModelLoader.isModelAvailable(
        CoreMLModelConfig.families[1].variants.first.fileName,
      ),
    ]);
    return results.every((e) => e);
  }

  /// 当前平台对应的 7z 压缩包文件名。
  static String? get _assetName {
    if (Platform.isAndroid) return 'realsr-android.7z';
    if (Platform.isWindows) return 'realsr-win.7z';
    if (Platform.isLinux) return 'realsr-linux.7z';
    return null;
  }

  /// 当前平台手动下载模型的直链（可在浏览器中打开）。
  ///
  /// - Android：`realsr-android.7z`
  /// - Windows：`realsr-win.7z`
  /// - Linux：`realsr-linux.7z`
  /// - iOS / macOS：`MacOS-iOS.7z`
  static String? get manualDownloadUrl {
    if (Platform.isIOS || Platform.isMacOS) {
      return '${CoreMLModelConfig.binaryRepoBaseUrl}/${CoreMLModelConfig.archiveName}';
    }
    final assetName = _assetName;
    if (assetName == null) return null;
    return '$_binaryRepoBaseUrl/$assetName';
  }

  /// 7z 文件魔数（6 字节）。
  static const List<int> _sevenZSignature = [
    0x37,
    0x7A,
    0xBC,
    0xAF,
    0x27,
    0x1C,
  ];

  /// 校验文件是否为有效的 7z 压缩包（仅检查头部魔数）。
  static Future<bool> isSevenZArchive(File file) async {
    try {
      if (!file.existsSync()) return false;
      final raf = await file.open();
      try {
        final bytes = await raf.read(_sevenZSignature.length);
        if (bytes.length < _sevenZSignature.length) return false;
        for (var i = 0; i < _sevenZSignature.length; i++) {
          if (bytes[i] != _sevenZSignature[i]) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 导入本地手动下载的 7z 模型压缩包。
  ///
  /// 会先校验 7z 格式与当前平台所需的模型内容，全部通过后替换本地模型。
  static Future<void> importModelArchive(String archivePath) async {
    final archiveFile = File(archivePath);
    if (!archiveFile.existsSync()) {
      throw FileSystemException('模型压缩包不存在', archivePath);
    }
    if (!await isSevenZArchive(archiveFile)) {
      throw const FormatException('不是有效的 7z 压缩包');
    }

    final tempDir = await Directory.systemTemp.createTemp(
      'breeze_realsr_import_',
    );
    try {
      try {
        await decompress7Z(archivePath: archivePath, destPath: tempDir.path);
      } catch (e, s) {
        logger.w('手动导入：7z 解压失败', error: e, stackTrace: s);
        throw const FormatException('7z 压缩包已损坏或解压失败');
      }

      final missing = _missingModelFiles(tempDir);
      if (missing != null) {
        throw FormatException('压缩包内容不符合当前平台要求: $missing');
      }

      if (Platform.isIOS || Platform.isMacOS) {
        final tempBase = await getTemporaryDirectory();
        final modelsDir = Directory(p.join(tempBase.path, 'coreml_models'));
        final destDir = Directory(
          p.join(modelsDir.path, CoreMLModelConfig.archiveSubDir),
        );
        if (modelsDir.existsSync()) {
          await modelsDir.delete(recursive: true);
        }
        await modelsDir.create(recursive: true);
        await _moveDirectory(
          Directory(p.join(tempDir.path, CoreMLModelConfig.archiveSubDir)),
          destDir,
        );
      } else {
        final destDir = await _modelDirectory;
        if (Directory(destDir).existsSync()) {
          await Directory(destDir).delete(recursive: true);
        }
        await Directory(p.dirname(destDir)).create(recursive: true);
        await _moveDirectory(tempDir, Directory(destDir));
      }

      // Linux / macOS 需要给可执行文件授权
      if (Platform.isLinux || Platform.isMacOS) {
        final modelRoot = await _modelDirectory;
        for (final name in ['realcugan-ncnn-vulkan', 'waifu2x-ncnn-vulkan']) {
          final exe = p.join(modelRoot, name);
          try {
            await Process.run('chmod', ['+x', exe], runInShell: false);
          } catch (e, s) {
            logger.w('RealSR 可执行文件授权失败: $exe', error: e, stackTrace: s);
          }
        }
      }

      _missingModelNotified = false;
    } finally {
      try {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  /// 检查解压后的内容是否满足当前平台需求，返回缺失内容描述；null 表示通过。
  static String? _missingModelFiles(Directory extractedRoot) {
    if (Platform.isAndroid) {
      final variant = AndroidNcnnModelConfig.variantFor(
        mode: AndroidNcnnModelConfig.defaultMode,
        noise: AndroidNcnnModelConfig.defaultNoise,
      );
      final modelDir = Directory(p.join(extractedRoot.path, variant.modelDir));
      if (!modelDir.existsSync()) {
        return '缺少模型目录 ${variant.modelDir}';
      }
      for (final relative in _androidModelFilesFor(variant)) {
        if (!File(p.join(modelDir.path, relative)).existsSync()) {
          return '缺少模型文件 ${p.join(variant.modelDir, relative)}';
        }
      }
      return null;
    }

    if (Platform.isWindows || Platform.isLinux) {
      final suffix = Platform.isWindows ? '.exe' : '';
      const exes = ['realcugan-ncnn-vulkan', 'waifu2x-ncnn-vulkan'];
      final hasExecutable = exes.any(
        (name) => File(p.join(extractedRoot.path, '$name$suffix')).existsSync(),
      );
      if (!hasExecutable) {
        return '缺少 waifu2x / Real-CUGAN 可执行文件';
      }
      const modelDirs = [
        'models-pro',
        'models-se',
        'models-upconv_7_anime_style_art_rgb',
      ];
      final hasModelDir = modelDirs.any(
        (name) => Directory(p.join(extractedRoot.path, name)).existsSync(),
      );
      if (!hasModelDir) {
        return '缺少模型目录（models-pro / models-se 等）';
      }
      return null;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      final subDir = Directory(
        p.join(extractedRoot.path, CoreMLModelConfig.archiveSubDir),
      );
      if (!subDir.existsSync()) {
        return '缺少 ${CoreMLModelConfig.archiveSubDir} 目录';
      }
      for (final family in CoreMLModelConfig.families) {
        for (final variant in family.variants) {
          final path = p.join(subDir.path, variant.fileName);
          final exists = variant.fileName.endsWith('.mlpackage')
              ? Directory(path).existsSync()
              : File(path).existsSync();
          if (!exists) return '缺少模型 ${variant.fileName}';
        }
      }
      return null;
    }

    return '当前平台不支持手动导入超分模型';
  }

  /// 把目录移动到目标位置；跨磁盘/分区失败时退回复制后删除。
  static Future<void> _moveDirectory(Directory from, Directory to) async {
    try {
      await from.rename(to.path);
    } on FileSystemException {
      await to.create(recursive: true);
      await _copyDirectoryContents(from, to);
      await from.delete(recursive: true);
    }
  }

  static Future<void> _copyDirectoryContents(
    Directory from,
    Directory to,
  ) async {
    await for (final entity in from.list()) {
      final targetPath = p.join(to.path, p.basename(entity.path));
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
        await _copyDirectoryContents(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }

  /// 下载并解压当前平台需要的超分模型。
  ///
  /// - Android：下载 `realsr-android.7z` 并解压 NCNN 模型。
  /// - iOS / macOS：下载 `MacOS-iOS.7z` 并解压 CoreML 模型。
  /// - Windows / Linux：下载对应平台的 realcugan-ncnn-vulkan 压缩包。
  ///
  /// [force] 为 true 时，会先删除本地已有模型再重新下载。
  static Future<void> downloadModel({
    void Function(int received, int total)? onProgress,
    bool force = false,
  }) async {
    if (Platform.isIOS || Platform.isMacOS) {
      final tempDir = await getTemporaryDirectory();
      final modelsDir = Directory(p.join(tempDir.path, 'coreml_models'));

      if (force && modelsDir.existsSync()) {
        await modelsDir.delete(recursive: true);
      }

      // 压缩包里包含两个模型，下载任意一个都会把完整压缩包拉下来。
      await CoreMLModelLoader.prepareModel(
        CoreMLModelConfig.defaultVariant.fileName,
        onProgress: onProgress,
      );
      // 确保另一个模型也被解压出来
      await CoreMLModelLoader.prepareModel(
        CoreMLModelConfig.families[1].variants.first.fileName,
      );
      return;
    }

    final assetName = _assetName;
    if (assetName == null) {
      throw UnsupportedError('当前平台不支持下载 RealSR 模型');
    }

    final url = '$_binaryRepoBaseUrl/$assetName';
    final cachePath = await getCachePath();
    final archivePath = p.join(cachePath, assetName);
    final destDir = await _modelDirectory;

    if (force && Directory(destDir).existsSync()) {
      await Directory(destDir).delete(recursive: true);
    }

    await Directory(destDir).create(recursive: true);

    try {
      // 强制重新下载时先删掉本地缓存的压缩包
      if (force && File(archivePath).existsSync()) {
        await File(archivePath).delete();
      }

      await WindHttp().download(
        url,
        archivePath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received, total);
        },
      );

      await decompress7Z(archivePath: archivePath, destPath: destDir);

      // Linux / macOS 需要给可执行文件授权
      if (Platform.isLinux || Platform.isMacOS) {
        final modelRoot = await _modelDirectory;
        for (final name in ['realcugan-ncnn-vulkan', 'waifu2x-ncnn-vulkan']) {
          final exe = p.join(modelRoot, name);
          try {
            await Process.run('chmod', ['+x', exe], runInShell: false);
          } catch (e, s) {
            logger.w('RealSR 可执行文件授权失败: $exe', error: e, stackTrace: s);
          }
        }
      }

      _missingModelNotified = false;
      showSuccessToast('模型下载完成');
    } finally {
      try {
        await File(archivePath).delete();
      } catch (_) {}
    }
  }

  /// 删除当前平台已下载的超分模型。
  ///
  /// - iOS / macOS：删除临时目录下的 CoreML 模型目录
  /// - Android / Windows / Linux：删除 `super_resolution` 目录及缓存中的压缩包
  static Future<void> deleteModel() async {
    if (Platform.isIOS || Platform.isMacOS) {
      final tempDir = await getTemporaryDirectory();
      final modelsDir = Directory(p.join(tempDir.path, 'coreml_models'));
      if (modelsDir.existsSync()) {
        await modelsDir.delete(recursive: true);
      }
      _missingModelNotified = false;
      return;
    }

    if (Platform.isAndroid || Platform.isWindows || Platform.isLinux) {
      final destDir = await _modelDirectory;
      if (Directory(destDir).existsSync()) {
        await Directory(destDir).delete(recursive: true);
      }

      final assetName = _assetName;
      if (assetName != null) {
        final archivePath = p.join(await getCachePath(), assetName);
        final archiveFile = File(archivePath);
        if (archiveFile.existsSync()) {
          await archiveFile.delete();
        }
      }

      _missingModelNotified = false;
      return;
    }

    throw UnsupportedError('当前平台不支持删除 RealSR 模型');
  }

  static const Set<String> _supportedFormats = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  };

  /// 检测图片是否可被 RealSR 处理。
  ///
  /// 只读取文件头做判断，返回规范化扩展名；不支持（含动图 WebP）返回 null。
  static Future<String?> _detectUpscalableExtension(File file) async {
    final rawExt = await detectImageExtension(file);
    final normalizedExt = rawExt.toLowerCase();
    if (!_supportedFormats.contains(normalizedExt)) return null;
    if (normalizedExt == '.webp' && await isAnimatedWebP(file)) return null;
    return normalizedExt;
  }

  /// 判断图片是否需要超分：仅当能解析出横向分辨率且小于阈值时返回 true。
  static Future<bool> shouldUpscale(
    String inputPath, {
    RealSrResolutionThreshold? threshold,
  }) async {
    logger.d('Checking if $inputPath needs to be upscaled...');
    final effectiveThreshold =
        threshold ?? await RealSrSettings.loadResolutionThreshold();

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(inputPath);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return descriptor.width < effectiveThreshold.maxWidth;
    } catch (e, s) {
      logger.w('RealSR 无法解析图片尺寸，跳过超分: $inputPath', error: e, stackTrace: s);
      return false;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static bool _missingModelNotified = false;

  /// 对单张图片做超分放大，成功后再转换为 WebP 以节省空间。
  static Future<void> upscaleAndConvertToWebp(String inputPath) async {
    final autoUpscale = await RealSrSettings.loadAutoUpscale();
    if (!autoUpscale) return;

    // 先做廉价的文件头格式检测，不支持的格式（如 GIF、动图 WebP）直接跳过，
    // 避免进入分辨率解析、模型检查与超分队列。
    final supportedExt = await _detectUpscalableExtension(File(inputPath));
    if (supportedExt == null) {
      logger.d('RealSR 不支持的图片格式，跳过超分: $inputPath');
      return;
    }

    final engine = await RealSrSettings.loadSrEngine();

    if (!await isAvailable) {
      if (!_missingModelNotified) {
        _missingModelNotified = true;
        // 远程模式下「模型不完整」的说法会误导：缺的是服务端连通性/配置。
        showErrorToast(engine.isRemote ? t.realSr.remoteNotReady : '模型不完整');
      }
      return;
    }

    final threshold = await RealSrSettings.loadResolutionThreshold();
    if (!await shouldUpscale(inputPath, threshold: threshold)) {
      logger.d('Input $inputPath does not need to be upscaled.');
      return;
    }

    // 远程引擎：走独立路径，直接发原始编码。
    //
    // 两处刻意与本地路径不同：
    // - **不转 PNG**：本地 CLI 需要 PNG，而服务端 pyvips 按内容识别格式，
    //   转 PNG 只会让上传体积涨 3-5 倍（PLAN §5.4）。
    // - **不进 MangaJaNaiBatchScheduler**：攒批是为「本地 CLI 每次调用都要付
    //   Python/torch 冷启动」设计的；服务端常驻且自带两通道调度，攒批只会
    //   平白增加延迟。
    if (engine.isRemote) {
      await _upscaleRemote(inputPath);
      return;
    }

    final tileSize = await RealSrSettings.loadTileSize();

    // Android NCNN 通过 OpenCV imwrite 写图，只能按扩展名识别格式；
    // 输出路径若带 webp/jpg 等扩展名会崩溃。因此 Android 先写到临时 PNG，
    // 转 WebP 后再覆盖回原路径。
    if (Platform.isAndroid) {
      final cacheDir = await getCachePath();
      final tempOutput = p.join(
        cacheDir,
        'realsr_output_${const Uuid().v4()}.png',
      );

      try {
        final upscaled = await upscale(
          inputPath: inputPath,
          outputPath: tempOutput,
          tileSize: tileSize,
        );
        if (!upscaled) return;

        // 超分成功后输出的是 PNG，再转换为 WebP 以节省空间
        await convertImageToWebp(inputPath: tempOutput, imageType: 'png');
        await File(tempOutput).rename(inputPath);
        _notifyUpscaled(inputPath);
      } catch (e, s) {
        logger.w('Android 超分/WebP 转换失败: $inputPath', error: e, stackTrace: s);
        rethrow;
      } finally {
        try {
          if (File(tempOutput).existsSync()) {
            await File(tempOutput).delete();
          }
        } catch (_) {}
      }
      return;
    }

    // Windows / Linux：根据引擎选择走本地 MangaJaNai 或 NCNN CLI。
    // （远程引擎已在上面提前返回。）
    if (Platform.isWindows || Platform.isLinux) {
      final useMangaJaNai = engine.isLocalCli;

      if (useMangaJaNai) {
        // ① 本机常驻服务已就绪 → 走它。这是主路径：服务把 torch 与模型常驻显存，
        //    固定成本只付一次（单页实测约 1.19 s，而 CLI 每次 spawn 要 5.79~6.02 s）。
        final service = MjnLocalService.instance;
        if (Platform.isWindows && service.isReady) {
          try {
            await _upscaleLocalService(inputPath);
            return;
          } catch (e, s) {
            // 服务中途挂掉（崩溃、看门狗重启、端口被抢）不该让这张图白丢 ——
            // 救回 CLI 路径重试一次。代价是这张图慢（约 6 s），但结果保住了。
            logger.w(
              '本机服务超分失败，回退 CLI 路径重试: $inputPath',
              error: e,
              stackTrace: s,
            );
            service.requestStartInBackground(force: true);
          }
        } else if (Platform.isWindows) {
          // ② 服务还没就绪 → **本次仍走 CLI**（不让首张图白等一次进程启动），
          //    同时在后台把服务拉起来，后续图片就能用上它。
          service.requestStartInBackground();
        }

        // MangaJaNai 走批量调度器：短时间窗内到达的图片攒成一批后，由单次 CLI
        // 调用处理整批，模型只加载一次；调度器串行执行，即单线程，不会出现多个
        // Python 进程争抢 GPU。超分与 WebP 转换均在调度器内完成，此处直接返回，
        // 跳过下方的 WebP 转换。
        await MangaJaNaiBatchScheduler.instance.enqueue(inputPath);
        _notifyUpscaled(inputPath);
        return;
      } else {
        final mode = await RealSrSettings.loadDesktopNcnnMode();
        final noise = await RealSrSettings.loadDesktopNcnnNoise();
        final variant = DesktopNcnnModelConfig.variantFor(
          mode: mode,
          noise: noise,
        );
        final noiseLevel = RealSrNoiseLevel.values.firstWhere(
          (e) => e.value == variant.noise,
          orElse: () => RealSrNoiseLevel.conservative,
        );

        final upscaled = await upscale(
          inputPath: inputPath,
          outputPath: inputPath,
          executable: variant.displayName,
          modelDir: variant.modelDir,
          scale: variant.scale,
          noiseLevel: noiseLevel,
          tileSize: tileSize,
        );
        if (!upscaled) return;
      }
    } else {
      final noiseLevel = await RealSrSettings.loadNoiseLevel();
      final upscaled = await upscale(
        inputPath: inputPath,
        outputPath: inputPath,
        noiseLevel: noiseLevel,
        tileSize: tileSize,
      );
      if (!upscaled) return;
    }

    // 超分成功后输出的是 PNG，再转换为 WebP 以节省空间
    try {
      await convertImageToWebp(inputPath: inputPath, imageType: 'png');
    } catch (e, s) {
      logger.w('WebP 转换失败，保留超分后的原图: $inputPath', error: e, stackTrace: s);
    }

    _notifyUpscaled(inputPath);
  }

  /// 广播"图片超分完成"：路径不变、内容已覆盖为高清版。
  ///
  /// 显示层（ImageDisplay）收到后清除 ImageProvider 缓存并重新解码，
  /// 实现"先显示原图、超分完成后无感热替换"。
  static void _notifyUpscaled(String path) {
    eventBus.fire(ImageUpscaledEvent(path));
  }

  /// 远程 MangaJaNai 超分：把原图交给局域网内的 mjn-service，结果覆盖回原路径。
  ///
  /// 直接在**原路径**上覆盖（而非另存）是刻意的：与本地路径行为一致，
  /// 阅读器不需要知道超分发生过，覆盖后靠 [ImageUpscaledEvent] 热替换即可。
  ///
  /// 结果文件是 WebP，但覆盖到 `.jpg` 之类的原路径上不会出问题 ——
  /// Breeze 侧一律按文件头识别格式（[_detectUpscalableExtension]），不看扩展名。
  static Future<void> _upscaleRemote(String inputPath) async {
    final scale = await RealSrSettings.loadMangaJaNaiScale();
    final threshold = await RealSrSettings.loadMangaJaNaiGrayscaleThreshold();
    final cachePath = await getCachePath();
    final tempOutput = p.join(
      cachePath,
      'mjn_remote_${const Uuid().v4()}.webp',
    );

    try {
      await MangaJaNaiRemoteEngine.upscale(
        inputPath: inputPath,
        outputPath: tempOutput,
        scale: scale,
        grayscaleThreshold: threshold,
      );
      await _replaceFile(tempOutput, inputPath);
      _notifyUpscaled(inputPath);
    } finally {
      try {
        final temp = File(tempOutput);
        if (temp.existsSync()) {
          await temp.delete();
        }
      } catch (_) {}
    }
  }

  /// 走**本机常驻服务**超分（仅 Windows）。
  ///
  /// 与 [_upscaleRemote] 的唯一区别是地址来源：本机服务固定 `127.0.0.1`，不读用户
  /// 配置的远程地址，也不带远程 Token。请求格式与远程路径完全一致 —— 因为服务端
  /// 就是同一份 `mjn_service.py`，跑在 WSL 容器与 Windows 原生两种宿主上。
  ///
  /// 覆盖回**原路径**的语义与其它引擎一致：超分对阅读器不可见，靠
  /// [ImageUpscaledEvent] 触发热替换。
  static Future<void> _upscaleLocalService(String inputPath) async {
    final baseUrl = MjnLocalService.instance.baseUrl;
    if (baseUrl == null) {
      throw StateError('本机超分服务不可用');
    }

    final scale = await RealSrSettings.loadMangaJaNaiScale();
    final threshold = await RealSrSettings.loadMangaJaNaiGrayscaleThreshold();
    final cachePath = await getCachePath();
    final tempOutput = p.join(cachePath, 'mjn_local_${const Uuid().v4()}.webp');

    try {
      await MangaJaNaiRemoteEngine.upscale(
        inputPath: inputPath,
        outputPath: tempOutput,
        scale: scale,
        grayscaleThreshold: threshold,
        baseUrlOverride: baseUrl,
      );
      await _replaceFile(tempOutput, inputPath);
      _notifyUpscaled(inputPath);
    } finally {
      try {
        final temp = File(tempOutput);
        if (temp.existsSync()) {
          await temp.delete();
        }
      } catch (_) {}
    }
  }

  /// 把 [from] 覆盖到 [to]。
  ///
  /// Windows 上目标已存在时 rename 会失败，跨卷时同样失败，因此退回复制
  /// （`File.copy` 会覆盖已存在的目标）。
  static Future<void> _replaceFile(String from, String to) async {
    final src = File(from);
    try {
      await src.rename(to);
    } on FileSystemException {
      await src.copy(to);
      await src.delete();
    }
  }

  /// 对单张图片做超分放大。
  ///
  /// 返回是否实际执行了超分；图片格式不支持、模型不可用等跳过场景返回 false。
  ///
  /// 仅负责 NCNN / CoreML 路径；Windows 下的 MangaJaNai 引擎改由
  /// `MangaJaNaiBatchScheduler` 批量调度，不经过本方法。
  static Future<bool> upscale({
    required String inputPath,
    String? outputPath,
    String executable = 'realcugan-ncnn-vulkan',
    String modelDir = 'models-pro',
    int scale = 2,
    RealSrNoiseLevel noiseLevel = RealSrNoiseLevel.conservative,
    int tileSize = 0,
    int syncGapMode = 3,
  }) async {
    if (!await isAvailable) {
      logger.d('RealSR 不可用，跳过超分: $inputPath');
      return false;
    }

    final inputFile = File(inputPath);
    if (!inputFile.existsSync()) {
      throw ArgumentError.value(
        inputPath,
        'inputPath',
        'Input file does not exist',
      );
    }

    // 在占用超分并发池之前先判断格式，避免不支持的图片占着任务槽。
    final rawExt = await detectImageExtension(inputFile);
    final normalizedExt = rawExt.toLowerCase();
    if (!_supportedFormats.contains(normalizedExt)) {
      logger.w('RealSR 不支持的图片格式，跳过超分: $inputPath ($rawExt)');
      return false;
    }

    if (normalizedExt == '.webp' && await isAnimatedWebP(inputFile)) {
      logger.w('RealSR 不支持动图 WebP，跳过超分: $inputPath');
      return false;
    }

    // 并发设置只对 NCNN / CoreML 路径生效：MangaJaNai 由批量调度器串行控制，
    // 不经过本方法的并发池。放在这里而不是调用方，是为了让「谁用谁读」显式化，
    // 避免 MangaJaNai 路径白读一次配置并重建无用的池；同时避开被上面的格式检查
    // 提前跳过的图片（GIF / 动图 WebP 等）。
    final concurrency = await RealSrSettings.loadConcurrency();
    final targetConcurrency = concurrency == 0 ? 64 : concurrency;
    if (maxConcurrency != targetConcurrency) {
      maxConcurrency = targetConcurrency;
    }

    return _pool.withResource(() async {
      final startAt = DateTime.now();
      logger.d('Upscaling $inputPath to $outputPath');

      final out =
          outputPath ??
          p.join(
            p.dirname(inputPath),
            '${p.basenameWithoutExtension(inputPath)}_sr.png',
          );

      // 超分引擎统一按 PNG 输入处理，先转换到临时 PNG。
      String pngInputPath = inputPath;
      File? tempPngFile;
      if (normalizedExt != '.png') {
        final cacheDir = await getCachePath();
        pngInputPath = p.join(
          cacheDir,
          'realsr_input_${const Uuid().v4()}.png',
        );
        tempPngFile = File(pngInputPath);
        await convertImageToPng(inputPath: inputPath, outputPath: pngInputPath);
      }

      try {
        if (Platform.isAndroid) {
          final variant = AndroidNcnnModelConfig.variantFor(
            mode: AndroidNcnnModelConfig.defaultMode,
            noise: AndroidNcnnModelConfig.defaultNoise,
          );
          await _upscaleAndroidCli(
            inputPath: pngInputPath,
            outputPath: out,
            variant: variant,
            tileSize: tileSize,
          );
        } else if (Platform.isIOS || Platform.isMacOS) {
          await _upscaleCoreML(inputPath: pngInputPath, outputPath: out);
        } else {
          await _upscaleCli(
            inputPath: pngInputPath,
            outputPath: out,
            executable: executable,
            modelDir: modelDir,
            scale: scale,
            noiseLevel: noiseLevel,
            tileSize: tileSize,
            syncGapMode: syncGapMode,
          );
        }
      } finally {
        if (tempPngFile != null && tempPngFile.existsSync()) {
          await tempPngFile.delete();
        }
      }

      final endAt = DateTime.now();
      final duration = endAt.difference(startAt).inMilliseconds;
      logger.d('Upscaling took ${duration}ms');
      return true;
    });
  }

  /// Android 通过 bundled waifu2x CLI 超分。
  static Future<void> _upscaleAndroidCli({
    required String inputPath,
    required String outputPath,
    required NcnnModelVariant variant,
    required int tileSize,
  }) async {
    final exePath = await _prepareAndroidCli();
    final modelRoot = await _modelDirectory;
    final modelPath = p.join(modelRoot, variant.modelDir);

    final result = await Process.run(
      exePath,
      [
        '-i',
        inputPath,
        '-o',
        outputPath,
        '-s',
        variant.scale.toString(),
        '-n',
        variant.noise.toString(),
        '-m',
        modelPath,
        '-g',
        '0',
        '-t',
        tileSize.toString(),
      ],
      runInShell: false,
      workingDirectory: modelRoot,
    );

    if (result.exitCode != 0) {
      throw StateError(
        'waifu2x CLI 失败 (exitCode=${result.exitCode})\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }
  }

  static String? _androidCliPath;

  /// 获取 APK 中 bundled 的 waifu2x CLI 路径（位于 nativeLibraryDir）。
  static Future<String> _prepareAndroidCli() async {
    if (_androidCliPath != null) return _androidCliPath!;

    final path = await _channel.invokeMethod<String>('getWaifu2xCliPath');
    if (path == null || path.isEmpty) {
      throw StateError('getWaifu2xCliPath returned empty path');
    }
    _androidCliPath = path;
    return path;
  }

  /// iOS / macOS 通过 CoreML 插件超分。
  static Future<void> _upscaleCoreML({
    required String inputPath,
    required String outputPath,
  }) async {
    final family = await RealSrSettings.loadCoreMLFamily();
    final variant = await RealSrSettings.loadCoreMLVariant(family);
    final modelPath = await CoreMLModelLoader.prepareModel(variant.fileName);

    await CoreMLUpscale.upscale(
      inputPath: inputPath,
      outputPath: outputPath,
      modelPath: modelPath,
      modelType: 'multiarray',
      config: variant.config,
    );
  }

  /// 桌面端通过 Process.run 调用 waifu2x-ncnn-vulkan / realcugan-ncnn-vulkan。
  static Future<void> _upscaleCli({
    required String inputPath,
    required String outputPath,
    required String executable,
    required String modelDir,
    required int scale,
    required RealSrNoiseLevel noiseLevel,
    required int tileSize,
    required int syncGapMode,
  }) async {
    final modelRoot = await _modelDirectory;
    final exe = p.join(modelRoot, executable);
    final isWaifu2x = executable.toLowerCase().contains('waifu2x');
    final cachePath = await getCachePath();
    final workDir = Directory(
      p.normalize(p.join(cachePath, 'realsr-upscale', const Uuid().v4())),
    );

    try {
      await workDir.create(recursive: true);

      // CLI 根据后缀判断输入格式，用真实扩展名避免格式错配导致花图。
      final rawExt = await detectImageExtension(File(inputPath));
      final inputExt = rawExt.startsWith('.') ? rawExt.substring(1) : rawExt;
      final tempInput = p.join(
        workDir.path,
        'input.${inputExt.isEmpty ? 'png' : inputExt}',
      );
      final tempOutput = p.join(workDir.path, 'output.png');
      await File(inputPath).copy(tempInput);

      final modelPath = p.join(modelRoot, modelDir);
      final args = [
        '-i',
        tempInput,
        '-o',
        tempOutput,
        '-s',
        scale.toString(),
        '-n',
        noiseLevel.value.toString(),
        '-m',
        modelPath,
        '-g',
        '0',
        '-t',
        tileSize.toString(),
        if (!isWaifu2x) ...['-c', syncGapMode.toString()],
      ];
      final result = await Process.run(
        exe,
        args,
        runInShell: false,
        workingDirectory: modelRoot,
      );

      if (result.exitCode != 0) {
        throw StateError(
          '${isWaifu2x ? 'waifu2x' : 'Real-CUGAN'} CLI 失败 '
          '(exitCode=${result.exitCode})\n'
          'stdout: ${result.stdout}\n'
          'stderr: ${result.stderr}',
        );
      }

      await File(tempOutput).copy(outputPath);
    } finally {
      if (workDir.existsSync()) {
        workDir.deleteSync(recursive: true);
      }
    }
  }
}

class RealSrUpscaleResult {
  final bool success;
  final int exitCode;
  final String outputPath;
  final String stdout;
  final String stderr;

  const RealSrUpscaleResult({
    required this.success,
    required this.exitCode,
    required this.outputPath,
    required this.stdout,
    required this.stderr,
  });

  /// 如果成功，返回输出文件；否则抛出异常并附带 stderr。
  File get outputFile {
    if (!success) {
      throw StateError(
        'RealSR upscale failed (exitCode=$exitCode)\nstdout: $stdout\nstderr: $stderr',
      );
    }
    return File(outputPath);
  }

  @override
  String toString() {
    return 'RealSrUpscaleResult(success=$success, exitCode=$exitCode, outputPath=$outputPath)';
  }
}

/// 检测 WebP 文件是否为动图
/// 返回 true 表示是动图，false 表示静态图或读取失败
Future<bool> isAnimatedWebP(File file) async {
  try {
    // 只需要读取前 20 个字节就够了（实际只需 16 个，读 20 以防万一）
    final bytes = await file.openRead(0, 20).first;

    // 长度不足则判定为非动图
    if (bytes.length < 16) return false;

    // 校验头部是否为 RIFF...WEBP (0x52= R, 0x49=I, 0x46=F)
    // 偏移 0-3: RIFF, 偏移 8-11: WEBP
    if (bytes[0] != 0x52 ||
        bytes[1] != 0x49 ||
        bytes[2] != 0x46 ||
        bytes[3] != 0x46) {
      return false;
    }
    if (bytes[8] != 0x57 ||
        bytes[9] != 0x45 ||
        bytes[10] != 0x42 ||
        bytes[11] != 0x50) {
      return false;
    }

    // 关键判断：偏移 12-15 必须是 'ANIM' (0x41=A, 0x4E=N, 0x49=I, 0x4D=M)
    // 只要是 ANIM，就说明包含动画控制块，必然是动图
    return bytes[12] == 0x41 &&
        bytes[13] == 0x4E &&
        bytes[14] == 0x49 &&
        bytes[15] == 0x4D;
  } catch (_) {
    return true;
  }
}

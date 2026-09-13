import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/page/setting/real_sr/service/android_ncnn_model_config.dart';
import 'package:zephyr/util/coreml_model_config.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// RealSR / Real-CUGAN 超分设置
///
/// 这些配置不进入 ObjectBox 的 [GlobalSettingState]，而是直接存在
/// SharedPreferences 中，避免把“功能开关”和“全局配置”混在一起。
class RealSrSettings {
  RealSrSettings._();

  static const _keyAutoUpscale = 'realsr_auto_upscale';
  static const _keyResolutionThreshold = 'realsr_resolution_threshold';
  static const _keyConcurrency = 'realsr_concurrency';
  static const _keyNoiseLevel = 'realsr_noise_level';
  static const _keyTileSize = 'realsr_tile_size';
  static const _keyCoreMLFamily = 'realsr_coreml_family';
  static const _keyCoreMLVariant = 'realsr_coreml_variant';
  static const _keyAndroidNcnnMode = 'realsr_android_ncnn_mode';
  static const _keyAndroidNcnnNoise = 'realsr_android_ncnn_noise';
  static const _keyDesktopNcnnMode = 'realsr_desktop_ncnn_mode';
  static const _keyDesktopNcnnNoise = 'realsr_desktop_ncnn_noise';
  static const _keyDesktopEngine = 'realsr_desktop_engine';
  static const _keyMangaJaNaiScale = 'realsr_mangajanai_scale';
  static const _keyMangaJaNaiGrayscaleThreshold =
      'realsr_mangajanai_grayscale_threshold';
  static const _keyMangaJaNaiPythonPath = 'realsr_mangajanai_python_path';
  static const _keyMangaJaNaiBackendSrcDir =
      'realsr_mangajanai_backend_src_dir';
  static const _keyMangaJaNaiModelsDir = 'realsr_mangajanai_models_dir';

  /// 默认并发数：**全平台固定 1（单线程）**。
  ///
  /// 依据：MangaJaNai 后端单进程最快——多个独立进程各持 CUDA context，在消费级卡上
  /// 会互相争抢（context 切换、显存带宽、L2 局部性），176 张实测并行反而慢 20%。
  /// NCNN / CoreML 沿用同一策略以保持行为一致，同时避免后台超分与前台应用争抢
  /// 显存和 GPU。需要时用户可在设置页手动调高。
  static int get defaultConcurrency => 1;

  static Future<bool> loadAutoUpscale() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoUpscale) ?? false;
  }

  static Future<void> saveAutoUpscale(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoUpscale, value);
  }

  static Future<RealSrResolutionThreshold> loadResolutionThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyResolutionThreshold);
    final value = RealSrResolutionThreshold.values.firstWhere(
      (e) => e.name == name,
      orElse: () => RealSrResolutionThreshold.p720,
    );

    // 桌面端最高 2160p，移动设备最高 1080p
    const desktopMax = RealSrResolutionThreshold.p2160;
    const mobileMax = RealSrResolutionThreshold.p1080;
    final max = _isDesktop ? desktopMax : mobileMax;
    if (value.maxWidth > max.maxWidth) {
      return max;
    }

    return value;
  }

  static Future<void> saveResolutionThreshold(
    RealSrResolutionThreshold value,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyResolutionThreshold, value.name);
  }

  static Future<int> loadConcurrency() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyConcurrency) ?? defaultConcurrency;
  }

  static Future<void> saveConcurrency(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyConcurrency, value);
  }

  static Future<int> loadTileSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyTileSize) ?? 256;
  }

  static Future<void> saveTileSize(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyTileSize, value);
  }

  static Future<RealSrNoiseLevel> loadNoiseLevel() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyNoiseLevel);
    return RealSrNoiseLevel.values.firstWhere(
      (e) => e.name == name,
      orElse: () => RealSrNoiseLevel.conservative,
    );
  }

  static Future<void> saveNoiseLevel(RealSrNoiseLevel value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyNoiseLevel, value.name);
  }

  /// iOS / macOS 使用的 CoreML 模型族，默认 waifu2x（速度优先）。
  static Future<CoreMLModelFamily> loadCoreMLFamily() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_keyCoreMLFamily);
    return CoreMLModelConfig.familyById(id ?? '') ??
        CoreMLModelConfig.defaultFamily;
  }

  static Future<void> saveCoreMLFamily(CoreMLModelFamily value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCoreMLFamily, value.id);
  }

  /// iOS / macOS 使用的 CoreML 模型变体。
  ///
  /// 如果保存的变体不在当前族中，自动回退到该族第一个变体。
  static Future<CoreMLModelVariant> loadCoreMLVariant(
    CoreMLModelFamily family,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final fileName = prefs.getString(_keyCoreMLVariant);
    return CoreMLModelConfig.variantByFileName(family, fileName ?? '') ??
        family.variants.first;
  }

  static Future<void> saveCoreMLVariant(CoreMLModelVariant value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCoreMLVariant, value.fileName);
  }

  /// Android 使用的 NCNN 超分模式，默认效率优先（waifu2x）。
  static Future<AndroidNcnnMode> loadAndroidNcnnMode() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyAndroidNcnnMode);
    return AndroidNcnnMode.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AndroidNcnnModelConfig.defaultMode,
    );
  }

  static Future<void> saveAndroidNcnnMode(AndroidNcnnMode value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAndroidNcnnMode, value.name);
  }

  /// Android 使用的 NCNN 降噪档位，默认无降噪（适合漫画）。
  static Future<AndroidNcnnNoise> loadAndroidNcnnNoise() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyAndroidNcnnNoise);
    return AndroidNcnnNoise.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AndroidNcnnModelConfig.defaultNoise,
    );
  }

  static Future<void> saveAndroidNcnnNoise(AndroidNcnnNoise value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAndroidNcnnNoise, value.name);
  }

  /// 桌面端（Windows / Linux）使用的 NCNN 超分模式。
  static Future<AndroidNcnnMode> loadDesktopNcnnMode() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyDesktopNcnnMode);
    return AndroidNcnnMode.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AndroidNcnnModelConfig.defaultMode,
    );
  }

  static Future<void> saveDesktopNcnnMode(AndroidNcnnMode value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDesktopNcnnMode, value.name);
  }

  /// 桌面端（Windows / Linux）使用的 NCNN 降噪档位。
  static Future<AndroidNcnnNoise> loadDesktopNcnnNoise() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyDesktopNcnnNoise);
    return AndroidNcnnNoise.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AndroidNcnnModelConfig.defaultNoise,
    );
  }

  static Future<void> saveDesktopNcnnNoise(AndroidNcnnNoise value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDesktopNcnnNoise, value.name);
  }

  /// 桌面端（Windows）使用的超分引擎，默认内置 NCNN。
  static Future<DesktopSrEngine> loadDesktopEngine() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyDesktopEngine);
    return DesktopSrEngine.values.firstWhere(
      (e) => e.name == name,
      orElse: () => DesktopSrEngine.ncnn,
    );
  }

  static Future<void> saveDesktopEngine(DesktopSrEngine value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDesktopEngine, value.name);
  }

  /// MangaJaNai 引擎的目标放大倍率，仅支持 2x / 4x，默认 2x。
  static Future<int> loadMangaJaNaiScale() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyMangaJaNaiScale) == 4 ? 4 : 2;
  }

  static Future<void> saveMangaJaNaiScale(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMangaJaNaiScale, value == 4 ? 4 : 2);
  }

  /// MangaJaNai 引擎的灰度判定阈值，与 GUI 的同名设置一致，默认 12。
  ///
  /// 黑白页被误判为彩色进入彩色链时，调高该值。
  static Future<int> loadMangaJaNaiGrayscaleThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_keyMangaJaNaiGrayscaleThreshold);
    return (value == null || value <= 0) ? 12 : value;
  }

  static Future<void> saveMangaJaNaiGrayscaleThreshold(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMangaJaNaiGrayscaleThreshold, value);
  }

  /// MangaJaNai CLI 后端路径覆写，空字符串表示使用默认安装路径。
  static Future<String> loadMangaJaNaiPythonPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyMangaJaNaiPythonPath) ?? '';
  }

  static Future<void> saveMangaJaNaiPythonPath(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMangaJaNaiPythonPath, value.trim());
  }

  static Future<String> loadMangaJaNaiBackendSrcDir() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyMangaJaNaiBackendSrcDir) ?? '';
  }

  static Future<void> saveMangaJaNaiBackendSrcDir(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMangaJaNaiBackendSrcDir, value.trim());
  }

  static Future<String> loadMangaJaNaiModelsDir() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyMangaJaNaiModelsDir) ?? '';
  }

  static Future<void> saveMangaJaNaiModelsDir(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMangaJaNaiModelsDir, value.trim());
  }
}

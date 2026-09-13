import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/common/setting_ui.dart';
import 'package:zephyr/page/setting/real_sr/service/android_ncnn_model_config.dart';
import 'package:zephyr/page/setting/real_sr/service/desktop_ncnn_model_config.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_bootstrap.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_engine.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_super_resolution.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/util/coreml_model_config.dart';
import 'package:zephyr/widgets/fluent_dropdown.dart';
import 'package:zephyr/widgets/toast.dart';

final Map<int, String> _concurrencyLabels = {
  1: '1',
  2: '2',
  4: '4',
  6: '6',
  8: '8',
  0: t.realSr.unlimited,
};

const Map<int, String> _tileSizeLabels = {
  0: '0',
  128: '128',
  256: '256',
  512: '512',
  1024: '1024',
};

final List<int> _concurrencyOptions = _concurrencyLabels.keys.toList()..sort();
final List<int> _tileSizeOptions = _tileSizeLabels.keys.toList()..sort();

/// MangaJaNai 放大倍率可选项。
const Map<int, String> _mangaJaNaiScaleLabels = {2: '2x', 4: '4x'};

/// MangaJaNai 灰度判定阈值可选项（与 GUI 同名设置，默认 12）。
const Map<int, String> _mangaJaNaiThresholdLabels = {
  4: '4',
  8: '8',
  12: '12',
  24: '24',
  48: '48',
};

@RoutePage()
class RealSrSettingPage extends StatefulWidget {
  const RealSrSettingPage({super.key});

  @override
  State<RealSrSettingPage> createState() => _RealSrSettingPageState();
}

class _RealSrSettingPageState extends State<RealSrSettingPage> {
  bool _loading = true;
  bool _autoUpscale = false;
  RealSrResolutionThreshold _resolutionThreshold =
      RealSrResolutionThreshold.p720;
  int _concurrency = 1;
  int _tileSize = 0;
  AndroidNcnnMode _desktopNcnnMode = DesktopNcnnModelConfig.defaultMode;
  AndroidNcnnNoise _desktopNcnnNoise = DesktopNcnnModelConfig.defaultNoise;
  DesktopSrEngine _desktopEngine = DesktopSrEngine.ncnn;
  int _mangaJaNaiScale = 2;
  int _mangaJaNaiGrayscaleThreshold = 12;
  String _mangaJaNaiPythonPath = '';
  String _mangaJaNaiBackendSrcDir = '';
  String _mangaJaNaiModelsDir = '';
  List<String> _mangaJaNaiMissing = const [];
  bool _installingEngine = false;
  String? _installStatusText;
  CoreMLModelFamily _coreMLFamily = CoreMLModelConfig.defaultFamily;
  CoreMLModelVariant _coreMLVariant = CoreMLModelConfig.defaultVariant;
  bool _isAvailable = false;
  bool _downloading = false;
  bool _importing = false;
  double _downloadProgress = 0;

  bool get _usesCoreML => Platform.isIOS || Platform.isMacOS;

  /// Windows 下是否选择了本地 MangaJaNai 引擎。
  bool get _useMangaJaNaiEngine =>
      Platform.isWindows && _desktopEngine == DesktopSrEngine.mangaJaNai;

  List<RealSrResolutionThreshold> get _availableThresholds {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return RealSrResolutionThreshold.values;
    }
    return const [
      RealSrResolutionThreshold.p540,
      RealSrResolutionThreshold.p720,
      RealSrResolutionThreshold.p1080,
    ];
  }

  RealSrResolutionThreshold get _effectiveThreshold {
    if (_availableThresholds.contains(_resolutionThreshold)) {
      return _resolutionThreshold;
    }
    return RealSrResolutionThreshold.p1080;
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final family = await RealSrSettings.loadCoreMLFamily();
    final variant = await RealSrSettings.loadCoreMLVariant(family);
    final desktopEngine = await RealSrSettings.loadDesktopEngine();
    final mangaJaNaiScale = await RealSrSettings.loadMangaJaNaiScale();
    final mangaJaNaiThreshold =
        await RealSrSettings.loadMangaJaNaiGrayscaleThreshold();
    final mangaJaNaiPythonPath =
        await RealSrSettings.loadMangaJaNaiPythonPath();
    final mangaJaNaiBackendSrcDir =
        await RealSrSettings.loadMangaJaNaiBackendSrcDir();
    final mangaJaNaiModelsDir = await RealSrSettings.loadMangaJaNaiModelsDir();
    final results = await Future.wait([
      RealSrSettings.loadAutoUpscale(),
      RealSrSettings.loadResolutionThreshold(),
      RealSrSettings.loadConcurrency(),
      RealSrSettings.loadTileSize(),
      RealSrSettings.loadDesktopNcnnMode(),
      RealSrSettings.loadDesktopNcnnNoise(),
      RealSrSuperResolution.isAvailable,
    ]);

    if (!mounted) return;
    setState(() {
      _autoUpscale = results[0] as bool;
      _resolutionThreshold = results[1] as RealSrResolutionThreshold;
      _concurrency = results[2] as int;
      _tileSize = results[3] as int;
      _desktopNcnnMode = results[4] as AndroidNcnnMode;
      _desktopNcnnNoise = results[5] as AndroidNcnnNoise;
      _isAvailable = results[6] as bool;
      _desktopEngine = desktopEngine;
      _mangaJaNaiScale = mangaJaNaiScale;
      _mangaJaNaiGrayscaleThreshold = mangaJaNaiThreshold;
      _mangaJaNaiPythonPath = mangaJaNaiPythonPath;
      _mangaJaNaiBackendSrcDir = mangaJaNaiBackendSrcDir;
      _mangaJaNaiModelsDir = mangaJaNaiModelsDir;
      _coreMLFamily = family;
      _coreMLVariant = variant;
      _loading = false;
    });

    if (_useMangaJaNaiEngine) {
      await _refreshMangaJaNaiStatus();
    }
  }

  Future<void> _setAutoUpscale(bool value) async {
    await RealSrSettings.saveAutoUpscale(value);
    setState(() => _autoUpscale = value);
  }

  Future<void> _setResolutionThreshold(RealSrResolutionThreshold value) async {
    await RealSrSettings.saveResolutionThreshold(value);
    setState(() => _resolutionThreshold = value);
  }

  Future<void> _setConcurrency(int value) async {
    await RealSrSettings.saveConcurrency(value);
    setState(() => _concurrency = value);
  }

  Future<void> _setTileSize(int value) async {
    await RealSrSettings.saveTileSize(value);
    setState(() => _tileSize = value);
  }

  Future<void> _setDesktopNcnnMode(AndroidNcnnMode value) async {
    await RealSrSettings.saveDesktopNcnnMode(value);
    setState(() => _desktopNcnnMode = value);
  }

  Future<void> _setDesktopNcnnNoise(AndroidNcnnNoise value) async {
    await RealSrSettings.saveDesktopNcnnNoise(value);
    setState(() => _desktopNcnnNoise = value);
  }

  Future<void> _setDesktopEngine(DesktopSrEngine value) async {
    await RealSrSettings.saveDesktopEngine(value);
    setState(() => _desktopEngine = value);
    await _refreshAvailability();
    if (_useMangaJaNaiEngine) {
      await _refreshMangaJaNaiStatus();
    }
  }

  Future<void> _setMangaJaNaiScale(int value) async {
    await RealSrSettings.saveMangaJaNaiScale(value);
    setState(() => _mangaJaNaiScale = value);
  }

  Future<void> _setMangaJaNaiGrayscaleThreshold(int value) async {
    await RealSrSettings.saveMangaJaNaiGrayscaleThreshold(value);
    setState(() => _mangaJaNaiGrayscaleThreshold = value);
  }

  Future<void> _refreshMangaJaNaiStatus() async {
    final missing = await MangaJaNaiEngine.missingRequirements();
    if (mounted) setState(() => _mangaJaNaiMissing = missing);
  }

  /// 从官方源在线安装 MangaJaNai 引擎（无需 GUI）。
  Future<void> _installEngineOnline() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.realSr.mangaJaNaiOnlineInstall),
        content: Text(t.realSr.mangaJaNaiOnlineInstallConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.realSr.mangaJaNaiOnlineInstallAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _installingEngine = true;
      _installStatusText = null;
    });
    try {
      await MangaJaNaiBootstrap.install(
        onProgress: (stage, {received, total, detail}) {
          if (!mounted) return;
          final base = switch (stage) {
            MangaJaNaiInstallStage.python =>
              t.realSr.mangaJaNaiInstallStagePython,
            MangaJaNaiInstallStage.deps => t.realSr.mangaJaNaiInstallStageDeps,
            MangaJaNaiInstallStage.torch =>
              t.realSr.mangaJaNaiInstallStageTorch,
            MangaJaNaiInstallStage.backend =>
              t.realSr.mangaJaNaiInstallStageBackend,
            MangaJaNaiInstallStage.models =>
              t.realSr.mangaJaNaiInstallStageModels,
          };
          final progress = received != null && total != null && total > 0
              ? ' ${(received / 1024 / 1024).toStringAsFixed(0)}/'
                    '${(total / 1024 / 1024).toStringAsFixed(0)} MB'
              : '';
          setState(() {
            _installStatusText = detail == null
                ? '$base$progress'
                : '$base$progress\n$detail';
          });
        },
      );
      if (!mounted) return;
      showSuccessToast(t.realSr.mangaJaNaiInstallDone);
    } catch (e, s) {
      logger.e('MangaJaNai 在线安装失败', error: e, stackTrace: s);
      if (mounted) {
        showErrorToast('${t.realSr.mangaJaNaiInstallFailed}: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _installingEngine = false;
          _installStatusText = null;
        });
      }
      await _loadSettings();
    }
  }

  Future<void> _refreshAvailability() async {
    final available = await RealSrSuperResolution.isAvailable;
    if (mounted) setState(() => _isAvailable = available);
  }

  /// 弹窗编辑 MangaJaNai CLI 后端的三个路径，留空回退默认安装位置。
  Future<void> _editMangaJaNaiPaths() async {
    final pythonCtrl = TextEditingController(text: _mangaJaNaiPythonPath);
    final backendCtrl = TextEditingController(text: _mangaJaNaiBackendSrcDir);
    final modelsCtrl = TextEditingController(text: _mangaJaNaiModelsDir);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.realSr.mangaJaNaiPaths),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pythonCtrl,
                decoration: InputDecoration(
                  labelText: t.realSr.mangaJaNaiPathPython,
                  hintText: MangaJaNaiEngine.defaultPythonPath,
                ),
              ),
              TextField(
                controller: backendCtrl,
                decoration: InputDecoration(
                  labelText: t.realSr.mangaJaNaiPathBackend,
                  hintText: MangaJaNaiEngine.defaultBackendSrcDir,
                ),
              ),
              TextField(
                controller: modelsCtrl,
                decoration: InputDecoration(
                  labelText: t.realSr.mangaJaNaiPathModels,
                  hintText: MangaJaNaiEngine.defaultModelsDir,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.common.save),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;

    await Future.wait([
      RealSrSettings.saveMangaJaNaiPythonPath(pythonCtrl.text),
      RealSrSettings.saveMangaJaNaiBackendSrcDir(backendCtrl.text),
      RealSrSettings.saveMangaJaNaiModelsDir(modelsCtrl.text),
    ]);
    setState(() {
      _mangaJaNaiPythonPath = pythonCtrl.text.trim();
      _mangaJaNaiBackendSrcDir = backendCtrl.text.trim();
      _mangaJaNaiModelsDir = modelsCtrl.text.trim();
    });
    await _refreshMangaJaNaiStatus();
    await _refreshAvailability();
  }

  Future<void> _setCoreMLFamily(CoreMLModelFamily value) async {
    final newVariant = value.variants.first;
    await Future.wait([
      RealSrSettings.saveCoreMLFamily(value),
      RealSrSettings.saveCoreMLVariant(newVariant),
    ]);
    setState(() {
      _coreMLFamily = value;
      _coreMLVariant = newVariant;
    });
  }

  Future<void> _setCoreMLVariant(CoreMLModelVariant value) async {
    await RealSrSettings.saveCoreMLVariant(value);
    setState(() => _coreMLVariant = value);
  }

  Future<void> _downloadModel() async {
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });

    try {
      await RealSrSuperResolution.downloadModel(
        force: _isAvailable,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _downloadProgress = received / total);
        },
      );
    } catch (e, s) {
      logger.e('模型下载失败', error: e, stackTrace: s);
      showErrorToast('${t.realSr.modelDownloadFailed}: $e');
    } finally {
      if (mounted) {
        setState(() => _downloading = false);
        await _refreshAvailability();
      }
    }
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.realSr.deleteModel),
        content: Text(t.realSr.deleteModelConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.common.delete),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await RealSrSuperResolution.deleteModel();
      showSuccessToast(t.realSr.modelDeleted);
    } catch (e, s) {
      logger.e('模型删除失败', error: e, stackTrace: s);
      showErrorToast('${t.realSr.modelDeleteFailed}: $e');
    } finally {
      if (mounted) await _refreshAvailability();
    }
  }

  Future<void> _openManualDownloadUrl() async {
    final url = RealSrSuperResolution.manualDownloadUrl;
    if (url == null) {
      showErrorToast(t.realSr.manualDownloadUnsupported);
      return;
    }
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      showErrorToast(t.realSr.openDownloadUrlFailed);
    }
  }

  Future<void> _importModel() async {
    // iOS 没有系统声明的 7z UTI，使用通用数据类型后由导入逻辑校验 7z 魔数。
    final typeGroup = Platform.isIOS
        ? const XTypeGroup(label: '7z')
        : const XTypeGroup(label: '7z', extensions: ['7z']);
    final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: [typeGroup]);
    } catch (e) {
      showErrorToast('${t.realSr.modelImportFailed}: $e');
      return;
    }
    if (file == null) return;

    setState(() => _importing = true);
    try {
      await RealSrSuperResolution.importModelArchive(file.path);
      if (mounted) showSuccessToast(t.realSr.modelImportSuccess);
    } catch (e, s) {
      logger.e('模型导入失败', error: e, stackTrace: s);
      if (mounted) {
        showErrorToast('${t.realSr.modelImportFailed}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
        await _refreshAvailability();
      }
    }
  }

  String get _coreMLBlockInfo {
    final blockSize = _coreMLVariant.config['blockSize'] as int? ?? 0;
    final shrinkSize = _coreMLVariant.config['shrinkSize'] as int? ?? 0;
    final contentSize = CoreMLModelConfig.contentBlockSize(_coreMLVariant);
    return t.realSr.blockInfoFormat(
      contentSize: contentSize,
      blockSize: blockSize,
      shrinkSize: shrinkSize,
    );
  }

  List<Widget> _buildModelItems() {
    if (_usesCoreML) {
      return [
        ListTile(
          leading: const Icon(Icons.speed_outlined),
          title: Text(t.realSr.model),
          subtitle: Text(t.realSr.modelSubtitle),
          trailing: FluentDropdown<CoreMLModelFamily>(
            value: _coreMLFamily,
            displayValue: _coreMLFamily.localizedLabel,
            items: {
              for (final family in CoreMLModelConfig.families)
                family: family.localizedLabel,
            },
            onChanged: _setCoreMLFamily,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.healing_outlined),
          title: Text(t.realSr.noiseLevel),
          subtitle: Text(t.realSr.noiseLevelSubtitle),
          trailing: FluentDropdown<CoreMLModelVariant>(
            value: _coreMLVariant,
            displayValue: _coreMLVariant.localizedDisplayName,
            items: {
              for (final variant in _coreMLFamily.variants)
                variant: variant.localizedDisplayName,
            },
            onChanged: _setCoreMLVariant,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.grid_view_outlined),
          title: Text(t.realSr.blockInfo),
          subtitle: Text(_coreMLBlockInfo),
          trailing: Tooltip(
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 5),
            message: t.realSr.blockInfoTooltip,
            child: const Icon(Icons.help_outline),
          ),
        ),
      ];
    }

    if (Platform.isAndroid) {
      return [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(t.realSr.androidSuperResolution),
          subtitle: Text(t.realSr.androidSuperResolutionSubtitle),
        ),
      ];
    }

    // Windows / Linux
    final items = <Widget>[];

    // Linux 无本地 MangaJaNai GUI 安装约定，仅 Windows 提供引擎切换。
    if (Platform.isWindows) {
      items.add(
        ListTile(
          leading: const Icon(Icons.memory_outlined),
          title: Text(t.realSr.engine),
          subtitle: Text(t.realSr.engineSubtitle),
          trailing: FluentDropdown<DesktopSrEngine>(
            value: _desktopEngine,
            displayValue: _desktopEngine.label,
            items: {
              for (final engine in DesktopSrEngine.values) engine: engine.label,
            },
            onChanged: _setDesktopEngine,
          ),
        ),
      );
    }

    if (_useMangaJaNaiEngine) {
      final effectiveScale =
          _mangaJaNaiScaleLabels.containsKey(_mangaJaNaiScale)
          ? _mangaJaNaiScale
          : 2;
      final effectiveThreshold =
          _mangaJaNaiThresholdLabels.containsKey(_mangaJaNaiGrayscaleThreshold)
          ? _mangaJaNaiGrayscaleThreshold
          : 12;
      final pathsCustomized =
          _mangaJaNaiPythonPath.isNotEmpty ||
          _mangaJaNaiBackendSrcDir.isNotEmpty ||
          _mangaJaNaiModelsDir.isNotEmpty;
      items.addAll([
        ListTile(
          leading: const Icon(Icons.open_in_full_outlined),
          title: Text(t.realSr.mangaJaNaiScale),
          subtitle: Text(t.realSr.mangaJaNaiScaleSubtitle),
          trailing: FluentDropdown<int>(
            value: effectiveScale,
            displayValue: _mangaJaNaiScaleLabels[effectiveScale]!,
            items: {
              for (final entry in _mangaJaNaiScaleLabels.entries)
                entry.key: entry.value,
            },
            onChanged: (value) => _setMangaJaNaiScale(value),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.filter_b_and_w_outlined),
          title: Text(t.realSr.mangaJaNaiThreshold),
          subtitle: Text(t.realSr.mangaJaNaiThresholdSubtitle),
          trailing: FluentDropdown<int>(
            value: effectiveThreshold,
            displayValue: _mangaJaNaiThresholdLabels[effectiveThreshold]!,
            items: {
              for (final entry in _mangaJaNaiThresholdLabels.entries)
                entry.key: entry.value,
            },
            onChanged: (value) => _setMangaJaNaiGrayscaleThreshold(value),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: Text(
            pathsCustomized
                ? t.realSr.mangaJaNaiPathsCustom
                : t.realSr.mangaJaNaiPaths,
          ),
          subtitle: Text(t.realSr.mangaJaNaiPathsSubtitle),
          trailing: TextButton(
            onPressed: _editMangaJaNaiPaths,
            child: Text(t.realSr.importModelAction),
          ),
        ),
        _buildMangaJaNaiStatusTile(),
        if (_mangaJaNaiMissing.isNotEmpty)
          ListTile(
            leading: Icon(
              _installingEngine
                  ? Icons.downloading_outlined
                  : Icons.cloud_download_outlined,
            ),
            title: Text(t.realSr.mangaJaNaiOnlineInstall),
            subtitle: Text(
              _installStatusText ?? t.realSr.mangaJaNaiOnlineInstallSubtitle,
            ),
            trailing: _installingEngine
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: _installEngineOnline,
                    child: Text(t.realSr.mangaJaNaiOnlineInstallAction),
                  ),
          ),
        // NVIDIA 的「CUDA - 系统内存回退策略」若保持默认，显存不足时会回退到
        // 系统内存，超分速度差一个数量级。这是驱动侧设置，应用无法代劳，只能提示。
        ListTile(
          leading: const Icon(Icons.memory_outlined),
          title: Text(t.realSr.mangaJaNaiNvidiaTitle),
          subtitle: Text(t.realSr.mangaJaNaiNvidiaSubtitle),
        ),
      ]);
    } else {
      items.addAll([
        ListTile(
          leading: const Icon(Icons.speed_outlined),
          title: Text(t.realSr.desktopStrategy),
          subtitle: Text(t.realSr.desktopStrategySubtitle),
          trailing: FluentDropdown<AndroidNcnnMode>(
            value: _desktopNcnnMode,
            displayValue: _desktopNcnnMode.label,
            items: {
              for (final mode in AndroidNcnnMode.values) mode: mode.label,
            },
            onChanged: _setDesktopNcnnMode,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.healing_outlined),
          title: Text(t.realSr.desktopNoiseLevel),
          subtitle: Text(t.realSr.desktopNoiseLevelSubtitle),
          trailing: FluentDropdown<AndroidNcnnNoise>(
            value: _desktopNcnnNoise,
            displayValue: _desktopNcnnNoise.label,
            items: {
              for (final noise in AndroidNcnnNoise.values) noise: noise.label,
            },
            onChanged: _setDesktopNcnnNoise,
          ),
        ),
      ]);
    }

    return items;
  }

  /// MangaJaNai CLI 后端就绪状态瓦片。
  Widget _buildMangaJaNaiStatusTile() {
    if (_mangaJaNaiMissing.isEmpty) {
      return ListTile(
        leading: Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(t.realSr.mangaJaNaiReady),
      );
    }

    return ListTile(
      leading: const Icon(Icons.warning_amber_rounded),
      title: Text(t.realSr.mangaJaNaiNotReady),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.realSr.mangaJaNaiMissingHint),
          const SizedBox(height: 4),
          Text(
            _mangaJaNaiMissing.take(6).join('\n'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildModelManagementTile() {
    if (_downloading) {
      return ListTile(
        leading: const Icon(Icons.downloading_outlined),
        title: Text(t.realSr.downloadingModel),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _downloadProgress),
            const SizedBox(height: 4),
            Text('${(_downloadProgress * 100).toStringAsFixed(1)}%'),
          ],
        ),
      );
    }

    if (_isAvailable) {
      return ListTile(
        leading: Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(t.realSr.modelReady),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _deleteModel,
              child: Text(t.realSr.deleteModel),
            ),
            TextButton(
              onPressed: _downloadModel,
              child: Text(t.realSr.redownload),
            ),
          ],
        ),
      );
    }

    return ListTile(
      leading: const Icon(Icons.warning_amber_rounded),
      title: Text(t.realSr.modelNotDownloaded),
      subtitle: Text(t.realSr.modelNotDownloadedSubtitle),
      trailing: ElevatedButton(
        onPressed: _downloadModel,
        child: Text(t.realSr.downloadModel),
      ),
    );
  }

  Widget _buildManualDownloadTile() {
    final url = RealSrSuperResolution.manualDownloadUrl;
    if (url == null) {
      return ListTile(
        leading: const Icon(Icons.open_in_browser_outlined),
        title: Text(t.realSr.manualDownload),
        subtitle: Text(t.realSr.manualDownloadUnsupported),
      );
    }
    return ListTile(
      leading: const Icon(Icons.open_in_browser_outlined),
      title: Text(t.realSr.manualDownload),
      subtitle: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: TextButton(
        onPressed: _openManualDownloadUrl,
        child: Text(t.realSr.openDownloadUrl),
      ),
    );
  }

  Widget _buildImportModelTile() {
    return ListTile(
      leading: const Icon(Icons.file_open_outlined),
      title: Text(t.realSr.importModel),
      subtitle: Text(t.realSr.importModelSubtitle),
      trailing: _importing
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: _importModel,
              child: Text(t.realSr.importModelAction),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingPageShell(
      title: t.realSr.title,
      child: _loading
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : ListView(
              children: [
                settingSectionTitle(context, t.realSr.autoUpscaleSection),
                SwitchListTile(
                  secondary: const Icon(Icons.auto_fix_high_outlined),
                  title: Text(t.realSr.autoUpscale),
                  subtitle: Text(
                    !_isAvailable
                        ? t.realSr.autoUpscaleSubtitleUnavailable
                        : t.realSr.autoUpscaleSubtitleAvailable,
                  ),
                  thumbIcon: kSettingSwitchThumbIcon,
                  value: _autoUpscale,
                  onChanged: _setAutoUpscale,
                ),

                const SizedBox(height: 8),
                const Divider(height: 1, thickness: 0.3),
                settingSectionTitle(context, t.realSr.conditionSection),
                ListTile(
                  leading: const Icon(Icons.hd_outlined),
                  title: Text(t.realSr.resolutionThreshold),
                  subtitle: Text(t.realSr.resolutionThresholdSubtitle),
                  trailing: FluentDropdown<RealSrResolutionThreshold>(
                    value: _effectiveThreshold,
                    displayValue: _effectiveThreshold.label,
                    items: {
                      for (final threshold in _availableThresholds)
                        threshold: threshold.label,
                    },
                    onChanged: _setResolutionThreshold,
                  ),
                ),

                const SizedBox(height: 8),
                const Divider(height: 1, thickness: 0.3),
                settingSectionTitle(context, t.realSr.performanceSection),
                Builder(
                  builder: (context) {
                    final effective = _concurrencyOptions.contains(_concurrency)
                        ? _concurrency
                        : RealSrSettings.defaultConcurrency;
                    return ListTile(
                      leading: const Icon(Icons.speed_outlined),
                      title: Text(t.realSr.concurrency),
                      subtitle: Text(
                        _useMangaJaNaiEngine
                            ? t.realSr.concurrencyMangaJaNaiNote
                            : t.realSr.concurrencySubtitle,
                      ),
                      trailing: FluentDropdown<int>(
                        value: effective,
                        displayValue: _concurrencyLabels[effective]!,
                        items: {
                          for (final option in _concurrencyOptions)
                            option: _concurrencyLabels[option]!,
                        },
                        // MangaJaNai 固定单线程，本项对其无效：禁用下拉但保留
                        // 文字正常显示，以免说明文案跟着变灰看不清。
                        enabled: !_useMangaJaNaiEngine,
                        onChanged: _setConcurrency,
                      ),
                    );
                  },
                ),
                if (!_usesCoreML)
                  Builder(
                    builder: (context) {
                      final effective = _tileSizeOptions.contains(_tileSize)
                          ? _tileSize
                          : 0;
                      return ListTile(
                        leading: const Icon(Icons.grid_on_outlined),
                        title: Text(t.realSr.tileSize),
                        subtitle: Text(
                          _useMangaJaNaiEngine
                              ? t.realSr.tileSizeMangaJaNaiNote
                              : t.realSr.tileSizeSubtitle,
                        ),
                        trailing: FluentDropdown<int>(
                          value: effective,
                          displayValue: _tileSizeLabels[effective]!,
                          items: {
                            for (final option in _tileSizeOptions)
                              option: _tileSizeLabels[option]!,
                          },
                          // 同上：MangaJaNai 固定 512 分块，本项无效。
                          enabled: !_useMangaJaNaiEngine,
                          onChanged: _setTileSize,
                        ),
                      );
                    },
                  ),

                const SizedBox(height: 8),
                const Divider(height: 1, thickness: 0.3),
                settingSectionTitle(context, t.realSr.modelSection),
                ..._buildModelItems(),

                const SizedBox(height: 8),
                const Divider(height: 1, thickness: 0.3),
                settingSectionTitle(context, t.realSr.modelManagementSection),
                // MangaJaNai 引擎使用本机 GUI 的模型，无需下载/导入内置模型。
                if (!_useMangaJaNaiEngine) ...[
                  _buildModelManagementTile(),
                  _buildManualDownloadTile(),
                  _buildImportModelTile(),
                ],
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

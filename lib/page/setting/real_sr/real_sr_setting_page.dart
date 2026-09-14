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
import 'package:zephyr/page/setting/real_sr/service/mangajanai_remote.dart';
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
  SrEngine _srEngine = SrEngine.ncnn;
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

  /// 远程服务器配置（保存值，界面直接回显用户填的原文）。
  String _remoteBaseUrl = '';
  String _remoteApiKey = '';

  /// 远程探活状态：二者互斥，`_remoteError` 非空时 `_remoteHealth` 为 null。
  RemoteHealth? _remoteHealth;
  String? _remoteError;
  bool _remoteTesting = false;

  bool get _usesCoreML => Platform.isIOS || Platform.isMacOS;

  /// 当前平台可选的引擎。
  ///
  /// 与 `RealSrSettings.loadSrEngine()` 的平台归一化共用同一份定义 —— 界面下拉
  /// 与「实际生效的引擎」必须来自同一个列表，否则会出现「下拉里没有、却在执行」
  /// 的选项。iOS / macOS 走 CoreML，由 `_usesCoreML` 分支拦在前面。
  List<SrEngine> get _availableEngines => RealSrSettings.availableSrEngines;

  /// 实际生效的引擎。
  ///
  /// `_loadSettings` 读到的值已在存储层归一化；这里再兜一次底，覆盖页面停留期间
  /// 配置被其他入口改写的情况。
  SrEngine get _effectiveEngine =>
      _availableEngines.contains(_srEngine) ? _srEngine : SrEngine.ncnn;

  /// 是否使用本地 MangaJaNai CLI 后端。
  bool get _useLocalCliEngine => _effectiveEngine.isLocalCli;

  /// 是否使用远程 MangaJaNai 服务端。
  bool get _useRemoteEngine => _effectiveEngine.isRemote;

  /// 是否属于 MangaJaNai 家族（本地 CLI 或远程服务端）。
  ///
  /// 两者共用放大倍率与灰度判定阈值，且都不走 NCNN 的并发池与分块设置，
  /// 也不需要下载内置模型 —— 界面上按同一个条件收拢。
  bool get _useMangaJaNaiEngine => _effectiveEngine.isMangaJaNai;

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
    final srEngine = await RealSrSettings.loadSrEngine();
    final mangaJaNaiScale = await RealSrSettings.loadMangaJaNaiScale();
    final mangaJaNaiThreshold =
        await RealSrSettings.loadMangaJaNaiGrayscaleThreshold();
    final mangaJaNaiPythonPath =
        await RealSrSettings.loadMangaJaNaiPythonPath();
    final mangaJaNaiBackendSrcDir =
        await RealSrSettings.loadMangaJaNaiBackendSrcDir();
    final mangaJaNaiModelsDir = await RealSrSettings.loadMangaJaNaiModelsDir();
    final remoteBaseUrl = await RealSrSettings.loadMangaJaNaiRemoteBaseUrl();
    final remoteApiKey = await RealSrSettings.loadMangaJaNaiRemoteApiKey();
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
      _srEngine = srEngine;
      _mangaJaNaiScale = mangaJaNaiScale;
      _mangaJaNaiGrayscaleThreshold = mangaJaNaiThreshold;
      _mangaJaNaiPythonPath = mangaJaNaiPythonPath;
      _mangaJaNaiBackendSrcDir = mangaJaNaiBackendSrcDir;
      _mangaJaNaiModelsDir = mangaJaNaiModelsDir;
      _remoteBaseUrl = remoteBaseUrl;
      _remoteApiKey = remoteApiKey;
      _coreMLFamily = family;
      _coreMLVariant = variant;
      _loading = false;
    });

    if (_useLocalCliEngine) {
      await _refreshMangaJaNaiStatus();
    } else if (_useRemoteEngine) {
      await _refreshRemoteStatus();
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

  Future<void> _setSrEngine(SrEngine value) async {
    await RealSrSettings.saveSrEngine(value);
    setState(() => _srEngine = value);
    await _refreshAvailability();
    if (_useLocalCliEngine) {
      await _refreshMangaJaNaiStatus();
    } else if (_useRemoteEngine) {
      await _refreshRemoteStatus();
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

  // =========================================================
  // 远程服务器（mjn-service）
  // =========================================================

  /// 远程状态副标题：优先显示探活结果，其次是错误原因，最后是未配置提示。
  String get _remoteStatusLine {
    if (_remoteBaseUrl.trim().isEmpty) return t.realSr.remoteNotConfigured;
    if (_remoteTesting) return t.realSr.remoteTesting;
    final error = _remoteError;
    if (error != null) return error;
    final health = _remoteHealth;
    if (health == null) return t.realSr.remoteNotConfigured;
    return t.realSr.remoteStatusFormat(
      device: health.device,
      depth: health.queueDepth,
      queueMax: health.queueMax,
      models: health.loadedModels,
    );
  }

  /// 探活远程服务（进页面 / 切换引擎时调用）。
  ///
  /// 走 `force` 绕过 30 秒缓存：设置页是用户主动查看的地方，显示上一次的
  /// 陈旧结论比多打一次请求更让人困惑。
  Future<void> _refreshRemoteStatus() async {
    if (!_useRemoteEngine) return;
    setState(() {
      _remoteTesting = true;
      _remoteError = null;
    });
    try {
      final health = await MangaJaNaiRemoteEngine.probe(force: true);
      if (!mounted) return;
      setState(() => _remoteHealth = health);
    } on MangaJaNaiRemoteException catch (e) {
      if (!mounted) return;
      setState(() {
        _remoteHealth = null;
        _remoteError = e.message;
      });
    } finally {
      if (mounted) setState(() => _remoteTesting = false);
    }
  }

  /// 「测试连接」按钮：强制探活并把结果反馈给用户。
  Future<void> _testRemoteConnection() async {
    setState(() {
      _remoteTesting = true;
      _remoteError = null;
    });
    try {
      final health = await MangaJaNaiRemoteEngine.testConnection();
      if (!mounted) return;
      setState(() => _remoteHealth = health);
      showSuccessToast(t.realSr.remoteTestSuccess);
    } catch (e, s) {
      logger.w('远程超分服务连接测试失败', error: e, stackTrace: s);
      if (!mounted) return;
      setState(() {
        _remoteHealth = null;
        _remoteError = '$e';
      });
      showErrorToast('${t.realSr.remoteTestFailed}：$e');
    } finally {
      if (mounted) {
        setState(() => _remoteTesting = false);
        await _refreshAvailability();
      }
    }
  }

  /// 弹窗编辑远程服务器地址与 Token。
  Future<void> _editRemoteConfig() async {
    final urlCtrl = TextEditingController(text: _remoteBaseUrl);
    final keyCtrl = TextEditingController(text: _remoteApiKey);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.realSr.remoteConfig),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: t.realSr.remoteBaseUrl,
                  hintText: t.realSr.remoteBaseUrlHint,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: keyCtrl,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: t.realSr.remoteApiKey,
                  hintText: t.realSr.remoteApiKeyHint,
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
      RealSrSettings.saveMangaJaNaiRemoteBaseUrl(urlCtrl.text),
      RealSrSettings.saveMangaJaNaiRemoteApiKey(keyCtrl.text),
    ]);
    // 地址 / Token 变了，旧的探活结论作废。
    MangaJaNaiRemoteEngine.invalidateHealthCache();
    setState(() {
      _remoteBaseUrl = urlCtrl.text.trim();
      _remoteApiKey = keyCtrl.text.trim();
      _remoteHealth = null;
      _remoteError = null;
    });
    await _refreshRemoteStatus();
    await _refreshAvailability();
  }

  /// 远程服务端的健康告警：缺模型、未启用 CUDA、开了鉴权但没填 Token。
  Widget? _buildRemoteWarningTile() {
    final health = _remoteHealth;
    if (health == null) return null;

    final warnings = <String>[
      if (!health.cuda) t.realSr.remoteCudaOff,
      if (!health.modelsReady)
        '${t.realSr.remoteMissingModels}（${health.missingModels.length}）',
      if (health.authRequired && _remoteApiKey.trim().isEmpty)
        t.realSr.remoteApiKeyHint,
    ];
    if (warnings.isEmpty) return null;

    return ListTile(
      leading: const Icon(Icons.warning_amber_rounded),
      title: Text(warnings.join('\n')),
    );
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

    // 引擎选择：除 iOS / macOS（走 CoreML）外所有平台都有 ——
    // Android 也能选远程服务端，这正是让手机用上本机 4070S 的入口。
    final items = <Widget>[
      ListTile(
        leading: const Icon(Icons.memory_outlined),
        title: Text(t.realSr.engine),
        subtitle: Text(t.realSr.engineSubtitle),
        trailing: FluentDropdown<SrEngine>(
          value: _effectiveEngine,
          displayValue: _effectiveEngine.label,
          items: {for (final engine in _availableEngines) engine: engine.label},
          onChanged: _setSrEngine,
        ),
      ),
    ];

    if (_useRemoteEngine) {
      items.addAll(_buildRemoteMangaJaNaiItems());
    } else if (_useLocalCliEngine) {
      items.addAll(_buildLocalMangaJaNaiItems());
    } else if (Platform.isAndroid) {
      items.add(
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(t.realSr.androidSuperResolution),
          subtitle: Text(t.realSr.androidSuperResolutionSubtitle),
        ),
      );
    } else {
      // Windows / Linux 的内置 NCNN
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

  /// MangaJaNai 家族共用的调参项：放大倍率与灰度判定阈值。
  ///
  /// 本地 CLI 与远程服务端按同一套链配置工作（服务端的 `chains.py` 就是照抄
  /// Breeze 的 `_buildChains()`），因此这两项对两者含义完全一致。
  List<Widget> _buildMangaJaNaiTuningItems() {
    final effectiveScale = _mangaJaNaiScaleLabels.containsKey(_mangaJaNaiScale)
        ? _mangaJaNaiScale
        : 2;
    final effectiveThreshold =
        _mangaJaNaiThresholdLabels.containsKey(_mangaJaNaiGrayscaleThreshold)
        ? _mangaJaNaiGrayscaleThreshold
        : 12;
    return [
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
    ];
  }

  /// 本地 MangaJaNai CLI 后端：调参 + 路径覆写 + 就绪状态 + 在线安装 + NVIDIA 提示。
  List<Widget> _buildLocalMangaJaNaiItems() {
    final pathsCustomized =
        _mangaJaNaiPythonPath.isNotEmpty ||
        _mangaJaNaiBackendSrcDir.isNotEmpty ||
        _mangaJaNaiModelsDir.isNotEmpty;
    return [
      ..._buildMangaJaNaiTuningItems(),
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
    ];
  }

  /// 远程 MangaJaNai 服务端：调参 + 服务器配置 + 连接测试。
  List<Widget> _buildRemoteMangaJaNaiItems() {
    final warning = _buildRemoteWarningTile();
    final ready = _remoteHealth != null;
    return [
      ..._buildMangaJaNaiTuningItems(),
      ListTile(
        leading: const Icon(Icons.dns_outlined),
        title: Text(t.realSr.remoteConfig),
        subtitle: Text(
          _remoteBaseUrl.trim().isEmpty
              ? t.realSr.remoteConfigSubtitle
              : _remoteBaseUrl,
        ),
        trailing: TextButton(
          onPressed: _editRemoteConfig,
          child: Text(t.realSr.remoteConfigAction),
        ),
      ),
      ListTile(
        leading: _remoteTesting
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                ready ? Icons.check_circle : Icons.error_outline,
                color: ready ? Theme.of(context).colorScheme.primary : null,
              ),
        title: Text(ready ? t.realSr.remoteReady : t.realSr.remoteNotReady),
        subtitle: Text(_remoteStatusLine),
        trailing: TextButton(
          onPressed: _remoteTesting ? null : _testRemoteConnection,
          child: Text(t.realSr.remoteTest),
        ),
      ),
      ?warning,
    ];
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
                    // 不可用时的原因按引擎区分：远程模式下说「模型未下载」会
                    // 把人引向下载本地模型，而真正的问题多半是服务端没连上。
                    _isAvailable
                        ? t.realSr.autoUpscaleSubtitleAvailable
                        : _effectiveEngine.isRemote
                        ? t.realSr.remoteNotReady
                        : t.realSr.autoUpscaleSubtitleUnavailable,
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

                // MangaJaNai 家族（本地 CLI 用 GUI/引擎包的模型，远程用服务端
                // 自己的模型）都不需要下载或导入内置模型，整段隐藏。
                if (!_useMangaJaNaiEngine) ...[
                  const SizedBox(height: 8),
                  const Divider(height: 1, thickness: 0.3),
                  settingSectionTitle(context, t.realSr.modelManagementSection),
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

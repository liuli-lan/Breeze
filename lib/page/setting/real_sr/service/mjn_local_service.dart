import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_engine.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_remote.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';
import 'package:zephyr/util/get_path.dart';

/// 本机常驻超分服务的状态。
enum MjnServiceState {
  /// 未启动（或已正常停止）。
  stopped,

  /// 已拉起进程，正在等 `/v1/health` 就绪。
  starting,

  /// 自己拉起的实例已就绪。
  running,

  /// 端口上本来就有可用实例（例如 WSL 侧的服务经 portproxy 暴露到
  /// `127.0.0.1:8765`），直接复用，不另起进程。
  adopted,

  /// 已放弃：引擎未就绪、端口被别的程序占用、或连续崩溃超过上限。
  failed,
}

/// 本机服务的一次状态快照，供设置页展示。
class MjnServiceStatus {
  const MjnServiceStatus({
    required this.state,
    this.message,
    this.health,
    this.port = RealSrSettings.defaultMjnServicePort,
  });

  final MjnServiceState state;

  /// 给用户看的一句话：失败原因，或「正在复用已有实例」的说明。
  final String? message;

  /// 就绪时的服务端摘要（设备 / 队列 / 已加载模型）。
  final RemoteHealth? health;

  final int port;

  bool get ready =>
      state == MjnServiceState.running || state == MjnServiceState.adopted;

  /// 服务端的 baseUrl；未就绪时为 null。
  ///
  /// 本机服务固定走 `127.0.0.1`：即使绑了 `0.0.0.0`（为让手机访问），
  /// 本机客户端也没有理由绕道局域网地址。
  String? get baseUrl => ready ? 'http://127.0.0.1:$port' : null;
}

/// 本机常驻超分服务的生命周期管理（仅 Windows）。
///
/// ## 为什么需要它
///
/// Breeze 原有的本机做法是「每批超分 spawn 一次 `run_upscale.py`」，每次都要重付
/// Python 启动 + torch 导入 + 后端初始化 + 载模型的固定成本。Windows 上实测：
///
/// - 每次 spawn：**5.79 / 5.86 / 6.02 s** 一张（1300p 彩色、2x）
/// - 常驻服务：**1.19 s** 一张（冷启动那次 2.31 s）
///
/// 也就是说**阅读单页从约 6 秒降到约 1.2 秒**。服务把 torch 与模型常驻显存，
/// 固定成本只付一次。
///
/// ## 进程模型：Breeze 作为宿主
///
/// 服务是我们拉起的**子进程**，由本类负责启动 / 探活 / 崩溃重启 / 退出清理。
/// 之所以不用 Windows 服务或计划任务：那两者都要提权或额外安装步骤，
/// 而「用户关掉 Breeze = 服务停」这个因果关系对普通用户更自洽（见方案 §3.1）。
///
/// ## 孤儿进程：靠 stdin 管道解决
///
/// 父进程被强杀（任务管理器结束进程）时 **Windows 不会回收子进程**，会留下一个
/// 占着端口、握着数 GB 显存的孤儿。本类的对策是：**持有子进程 stdin 的写端且不关闭**。
/// 服务端侧有一个线程阻塞读 stdin，父进程一死管道写端被 OS 关闭 → 读到 EOF →
/// 服务立即自我了结（服务端的 `_guard_parent_death`，由 `MJN_PARENT_STDIN=1` 开启）。
///
/// 比轮询父进程 PID 更即时，也不依赖任何 Windows API。
/// 因此 [stop] 只需关闭 stdin，无需强杀。
class MjnLocalService {
  MjnLocalService._();

  static final MjnLocalService instance = MjnLocalService._();

  /// 随应用分发的服务代码（见 pubspec 的 `asset/mangajanai_service/*`）。
  static const List<String> _assetFiles = <String>[
    'mjn_service.py',
    'chains.py',
  ];
  static const String _assetDir = 'asset/mangajanai_service';

  /// 启动就绪超时。
  ///
  /// 实测后端引导（含 CUDA 初始化）约 2.2 s、torch 导入约 2.3 s，正常几秒就绪；
  /// 首次启动还要算上冷文件缓存与杀软扫描，给足 90 s。
  static const Duration _readyTimeout = Duration(seconds: 90);

  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// 停止时等服务优雅退出的宽限时间，超过才强杀。
  static const Duration _gracefulStopTimeout = Duration(seconds: 5);

  /// 探活超时。本机回环，给短超时即可，避免拖慢状态刷新。
  static const Duration _probeTimeout = Duration(seconds: 4);

  /// 退避重启间隔序列。
  ///
  /// 容器里可以无限重启，桌面应用不能 —— 无限拉进程会让用户看到反复闪烁的状态。
  /// 因此按序列退避，超过 [maxConsecutiveFailures] 次即放弃并把日志尾部暴露出来。
  static const List<Duration> _restartBackoff = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// 连续失败多少次后放弃自动重启。
  static const int maxConsecutiveFailures = 3;

  /// 保留最近多少行服务输出，供失败时展示。
  static const int _recentOutputLimit = 40;

  Process? _process;

  /// 子进程 stdin 的写端。**必须持有且不关闭** —— 这是孤儿自检的机制本身：
  /// 一旦本进程消失，OS 关闭写端，服务读到 EOF 后自我了结。
  IOSink? _stdinHold;

  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  MjnServiceState _state = MjnServiceState.stopped;
  String? _message;
  RemoteHealth? _health;
  int _port = RealSrSettings.defaultMjnServicePort;

  /// 本次进程是否已退出；用于在就绪等待期间及时发现崩溃。
  Completer<void>? _processGone;
  int? _lastExitCode;

  int _consecutiveFailures = 0;
  bool _stopping = false;
  Timer? _restartTimer;

  /// 本次进程生命周期内是否已经真正尝试过启动。
  ///
  /// 见 [ensureStarted] 的 [force] 说明：没有这个守卫，一个起不来的服务会在
  /// 热路径（每张图之前）被反复重试。
  bool _startAttempted = false;

  /// 进行中的启动流程。并发调用 [ensureStarted] 时复用它，避免拉起两个实例。
  Future<MjnServiceStatus>? _pendingStart;

  final List<String> _recentOutput = <String>[];

  MjnServiceState get state => _state;
  bool get isReady =>
      _state == MjnServiceState.running || _state == MjnServiceState.adopted;

  /// 服务端 baseUrl（`http://127.0.0.1:<port>`）；未就绪时为 null。
  String? get baseUrl => isReady ? 'http://127.0.0.1:$_port' : null;

  /// 最近的服务输出（stderr 优先），失败原因展示用。
  List<String> get recentOutput => List<String>.unmodifiable(_recentOutput);

  /// 是否正持有子进程 stdin 的写端。
  ///
  /// 这不只是诊断信息 —— 它**就是**孤儿自检的开/关状态：为 true 时本进程一旦消失，
  /// OS 会关闭管道写端，服务读到 EOF 即刻自我了结，不会留下占端口和显存的孤儿。
  /// 因此 [_stdinHold] 这个字段被刻意持有且从不关闭，设置页可据此展示托管状态。
  bool get holdsParentPipe => _stdinHold != null;

  MjnServiceStatus get status => MjnServiceStatus(
    state: _state,
    message: _message,
    health: _health,
    port: _port,
  );

  // =========================================================
  // 对外入口
  // =========================================================

  /// 幂等地确保服务可用。
  ///
  /// 顺序刻意如此，每一步都在避免更贵的操作：
  /// 1. 非 Windows / 引擎未就绪 → 直接失败（不拉起进程，避免必然失败的启动）；
  /// 2. **先探端口**：若已有可用实例，直接复用 —— 不白拉一个必然因端口冲突而退出的进程；
  /// 3. 释放服务代码到 `<files>/mangajanai/service/`；
  /// 4. 拉起进程并等 `/v1/health` 就绪。
  ///
  /// [force] 为 false 时，**本次进程生命周期内只真正尝试一次**：失败过就直接返回上次结论。
  /// 这个守卫是必需的 —— 超分主流程会在每张图之前问一次可用性，若无条件重试，
  /// 一个起不来的服务会让每张图都白付一遍「探端口 + 释放资产 + 拉起进程」的成本。
  /// 用户在设置页主动点击/重进页面时才传 `force: true` 重试。
  Future<MjnServiceStatus> ensureStarted({bool force = false}) {
    if (!force && _startAttempted && !isReady) return Future.value(status);

    final pending = _pendingStart;
    if (pending != null) return pending;

    _startAttempted = true;
    final future = _ensureStarted();
    _pendingStart = future;
    return future.whenComplete(() => _pendingStart = null);
  }

  /// 后台启动一次（不等待结果）。
  ///
  /// 给超分主流程用：服务还没就绪时**让本次仍走 CLI 路径**（功能不中断），
  /// 同时把服务在后台拉起来，后续图片就能用上它。这样首张图不会被启动延迟拖慢。
  void requestStartInBackground({bool force = false}) {
    unawaited(ensureStarted(force: force));
  }

  Future<MjnServiceStatus> _ensureStarted() async {
    if (_state == MjnServiceState.running && !_hasExited) {
      return status;
    }
    if (!Platform.isWindows) {
      return _fail('本机 MangaJaNai 服务仅支持 Windows');
    }

    _port = await RealSrSettings.loadMjnServicePort();

    final missing = await MangaJaNaiEngine.missingRequirements();
    if (missing.isNotEmpty) {
      return _fail(
        'MangaJaNai 引擎未就绪（缺 ${missing.length} 项），'
        '请先在下方安装运行环境',
      );
    }

    // 端口上已有可用实例：直接复用。
    //
    // 典型场景：本机同时跑着 WSL 侧的服务（经 portproxy 暴露到 127.0.0.1:8765）。
    // 复用比另起一个必然冲突的实例更好 —— 服务端也会以退出码 3 表达同一件事。
    final existing = await _probeHealth();
    if (existing != null) {
      return _adopt(existing);
    }

    try {
      final serviceDir = await _releaseServiceCode();
      final paths = await MangaJaNaiEngine.resolvePaths();
      await _launch(
        serviceDir: serviceDir,
        pythonPath: paths.pythonPath,
        backendSrcDir: paths.backendSrcDir,
        modelsDir: paths.modelsDir,
      );
    } on Object catch (e, s) {
      logger.w('本机超分服务启动失败', error: e, stackTrace: s);
      return _fail('服务启动失败：$e');
    }

    return _awaitReady();
  }

  /// 停止由本实例拉起的服务。
  ///
  /// 关闭 stdin 即可让服务端自行退出（孤儿自检机制），宽限期内没退再强杀。
  /// 复用的外部实例（[MjnServiceState.adopted]）**不会被停掉** —— 那不是我们拉起的。
  Future<void> stop() async {
    _stopping = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _teardownProcess(force: false);
    _state = MjnServiceState.stopped;
    _message = null;
    _health = null;
    _consecutiveFailures = 0;
    _startAttempted = false;
    _stopping = false;
  }

  // =========================================================
  // 服务代码释放
  // =========================================================

  /// 服务代码的落地目录。
  static Future<String> _serviceDir() async =>
      p.join(await getFilePath(), 'mangajanai', 'service');

  static Future<String> _workDir() async => p.join(await _serviceDir(), 'work');

  static Future<String> _logFile() async =>
      p.join(await _serviceDir(), 'logs', 'service.log');

  /// 把随应用分发的服务代码释放到磁盘，返回服务目录。
  ///
  /// **内容相同则不重写**：避免每次启动都刷新 mtime，也让目录保持稳定
  /// （杀软与文件缓存都不会被无谓地打乱）。
  Future<String> _releaseServiceCode() async {
    final dir = await _serviceDir();
    await Directory(dir).create(recursive: true);
    await Directory(await _workDir()).create(recursive: true);

    for (final name in _assetFiles) {
      final target = File(p.join(dir, name));
      final data = await rootBundle.load('$_assetDir/$name');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (target.existsSync() &&
          _bytesEqual(await target.readAsBytes(), bytes)) {
        continue;
      }
      await target.writeAsBytes(bytes, flush: true);
      logger.d('已释放本机服务代码：$name（${bytes.length} B）');
    }
    return dir;
  }

  /// 公开的服务代码释放入口（幂等），供安装/导入流程在完成时调用。
  ///
  /// 为什么需要它：导入离线包会**整体替换** `<files>/mangajanai/`，把此前释放的
  /// `service/` 一并抹掉 —— 装完/导完立刻把服务代码放回去，用户就不用经历
  /// 「装完第一次起服务时才发现 service/ 没了」这种隐式等待。
  Future<String> releaseServiceCode() => _releaseServiceCode();

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // =========================================================
  // 进程拉起与守护
  // =========================================================

  Future<void> _launch({
    required String serviceDir,
    required String pythonPath,
    required String backendSrcDir,
    required String modelsDir,
  }) async {
    await _teardownProcess(force: true);

    final bindLan = await RealSrSettings.loadMjnServiceBindLan();
    final env = <String, String>{
      'MJN_SRC': backendSrcDir,
      'MJN_MODELS': modelsDir,
      'MJN_WORK': await _workDir(),
      'MJN_SERVICE': serviceDir,
      'MJN_PORT': '$_port',
      // 绑 0.0.0.0 是为了让同一台 PC 的显卡也能服务手机；关掉则只服务本机。
      'MJN_HOST': bindLan ? '0.0.0.0' : '127.0.0.1',
      // **不预热模型**：预热要多花启动时间，而就绪慢会连带拖住 isAvailable()，
      // 让应用刚启动时的几张图直接跳过超分。改成按需加载 —— 每个模型首次多付
      // 约 0.5 s，远比"前几十秒完全不可用"划算。
      'MJN_PRELOAD': '0',
      // 开启服务端的父进程守护（stdin EOF → 自我了结），配合 _stdinHold。
      'MJN_PARENT_STDIN': '1',
      'MJN_LOG_FILE': await _logFile(),
      // 无缓冲，保证日志实时；不写 .pyc，避免在只读/被扫描的目录里留垃圾。
      'PYTHONUNBUFFERED': '1',
      'PYTHONDONTWRITEBYTECODE': '1',
    };

    logger.d('启动本机超分服务：$pythonPath（端口 $_port，LAN=$bindLan）');

    final process = await Process.start(
      pythonPath,
      <String>[p.join(serviceDir, 'mjn_service.py')],
      workingDirectory: serviceDir,
      environment: env,
      runInShell: false,
    );

    _process = process;
    _stdinHold = process.stdin; // 持有写端 = 孤儿自检的机制本身，勿关闭
    _processGone = Completer<void>();
    _lastExitCode = null;
    _state = MjnServiceState.starting;
    _message = null;

    const decoder = Utf8Decoder(allowMalformed: true);
    _stdoutSub = process.stdout
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(_recordOutput);
    // stderr 单独留后缀，便于失败时区分「正常进度」和「报错」。
    _stderrSub = process.stderr
        .transform(decoder)
        .transform(const LineSplitter())
        .listen((line) => _recordOutput('[stderr] $line'));

    unawaited(
      process.exitCode.then((code) => _onExit(code)).catchError((Object e) {
        logger.w('本机超分服务进程异常结束', error: e);
      }),
    );
  }

  void _recordOutput(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _recentOutput.add(trimmed);
    while (_recentOutput.length > _recentOutputLimit) {
      _recentOutput.removeAt(0);
    }
    logger.d('[mjn-service] $trimmed');
  }

  bool get _hasExited => _process == null;

  /// 等 `/v1/health` 就绪，期间若进程自己退了就立即失败。
  Future<MjnServiceStatus> _awaitReady() async {
    final deadline = DateTime.now().add(_readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_hasExited) {
        // 进程已退出：交给 _onExit 的退出码分支处理，但那里可能已经重启过一次，
        // 这里只把当前结论返回给调用方。
        final code = _lastExitCode;
        if (code == 3) {
          final existing = await _probeHealth();
          if (existing != null) return _adopt(existing);
        }
        return _fail(_lastExitCode == null ? '服务进程已退出' : _exitMessage(code!));
      }

      final health = await _probeHealth();
      if (health != null) {
        _consecutiveFailures = 0;
        _state = MjnServiceState.running;
        _health = health;
        _message = null;
        logger.d('本机超分服务就绪：${health.device}，已加载 ${health.loadedModels} 个模型');
        return status;
      }

      await Future<void>.delayed(_pollInterval);
    }

    await _teardownProcess(force: true);
    return _fail('服务启动超时（${_readyTimeout.inSeconds} s 内未就绪）');
  }

  Future<void> _onExit(int code) async {
    _lastExitCode = code;
    final gone = _processGone;
    if (gone != null && !gone.isCompleted) gone.complete();
    _processGone = null;

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _stdinHold = null;
    _process = null;
    _health = null;

    if (_stopping) {
      _state = MjnServiceState.stopped;
      return;
    }

    switch (code) {
      case 0:
        // 正常退出（含父进程已死）。不重启。
        _state = MjnServiceState.stopped;
        _message = null;
      case 3:
        // 端口上已有同类服务 —— 复用，绝不重启（否则会无限互撞）。
        final existing = await _probeHealth();
        if (existing != null) {
          _adopt(existing);
        } else {
          _fail('端口 $_port 上已有服务实例，但它当前不可用');
        }
      case 4:
        // 端口被其他程序占用。重启也没用。
        _fail('端口 $_port 被其他程序占用，请在设置里换一个端口');
      default:
        _scheduleRestart(code);
    }
  }

  void _scheduleRestart(int code) {
    if (_consecutiveFailures >= maxConsecutiveFailures) {
      _fail('服务连续 $_consecutiveFailures 次异常退出（退出码 $code），已停止自动重启');
      return;
    }

    final delay =
        _restartBackoff[_consecutiveFailures.clamp(
          0,
          _restartBackoff.length - 1,
        )];
    _consecutiveFailures++;
    _state = MjnServiceState.starting;
    _message =
        '服务异常退出（退出码 $code），${delay.inSeconds} 秒后重启'
        '（第 $_consecutiveFailures 次）';
    logger.w(_message!);

    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      if (_stopping) return;
      unawaited(ensureStarted());
    });
  }

  /// 关掉当前进程。先关 stdin 让服务端优雅退出，宽限期内没退再强杀。
  Future<void> _teardownProcess({required bool force}) async {
    final process = _process;
    _process = null;

    if (process != null) {
      // 关闭 stdin 即触发服务端的父进程守护，它会自己 os._exit(0)。
      try {
        await process.stdin.close();
      } on Object catch (_) {
        // 管道可能已断，忽略
      }

      if (force) {
        try {
          process.kill(ProcessSignal.sigkill);
        } on Object catch (_) {
          // 进程可能已退出
        }
      } else {
        try {
          await process.exitCode.timeout(_gracefulStopTimeout);
        } on TimeoutException {
          logger.w('服务未在宽限期内退出，强制结束');
          try {
            process.kill(ProcessSignal.sigkill);
          } on Object catch (_) {}
        }
      }
    }

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _stdinHold = null;
  }

  // =========================================================
  // 探活与状态
  // =========================================================

  /// 探一次 `http://127.0.0.1:<port>/v1/health`。
  ///
  /// 与 [MangaJaNaiRemoteEngine] 的区别是**地址不由用户配置**：本机服务固定回环。
  /// 用 `WindHttp.direct` 强制直连 —— 回环地址走系统代理必然失败。
  Future<RemoteHealth?> _probeHealth() async {
    try {
      final res = await WindHttp.direct(
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: _probeTimeout,
      ).fetch('http://127.0.0.1:$_port/v1/health', timeout: _probeTimeout);
      if (!res.ok) return null;
      final decoded = res.json;
      if (decoded is! Map<String, dynamic>) return null;
      final health = RemoteHealth.fromJson(decoded);
      // 只认自家服务：端口上可能是任意 web 服务。
      if (health.service != 'mjn-upscale') return null;
      return health;
    } on Object catch (_) {
      return null;
    }
  }

  MjnServiceStatus _adopt(RemoteHealth health) {
    _state = MjnServiceState.adopted;
    _health = health;
    _message = '端口 $_port 上已有可用实例，正在复用它（未另起进程）';
    logger.d('复用已有的本机超分服务实例：${health.device}');
    return status;
  }

  MjnServiceStatus _fail(String message) {
    _state = MjnServiceState.failed;
    _message = message;
    _health = null;
    logger.w('本机超分服务不可用：$message');
    return status;
  }

  static String _exitMessage(int code) => switch (code) {
    3 => '端口上已有服务实例（退出码 3）',
    4 => '端口被其他程序占用（退出码 4）',
    _ => '服务进程异常退出（退出码 $code）',
  };
}

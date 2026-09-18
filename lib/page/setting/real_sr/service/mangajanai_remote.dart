import 'dart:io';

import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';

/// 远程 MangaJaNai 超分服务（mjn-service）的 `/v1/health` 摘要。
///
/// 字段与 mjn-service 的 `health()` 响应一一对应；全部按「缺字段不炸」解析，
/// 以便服务端后续加字段时老客户端仍能用。
class RemoteHealth {
  const RemoteHealth({
    required this.service,
    required this.uptimeS,
    required this.cuda,
    required this.device,
    required this.loadedModels,
    required this.queueDepth,
    required this.queueMax,
    required this.bulkWaiting,
    required this.missingModels,
    required this.allowedScales,
    required this.authRequired,
  });

  final String service;
  final double uptimeS;
  final bool cuda;
  final String device;
  final int loadedModels;
  final int queueDepth;
  final int queueMax;
  final int bulkWaiting;
  final List<String> missingModels;
  final List<int> allowedScales;
  final bool authRequired;

  /// 服务端模型是否齐全。缺模型时多数链会降级或直接报错，值得在设置页提示。
  bool get modelsReady => missingModels.isEmpty;

  factory RemoteHealth.fromJson(Map<String, dynamic> json) {
    final engine = _asMap(json['engine']);
    final queue = _asMap(json['queue']);
    final models = _asMap(json['models']);
    final config = _asMap(json['config']);
    return RemoteHealth(
      service: _asString(json['service'], 'mjn-upscale'),
      uptimeS: _asDouble(json['uptime_s']),
      cuda: _asBool(engine['cuda']),
      device: _asString(engine['device'], 'unknown'),
      loadedModels: _asInt(engine['loaded_models']),
      queueDepth: _asInt(queue['depth']),
      queueMax: _asInt(queue['max']),
      bulkWaiting: _asInt(queue['bulk_waiting']),
      missingModels: _asStringList(models['missing']),
      allowedScales: _asIntList(config['allowed_scales']),
      authRequired: _asBool(config['auth_required']),
    );
  }
}

/// 远程超分服务相关的可读错误。
///
/// 与 [StateError] 区分开，便于调用方把「网络/服务端问题」与「用法错误」
/// 分开提示，也便于设置页把原始异常转成用户能看懂的一句话。
class MangaJaNaiRemoteException implements Exception {
  const MangaJaNaiRemoteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 远程 MangaJaNai 超分引擎（mjn-service 客户端）。
///
/// 把超分任务通过局域网 HTTP 发到跑着 RTX 4070S 的 PC：
/// - 服务端常驻加载 torch 与模型，单张端到端约 0.7 s（2x）/ 2.8 s（4x）；
/// - 服务端自带两通道调度（交互式优先于批量），所以客户端**不需要**再攒批，
///   每张图直接发单张请求即可 —— 预取已经让延迟离开关键路径。
///
/// 三条与本地 CLI 路径的关键差异（都是被实测数字逼出来的）：
/// 1. **不转 PNG**：服务端 pyvips 按内容识别格式，转 PNG 只会让上传体积涨 3-5 倍。
/// 2. **不走 MangaJaNaiBatchScheduler**：那是为「本地 CLI 每次调用都要付
///    Python/torch 冷启动」设计的；远程服务端常驻，攒批只会平白增加延迟。
/// 3. **强制直连**（[WindHttp.direct]）：局域网地址走系统代理必然失败。
class MangaJaNaiRemoteEngine {
  MangaJaNaiRemoteEngine._();

  /// 探活超时：够慢网回应，又不至于让设置页卡住。
  static const Duration _healthTimeout = Duration(seconds: 6);
  static const Duration _healthConnectTimeout = Duration(seconds: 4);

  /// 单张超分超时。
  ///
  /// 4x 单张实测 2.6 s，但服务端可能正跑着批量任务，排队上限约 2.4 s；
  /// 再算上 3 MB 量级的结果下载，120 s 是很宽松的上限。
  static const Duration _upscaleTimeout = Duration(seconds: 120);

  /// 探活结果缓存时长（成功）。
  ///
  /// [isAvailable] 在每张图超分前都会被调用，必须廉价；缓存让热路径上的
  /// HTTP 开销降到约每 30 秒一次，同时让「服务端掉线」能在半分钟内被发现。
  static const Duration _healthTtl = Duration(seconds: 30);

  /// 探活失败缓存时长（短得多）：避免一次抖动就让设置页长时间显示不可用，
  /// 也避免服务端刚好在重启时被反复打。
  static const Duration _healthFailTtl = Duration(seconds: 5);

  static RemoteHealth? _cachedHealth;
  static String? _cachedError;
  static DateTime? _cachedAt;

  /// 清空探活缓存。设置页保存地址/Token 后调用，避免沿用旧地址的结果。
  static void invalidateHealthCache() {
    _cachedHealth = null;
    _cachedError = null;
    _cachedAt = null;
  }

  /// 规范化用户填写的服务器地址。
  ///
  /// 容忍几种常见写法：`192.168.1.5:8765`、`http://192.168.1.5:8765/`、
  /// 甚至误粘贴的 `http://192.168.1.5:8765/v1/health` —— 统一成
  /// `scheme://host[:port]`，路径一律丢弃（服务端路径由客户端拼）。
  ///
  /// 返回 null 表示无法解析（未配置或明显非法）。
  static String? normalizeBaseUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (!value.contains('://')) value = 'http://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  /// 读取当前配置并规范化，未配置时返回 null。
  static Future<String?> configuredBaseUrl() async {
    final raw = await RealSrSettings.loadMangaJaNaiRemoteBaseUrl();
    return normalizeBaseUrl(raw);
  }

  /// 构造请求头。服务端未开鉴权时留空即可。
  static Future<Map<String, String>> _headers() async {
    final apiKey = (await RealSrSettings.loadMangaJaNaiRemoteApiKey()).trim();
    return {
      if (apiKey.isNotEmpty) 'X-Api-Key': apiKey,
      'Accept': 'application/json',
    };
  }

  /// 探活：`GET /v1/health`（服务端对该路径免鉴权）。
  ///
  /// [force] 为 true 时跳过缓存，用于设置页的「测试连接」。
  /// 失败抛 [MangaJaNaiRemoteException]，message 已是可读文案。
  static Future<RemoteHealth> probe({bool force = false}) async {
    final now = DateTime.now();
    final cachedAt = _cachedAt;
    if (!force && cachedAt != null) {
      final age = now.difference(cachedAt);
      if (_cachedError == null) {
        if (age < _healthTtl && _cachedHealth != null) return _cachedHealth!;
      } else if (age < _healthFailTtl) {
        throw MangaJaNaiRemoteException(_cachedError!);
      }
    }

    final baseUrl = await configuredBaseUrl();
    if (baseUrl == null) {
      throw const MangaJaNaiRemoteException('未配置远程服务器地址');
    }

    try {
      final res =
          await WindHttp.direct(
            connectTimeout: _healthConnectTimeout,
            receiveTimeout: _healthTimeout,
          ).fetch(
            '$baseUrl/v1/health',
            headers: await _headers(),
            timeout: _healthTimeout,
          );

      if (res.status == 401) {
        throw const MangaJaNaiRemoteException(
          '鉴权失败：Token 与服务端 MJN_API_KEY 不一致',
        );
      }
      if (!res.ok) {
        throw MangaJaNaiRemoteException(
          '服务端返回 HTTP ${res.status}${res.statusText.isEmpty ? '' : ' ${res.statusText}'}',
        );
      }

      final decoded = res.json;
      if (decoded is! Map<String, dynamic>) {
        throw const MangaJaNaiRemoteException('服务端响应不是合法的 JSON');
      }

      final health = RemoteHealth.fromJson(decoded);
      _cachedHealth = health;
      _cachedError = null;
      _cachedAt = DateTime.now();
      return health;
    } on MangaJaNaiRemoteException catch (e) {
      // 保留具体原因（401 / 非法 JSON 等），否则 TTL 窗口内只会重复抛「连接失败」。
      _cachedError = e.message;
      _cachedAt = DateTime.now();
      rethrow;
    } catch (e) {
      final message = '连接失败：$e';
      _cachedError = message;
      _cachedAt = DateTime.now();
      logger.w('MangaJaNai 远程探活失败：$baseUrl', error: e);
      throw MangaJaNaiRemoteException(message);
    }
  }

  /// 远程服务是否可用（探活通过即视为可用）。
  ///
  /// 与本地引擎的 `missingRequirements()` 语义对齐：空列表 = 就绪。
  static Future<List<String>> missingRequirements() async {
    try {
      final health = await probe();
      final missing = <String>[];
      final baseUrl = await configuredBaseUrl();
      if (health.authRequired) {
        final apiKey = (await RealSrSettings.loadMangaJaNaiRemoteApiKey())
            .trim();
        if (apiKey.isEmpty) {
          missing.add('服务端已开启鉴权，但未填写访问 Token');
        }
      }
      if (!health.cuda) {
        missing.add('服务端未启用 CUDA（${health.device}），超分会慢 20 倍以上');
      }
      if (!health.modelsReady) {
        missing.add(
          '服务端缺少 ${health.missingModels.length} 个模型文件'
          '（${health.missingModels.take(3).join(', ')}…）',
        );
      }
      logger.d('MangaJaNai 远程就绪：$baseUrl @ ${health.device}');
      return missing;
    } on MangaJaNaiRemoteException catch (e) {
      return [e.message];
    }
  }

  /// 远程服务是否可用。热路径（每张图超分前）会调用，故依赖 [_healthTtl] 缓存。
  static Future<bool> get isAvailable async =>
      (await missingRequirements()).isEmpty;

  /// 设置页的「测试连接」：强制刷新探活并返回结果，异常直接抛出。
  static Future<RemoteHealth> testConnection() => probe(force: true);

  /// 对单张图片执行超分，结果（WebP）写入 [outputPath]。
  ///
  /// [inputPath] 直接以**原始编码**上传（JPEG / PNG / WebP 均可），
  /// 不做任何转码 —— 见类文档第 1 条。
  ///
  /// [baseUrlOverride] 用于**本机常驻服务**：地址固定 `127.0.0.1`，不该读用户配置的
  /// 远程地址，也**不发送**远程 Token（本机服务按设计不开鉴权，多发一个 Key 无意义）。
  /// 同一份服务端代码跑在两种宿主上，所以请求格式完全一致 —— 这才是能复用的原因。
  static Future<void> upscale({
    required String inputPath,
    required String outputPath,
    required int scale,
    required int grayscaleThreshold,
    int quality = 90,
    String? baseUrlOverride,
  }) async {
    final isLocal = baseUrlOverride != null;
    final baseUrl = baseUrlOverride ?? await configuredBaseUrl();
    if (baseUrl == null) {
      throw const MangaJaNaiRemoteException('未配置远程服务器地址');
    }

    final inputFile = File(inputPath);
    if (!inputFile.existsSync()) {
      throw MangaJaNaiRemoteException('待超分图片不存在：$inputPath');
    }
    final bytes = await inputFile.readAsBytes();
    if (bytes.isEmpty) {
      throw MangaJaNaiRemoteException('待超分图片为空：$inputPath');
    }

    final stopwatch = Stopwatch()..start();
    try {
      final res =
          await WindHttp.direct(
            connectTimeout: _healthConnectTimeout,
            receiveTimeout: _upscaleTimeout,
          ).fetch(
            '$baseUrl/v1/upscale',
            method: 'POST',
            headers: {
              if (!isLocal) ...await _headers(),
              'Content-Type': 'application/octet-stream',
            },
            query: {
              'scale': '$scale',
              'threshold': '$grayscaleThreshold',
              'format': 'webp',
              'quality': '$quality',
            },
            body: bytes,
            timeout: _upscaleTimeout,
          );

      if (!res.ok) {
        throw MangaJaNaiRemoteException(_extractError(res));
      }
      if (res.body.isEmpty) {
        throw const MangaJaNaiRemoteException('服务端返回了空结果');
      }

      // 服务端在响应头里给出耗时拆分，记下来便于诊断「慢在排队还是慢在推理」。
      logger.d(
        'MangaJaNai 远程超分完成：${bytes.length ~/ 1024}KB -> '
        '${res.body.length ~/ 1024}KB，'
        'queue=${res.header('x-mjn-queue-ms') ?? '-'}ms '
        'gpu=${res.header('x-mjn-gpu-ms') ?? '-'}ms '
        'total=${res.header('x-mjn-total-ms') ?? '-'}ms '
        '（客户端 ${stopwatch.elapsedMilliseconds}ms）',
      );

      await File(outputPath).writeAsBytes(res.body, flush: true);
    } on MangaJaNaiRemoteException {
      rethrow;
    } catch (e) {
      logger.w('MangaJaNai 远程超分失败：$inputPath', error: e);
      throw MangaJaNaiRemoteException('远程超分失败：$e');
    }
  }

  /// 从错误响应里取出服务端的 `{"error": "..."}`，取不到就退回原文摘要。
  static String _extractError(FetchResponse res) {
    try {
      final decoded = res.json;
      if (decoded is Map && decoded['error'] is String) {
        final message = decoded['error'] as String;
        return res.status == 503 ? '服务端队列已满：$message' : message;
      }
    } catch (_) {
      // 响应不是 JSON，走下面的兜底
    }
    final text = res.text.trim();
    final brief = text.length > 200 ? '${text.substring(0, 200)}…' : text;
    return '服务端返回 HTTP ${res.status}${brief.isEmpty ? '' : '：$brief'}';
  }
}

// =========================================================
// JSON 取值辅助：服务端字段缺失 / 类型不符时退化到默认值
// =========================================================

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

String _asString(dynamic value, String fallback) =>
    value is String && value.isNotEmpty ? value : fallback;

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

bool _asBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.toLowerCase() == 'true';
  return false;
}

List<String> _asStringList(dynamic value) {
  if (value is List) {
    return [
      for (final item in value)
        if (item is String) item,
    ];
  }
  return const [];
}

List<int> _asIntList(dynamic value) {
  if (value is List) {
    return [
      for (final item in value)
        if (item is num) item.toInt(),
    ];
  }
  return const [];
}

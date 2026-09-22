import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';

/// 局域网里被发现的一台 mjn-service。
///
/// [baseUrl] 一律取**实际触达该服务的那个地址**，而不是服务端自报的 `host`：
/// 服务跑在 Docker / WSL 里时，它自己看到的地址是 172.x 的容器地址，手机根本连不上，
/// 而「我能连上它」这个事实本身就是最好的可达性证明。
class MjnDiscoveredServer {
  const MjnDiscoveredServer({
    required this.baseUrl,
    required this.host,
    required this.port,
    required this.instanceId,
    required this.name,
    required this.device,
    required this.authRequired,
    required this.token,
    required this.latency,
    required this.viaUdp,
  });

  /// 可直接写入设置项的地址，形如 `http://192.168.1.5:8765`。
  final String baseUrl;

  final String host;
  final int port;

  /// 服务端持久化的稳定标识。客户端靠它在 PC 换 IP 后认出「还是那台电脑」。
  final String instanceId;

  /// 服务端显示名（默认是主机名）。
  final String name;

  final String device;

  /// 服务端是否要求鉴权（`MJN_API_KEY` 非空）。
  final bool authRequired;

  /// 服务端随应答给出的 Token；仅在服务端显式开启 `MJN_DISCOVER_TOKEN=1` 时非空。
  final String? token;

  /// 发现耗时，用于「同一台机器被两条路径同时发现」时择优。
  final Duration latency;

  /// 是否来自 UDP 广播应答（否则是网段扫描）。
  final bool viaUdp;

  String get displayName => name.trim().isNotEmpty ? name.trim() : host;

  /// 去重键：优先用服务端稳定 id，这样同一台机器经 UDP 与扫描两条路被发现时能合并；
  /// 老服务端没有 id 时退回地址。
  String get dedupeKey =>
      instanceId.isNotEmpty ? instanceId : '$host:$port';

  /// 能否直接配对而无需用户输入 Token。
  bool get canPairSilently => !authRequired || (token?.isNotEmpty ?? false);
}

/// 局域网自动发现：让手机不用手输 `192.168.x.x:8765` 和 Token。
///
/// ## 为什么是两条路径，而不是一条
///
/// 客户端面对的服务端有两种完全不同的部署形态，而它们的可达性机制不同：
///
/// | 形态 | UDP 广播 | 网段扫描 |
/// |---|---|---|
/// | Windows 原生（Breeze 内置的 [MjnLocalService] 拉起） | ✅ 直接收得到 | ✅ |
/// | WSL / Docker 容器（经 portproxy 暴露） | ❌ NAT 命名空间隔离，Docker 的 UDP 端口映射也不转发广播包 | ✅ |
///
/// 只做广播的话，容器部署直接发现不了；只做扫描的话，每次要点 2–4 秒。
/// 所以两条并行跑、结果取并集：广播负责「快」，扫描负责「一定找得到」。
///
/// ## 扫描为什么不会把服务端打爆
///
/// 扫描先做 **TCP 端口探测**（`Socket.connect`，超时 [_tcpProbeTimeout]），
/// 只有端口真的开着才发 HTTP `/v1/info`。一个 /24 网段里最多一两个地址能走到
/// HTTP 那一步，所以绝大多数地址的成本只是一次被拒绝的 TCP 连接。
/// （这也是服务端要把 `/v1/info` 做成轻量端点的原因 —— 它是被"逐个地址打"的。）
class MjnDiscovery {
  MjnDiscovery._();

  /// UDP 探针魔数，与服务端 `PROBE_MAGIC` 一致。
  static const String probeMagic = 'MJN-DISCOVER/1';

  /// 服务端 UDP 发现端口的默认值，对应 `MJN_DISCOVER_PORT`。
  static const int defaultDiscoverPort = 8766;

  /// TCP 端口探测超时。
  ///
  /// 350 ms 是权衡：再短会在 WiFi 上因 ARP 未解析而漏掉真实目标（表现为"偶尔扫不到"），
  /// 再长则整轮扫描超过 2 秒。254 个地址 / [_scanConcurrency] 路并发 ≈ 1.4 s 最坏。
  static const Duration _tcpProbeTimeout = Duration(milliseconds: 350);

  /// 扫描并发数。定太高会触发家用 AP 的限速/丢包，反而更慢。
  static const int _scanConcurrency = 48;

  /// 单个地址上 HTTP `/v1/info` 的超时（TCP 已通，只等应用层响应）。
  static const Duration _infoTimeout = Duration(milliseconds: 1500);

  /// 监听 UDP 应答的时长。发两次探针（0 ms 与 350 ms），给丢包留一次重试机会。
  static const Duration _udpWindow = Duration(milliseconds: 1600);

  /// 跑一次发现，返回按发现延迟升序排好的服务列表。
  ///
  /// [onScanProgress] 用于界面展示进度，参数是 `(已探测地址数, 地址总数)`。
  /// UDP 路径没有进度概念（它是一次广播等应答），只由扫描路径驱动。
  static Future<List<MjnDiscoveredServer>> discover({
    int? httpPort,
    void Function(int done, int total)? onScanProgress,
  }) async {
    final startedAt = DateTime.now();
    final port = httpPort ?? await RealSrSettings.loadMjnServicePort();
    final found = <String, MjnDiscoveredServer>{};

    // 两条路径并行、写同一个 map（Dart 单线程，无需加锁）。
    await Future.wait<void>([
      _discoverViaUdp(port, found),
      _discoverViaScan(port, found, onScanProgress),
    ]);

    final list = found.values.toList()
      ..sort((a, b) => a.latency.compareTo(b.latency));
    logger.d(
      '局域网发现完成：${list.length} 个服务端，用时 ${DateTime.now().difference(startedAt).inMilliseconds}ms'
      '${list.isEmpty ? '' : '（${list.map((e) => e.baseUrl).join(', ')}）'}',
    );
    return list;
  }

  // =========================================================
  // 路径一：UDP 广播
  // =========================================================

  static Future<void> _discoverViaUdp(
    int httpPort,
    Map<String, MjnDiscoveredServer> out,
  ) async {
    RawDatagramSocket? socket;
    final done = Completer<void>();
    // 探针发送时刻，用于计算应答延迟。刻意做成局部变量而不是静态字段 ——
    // 静态字段会让并发或连续的两次 discover 互相污染时间基准。
    var sentAt = DateTime.now();
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final server = _parse(
          utf8.decode(datagram.data, allowMalformed: true),
          // 用**来源地址**而不是服务端自报的 host —— 见类文档与 [MjnDiscoveredServer.baseUrl]。
          reachedHost: datagram.address.address,
          httpPort: httpPort,
          latency: DateTime.now().difference(sentAt),
          viaUdp: true,
        );
        if (server != null) _merge(out, server);
      }, onError: (Object e) => logger.d('UDP 发现监听异常：$e'));

      final targets = await _broadcastTargets();
      final probe = Uint8List.fromList(utf8.encode(probeMagic));
      void sendAll() {
        for (final target in targets) {
          try {
            socket?.send(probe, target, defaultDiscoverPort);
          } catch (_) {
            // 某些网卡不支持广播（返回 EACCES / ENETUNREACH），跳过即可 —— 扫描兜底
          }
        }
      }

      sentAt = DateTime.now();
      sendAll();
      // 广播在 WiFi 上是不可靠的（无重传），补发一次显著提高命中率。
      Timer(const Duration(milliseconds: 350), sendAll);
      Timer(_udpWindow, () {
        if (!done.isCompleted) done.complete();
      });
    } catch (e) {
      // 绑定失败（如 Android 未授予网络权限）不该让整次发现失败，扫描仍会跑。
      logger.d('UDP 发现不可用，仅使用网段扫描：$e');
      if (!done.isCompleted) done.complete();
    }

    await done.future;
    socket?.close();
  }

  /// 广播目标：受限广播地址 + 每个网卡的定向广播地址。
  ///
  /// 两者都要：`255.255.255.255` 在部分 Android 设备/AP 上会被丢弃，
  /// 而定向广播（`192.168.1.255`）走的是路由表，可达性更稳定。
  static Future<List<InternetAddress>> _broadcastTargets() async {
    final seen = <String>{};
    final targets = <InternetAddress>[];

    void add(InternetAddress addr) {
      if (seen.add(addr.address)) targets.add(addr);
    }

    add(InternetAddress('255.255.255.255'));
    try {
      for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final addr in ni.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          // 按 /24 推算定向广播地址。家用/宿舍网络几乎都是 /24；
          // 掩码更宽的场合漏掉定向广播也无妨 —— `255.255.255.255` 与扫描仍能覆盖。
          add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    } catch (e) {
      logger.d('枚举网卡失败，仅使用受限广播地址：$e');
    }
    return targets;
  }

  // =========================================================
  // 路径二：网段扫描
  // =========================================================

  static Future<void> _discoverViaScan(
    int httpPort,
    Map<String, MjnDiscoveredServer> out,
    void Function(int done, int total)? onScanProgress,
  ) async {
    final hosts = await _localSubnetHosts();
    if (hosts.isEmpty) {
      logger.d('没有可扫描的局域网网段（可能未连接 WiFi）');
      return;
    }

    var cursor = 0;
    var done = 0;
    final total = hosts.length;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= hosts.length) return;
        final server = await _probeHost(hosts[index], httpPort);
        done++;
        if (server != null) _merge(out, server);
        if (done % 16 == 0 || done == total) {
          onScanProgress?.call(done, total);
        }
      }
    }

    await Future.wait<void>(
      List.generate(
        _scanConcurrency < total ? _scanConcurrency : total,
        (_) => worker(),
      ),
    );
    onScanProgress?.call(done, total);
  }

  /// 本机所在的 /24 网段里所有主机地址（不含自己）。
  ///
  /// 只认**私有网段**的 IPv4：手机上同时有蜂窝（`rmnet*`）、VPN（`tun*`）、
  /// 及各类虚拟网卡，把它们一并扫既慢又毫无意义（局域网服务不可能在公网地址上）。
  static Future<List<String>> _localSubnetHosts() async {
    final hosts = <String>[];
    final seen = <String>{};
    try {
      for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final addr in ni.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
          if (!_isPrivateIpv4(parts)) continue;
          if (!seen.add(prefix)) continue;
          for (var i = 1; i <= 254; i++) {
            final ip = '$prefix.$i';
            if (ip == addr.address) continue; // 自己不用探
            hosts.add(ip);
          }
        }
      }
    } catch (e) {
      logger.d('枚举网卡失败：$e');
    }
    return hosts;
  }

  /// 该地址所在的 /24 是否值得扫描。
  ///
  /// 只认私有网段（含 CGNAT —— Tailscale 这类组网会用到）：手机上同时有蜂窝
  /// （`rmnet*`）、VPN（`tun*`）与各类虚拟网卡，把它们一并扫既慢又毫无意义。
  /// 与 [_isLanAddress] 保持同一套网段判断，避免"能扫到却在校验时被丢弃"的怪状态。
  static bool _isPrivateIpv4(List<String> parts) {
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    return false;
  }

  /// 探测一个地址：先 TCP 试端口，通了再问 `/v1/info`。
  static Future<MjnDiscoveredServer?> _probeHost(String host, int port) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: _tcpProbeTimeout);
    } catch (_) {
      return null; // 绝大多数地址在这里就出局了，代价只是一次 TCP 被拒
    } finally {
      socket?.destroy();
    }

    final json = await _fetchInfo(host, port);
    if (json == null) return null;
    return _parseJson(
      json,
      reachedHost: host,
      httpPort: port,
      latency: stopwatch.elapsed,
      viaUdp: false,
    );
  }

  static Future<Map<String, dynamic>?> _fetchInfo(String host, int port) async {
    try {
      final res = await WindHttp.direct(
        connectTimeout: _tcpProbeTimeout,
        receiveTimeout: _infoTimeout,
      ).fetch(
        'http://$host:$port/v1/info',
        timeout: _infoTimeout,
      );
      if (!res.ok) return null;
      final decoded = res.json;
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  // =========================================================
  // 解析与合并
  // =========================================================

  static MjnDiscoveredServer? _parse(
    String payload, {
    required String reachedHost,
    required int httpPort,
    required Duration latency,
    required bool viaUdp,
  }) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return null;
      return _parseJson(
        decoded,
        reachedHost: reachedHost,
        httpPort: httpPort,
        latency: latency,
        viaUdp: viaUdp,
      );
    } catch (_) {
      return null; // 同端口上可能有别的程序在应答无可解析的内容
    }
  }

  static MjnDiscoveredServer? _parseJson(
    Map<String, dynamic> json, {
    required String reachedHost,
    required int httpPort,
    required Duration latency,
    required bool viaUdp,
  }) {
    // 识别屏障：8765 上完全可能是另一个 web 服务，靠 service 字段排除掉。
    if (json['service'] != 'mjn-upscale') return null;

    // 只接受私有网段来源。
    //
    // 发现是"局域网内谁应答就信谁"，所以来源本身必须被约束在局域网里 ——
    // 否则某个能投递广播/应答的设备（或 NAT 后的公网服务）可以把客户端引到
    // 任意地址去。而超分请求会把**用户正在看的漫画原图**整张送出去，
    // 这既是被迫的流量代付，也是隐私外泄。宁可漏发现，不可连错地方。
    if (!_isLanAddress(reachedHost)) {
      logger.w('丢弃非局域网来源的发现应答：$reachedHost');
      return null;
    }

    final port = _asInt(json['port'], httpPort);
    if (port < 1 || port > 65535) return null;

    // Token 长度做个上限：它会被存进设置并作为请求头发出去。
    final rawToken = (json['token'] as String?)?.trim();
    final token = (rawToken == null || rawToken.isEmpty)
        ? null
        : (rawToken.length > 256 ? null : rawToken);

    return MjnDiscoveredServer(
      baseUrl: 'http://$reachedHost:$port',
      host: reachedHost,
      port: port,
      instanceId: _sanitizeInstanceId(json['instance_id']),
      name: _truncate((json['name'] as String?)?.trim() ?? '', 64),
      device: _truncate((json['device'] as String?)?.trim() ?? '', 64),
      authRequired: json['auth_required'] == true,
      token: token,
      latency: latency,
      viaUdp: viaUdp,
    );
  }

  /// 地址是否落在本机所在的局域网里（私网或回环）。
  ///
  /// 回环也要放行：Windows 上由 Breeze 自己拉起的本机服务就在 127.0.0.1，
  /// 虽然它走的是 [MjnLocalService] 那条不经发现的路径，但将来若有本机发现入口，
  /// 这里不该成为障碍。
  static bool _isLanAddress(String host) {
    if (host.isEmpty || host.length > 45) return false;
    if (host == 'localhost') return true;
    final parts = host.split('.');
    if (parts.length != 4) {
      // 非 IPv4 字面量：只允许 IPv6 回环，其余（含域名）一律拒绝 ——
      // 域名意味着解析权在 DNS 手里，等于把"连到哪儿"交给外部。
      return host == '::1';
    }
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    final c = int.tryParse(parts[2]);
    final d = int.tryParse(parts[3]);
    if (a == null || b == null || c == null || d == null) return false;
    for (final v in [a, b, c, d]) {
      if (v < 0 || v > 255) return false;
    }
    if (a == 127) return true;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT / Tailscale
    return false;
  }

  /// `instance_id` 只当标识用，约束成十六进制短串 —— 服务端生成的就是这个形状。
  static String _sanitizeInstanceId(dynamic value) {
    final raw = (value is String ? value : '').trim();
    if (raw.isEmpty || raw.length > 64) return '';
    for (final unit in raw.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLower = unit >= 0x61 && unit <= 0x66;
      final isUpper = unit >= 0x41 && unit <= 0x46;
      if (!isDigit && !isLower && !isUpper) return '';
    }
    return raw;
  }

  static String _truncate(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  /// 合并结果：同一台机器只保留**更快**的那条记录。
  ///
  /// 典型场景是 UDP 与扫描同时命中同一台电脑 —— UDP 通常更快（亚秒级），
  /// 于是列表里显示的是 UDP 那条，但地址两者一致，不影响配对。
  static void _merge(
    Map<String, MjnDiscoveredServer> out,
    MjnDiscoveredServer server,
  ) {
    final existing = out[server.dedupeKey];
    if (existing == null || server.latency < existing.latency) {
      out[server.dedupeKey] = server;
    }
  }
}

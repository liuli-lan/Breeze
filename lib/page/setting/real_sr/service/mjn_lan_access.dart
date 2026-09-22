import 'dart:convert';
import 'dart:io';

import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/mjn_discovery.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';

/// 局域网可达性状态。
enum MjnLanAccessState {
  /// 还没检测过。
  unknown,

  /// 手机现在就能连上（局域网地址能访问到本机服务）。
  reachable,

  /// 本机服务没在跑。
  ///
  /// 必须与 [blocked] 分开：服务没起时「局域网不通」跟防火墙毫无关系，
  /// 把用户引去放行端口只会白忙一场。
  serviceDown,

  /// 回环通、局域网地址不通 —— 最常见的原因是 Windows 防火墙缺入站规则。
  blocked,

  /// 本机没有可用的私网 IPv4（没连网，或只有公网地址）。
  noLanAddress,
}

/// 一次局域网探测的结果。
class MjnLanProbeResult {
  const MjnLanProbeResult(this.state, {this.reachableAddress});

  final MjnLanAccessState state;

  /// 实测可用的那个地址；仅当 [state] 为 `reachable` 时非空。
  final String? reachableAddress;

  bool get isReachable => state == MjnLanAccessState.reachable;
}

/// 本机服务对局域网的可达性：检测 + 一键放行。
///
/// ## 为什么需要它
///
/// 目标是「别人装完 Breeze，手机就能调他的电脑超分」。这条路上唯一会静默失败的
/// 一环就是 Windows 防火墙：服务绑了 `0.0.0.0`，首次监听时系统会弹一次
/// 「允许访问」，但用户点「取消」、忽略弹窗、或机器上有组策略，入站规则就永久缺失。
/// 之后的表现是**手机搜也搜不到、连也连不上**，而用户完全不知道原因 ——
/// 他只会觉得"这功能是坏的"。
///
/// 所以这里做两件事：把真实可达性**探出来**（而不是猜），以及给一个
/// **点一下就能修好**的入口。
///
/// ## 判据是探测，不是查规则
///
/// [probe] 用的是「从局域网地址访问自己的服务」，而不是「防火墙里有没有我们的规则」。
/// 因为用户完全可能手动在防火墙里允许了 `Breeze.exe` —— 那种情况下没有我们的规则，
/// 可达性却完全正常。[hasFirewallRule] 只用来辅助说明。
class MjnLanAccess {
  MjnLanAccess._();

  /// 防火墙规则名。**保持纯 ASCII**：它会被拼进提权执行的 PowerShell 脚本，
  /// 而 Windows PowerShell 5.1 处理非 ASCII 时按 ANSI 解码，中文会变成乱码
  /// （本项目的打包脚本上踩过同类问题）。
  static const String tcpRuleName = 'Breeze MangaJaNai Upscale (TCP)';
  static const String udpRuleName = 'Breeze MangaJaNai Discovery (UDP)';

  /// 本机自连的探测超时。
  ///
  /// 防火墙拦截表现为**超时**（静默丢包）而不是连接被拒，所以给得太短会误判成"可达"；
  /// 但每个地址都等满又会很慢 —— 因此一旦有一个地址通了就立刻返回。
  static const Duration _probeTimeout = Duration(milliseconds: 900);
  static const Duration _probeConnectTimeout = Duration(milliseconds: 600);

  // =========================================================
  // 地址枚举
  // =========================================================

  /// 列出本机的私网 IPv4（可能不止一个：有线 + 无线 + 虚拟网卡）。
  static Future<List<String>> localAddresses() async {
    final found = <String>[];
    try {
      for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final addr in ni.addresses) {
          if (isLanIpv4(addr.address) && !found.contains(addr.address)) {
            found.add(addr.address);
          }
        }
      }
    } catch (e) {
      logger.d('枚举网卡失败：$e');
    }
    return found;
  }

  /// 该地址是否属于本机所在的局域网。
  ///
  /// 与发现模块用同一套网段判断，但**额外排除 169.254/16**：那是 DHCP 失败时
  /// 系统自配的地址（APIPA），手机绝无可能连上，把它当作"可用地址"展示只会误导。
  static bool isLanIpv4(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT / Tailscale
    return false;
  }

  // =========================================================
  // 检测
  // =========================================================

  /// 一次探测的结果。
  ///
  /// 刻意把「实测可用的地址」一起带回来，而不是让调用方从网卡列表里挑第一个：
  /// 本机同时有以太网、WSL 的 vEthernet、可能的 TUN 设备，**列表顺序与手机能否
  /// 连上毫无关系** —— 直接把 `192.168.80.1`（vEthernet 网关）展示给用户，
  /// 他会照着填一个永远连不上的地址。
  static Future<MjnLanProbeResult> probe({int? port}) async {
    final addresses = await localAddresses();
    if (addresses.isEmpty) {
      return const MjnLanProbeResult(MjnLanAccessState.noLanAddress);
    }

    final targetPort = port ?? await RealSrSettings.loadMjnServicePort();

    // 先确认服务本身活着。这一步不能省 —— 少了它，服务没启动会被判成
    // "被防火墙拦了"，用户照着提示去放行，问题依旧。
    if (!await _reachable('127.0.0.1', targetPort)) {
      return const MjnLanProbeResult(MjnLanAccessState.serviceDown);
    }

    // 逐个实打。这一步同时回答了「地址选对没 / 服务在监听没 / 防火墙放行没」
    // 三个问题 —— 只看网卡列表的话，这三种失败长得一模一样。
    for (final address in addresses) {
      if (await _reachable(address, targetPort)) {
        return MjnLanProbeResult(
          MjnLanAccessState.reachable,
          reachableAddress: address,
        );
      }
    }
    return const MjnLanProbeResult(MjnLanAccessState.blocked);
  }

  /// 从 [host] 探一次本机服务。
  ///
  /// 用最轻的 `/v1/info` 并校验 `service` 字段 —— 8765 上完全可能是别的程序，
  /// 那样「端口通」不代表「我们的服务可达」。
  static Future<bool> _reachable(String host, int port) async {
    try {
      final res =
          await WindHttp.direct(
            connectTimeout: _probeConnectTimeout,
            receiveTimeout: _probeTimeout,
          ).fetch(
            'http://$host:$port/v1/info',
            timeout: _probeTimeout,
          );
      if (!res.ok) return false;
      final decoded = res.json;
      return decoded is Map && decoded['service'] == 'mjn-upscale';
    } catch (_) {
      return false;
    }
  }

  // =========================================================
  // 防火墙
  // =========================================================

  /// 通过 UAC 提权添加入站规则（TCP 服务端口 + UDP 发现端口）。
  ///
  /// **返回 true 只代表提权进程正常退出**，不代表规则已经生效 ——
  /// 调用方必须重新 [probe] 一次来确认真实可达性。用户可能在 UAC 弹窗上点了「否」，
  /// 也可能被安全软件拦下，这些都不会让退出码变成非 0。
  static Future<bool> allowThroughFirewall({
    required int httpPort,
    int discoverPort = MjnDiscovery.defaultDiscoverPort,
  }) async {
    if (!Platform.isWindows) return false;

    // 端口会被拼进提权执行的脚本，**必须先钳到合法区间**。
    // 这是本模块唯一的注入面：端口值来自用户设置，不能假定它干净。
    if (!_validPort(httpPort) ||
        (discoverPort != 0 && !_validPort(discoverPort))) {
      logger.w('拒绝为非法的端口添加防火墙规则：http=$httpPort udp=$discoverPort');
      return false;
    }

    // 先删后建：端口改过之后重跑能纠正，而不是留下同名旧规则把新端口挡在外面。
    final script = StringBuffer()
      ..writeln(
        "Remove-NetFirewallRule -DisplayName '$tcpRuleName' -ErrorAction SilentlyContinue",
      )
      ..writeln(
        "New-NetFirewallRule -DisplayName '$tcpRuleName' -Direction Inbound "
        '-Action Allow -Protocol TCP -LocalPort $httpPort -Profile Any '
        '-ErrorAction Stop | Out-Null',
      );
    if (discoverPort != 0) {
      script
        ..writeln(
          "Remove-NetFirewallRule -DisplayName '$udpRuleName' -ErrorAction SilentlyContinue",
        )
        ..writeln(
          "New-NetFirewallRule -DisplayName '$udpRuleName' -Direction Inbound "
          '-Action Allow -Protocol UDP -LocalPort $discoverPort -Profile Any '
          '-ErrorAction Stop | Out-Null',
        );
    }
    script.writeln('Write-Output "MJN_FW_OK"');

    // 两层都走 -EncodedCommand，彻底避开引号嵌套与编码问题（见 [_encodeForPowerShell]）。
    final inner = _encodeForPowerShell(script.toString());
    final launcher =
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -WindowStyle Hidden "
        "-ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand','$inner'";
    final launcherEncoded = _encodeForPowerShell(launcher);

    try {
      final result = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        launcherEncoded,
      ]);
      if (result.exitCode != 0) {
        // UAC 被拒时 Start-Process 会抛「操作已被用户取消」，外层退出码非 0。
        logger.w(
          '添加防火墙规则未成功（退出码 ${result.exitCode}）：${result.stderr}',
        );
        return false;
      }
      logger.d(
        '已请求添加防火墙入站规则：TCP $httpPort'
        '${discoverPort == 0 ? '' : ' / UDP $discoverPort'}',
      );
      return true;
    } catch (e, s) {
      logger.w('调用提权进程失败', error: e, stackTrace: s);
      return false;
    }
  }

  /// 我们加的 TCP 规则是否存在且启用。
  ///
  /// 只用于界面说明 —— 真正的判据始终是 [probe] 的探测结果。用户也可能手动在
  /// 防火墙里允许了 `Breeze.exe`，那样没有我们的规则却依然完全可达。
  static Future<bool> hasFirewallRule({int? port}) async {
    if (!Platform.isWindows) return false;
    final targetPort = port ?? await RealSrSettings.loadMjnServicePort();
    if (!_validPort(targetPort)) return false;

    final script =
        "Get-NetFirewallRule -DisplayName '$tcpRuleName' -ErrorAction SilentlyContinue | "
        "Where-Object { \$_.Enabled -eq 'True' -and \$_.Direction -eq 'Inbound' "
        "-and \$_.LocalPort -eq '$targetPort' } | "
        'Measure-Object | Select-Object -ExpandProperty Count';
    try {
      final encoded = _encodeForPowerShell(script);
      final result = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encoded,
      ]);
      if (result.exitCode != 0) return false;
      final match = RegExp(r'(\d+)').firstMatch('${result.stdout}');
      return match != null && int.parse(match.group(1)!) > 0;
    } catch (_) {
      return false;
    }
  }

  static bool _validPort(int port) => port >= 1024 && port <= 65535;

  /// 把脚本编码成 PowerShell `-EncodedCommand` 需要的格式：**UTF-16LE 的 Base64**。
  ///
  /// 用它是为了绕开两层引号地狱与编码问题：脚本里含单引号与中文，
  /// 而 Windows PowerShell 5.1 从命令行接收非 ASCII 时按 ANSI 解码，中文会乱码。
  /// Base64 之后整条命令是纯 ASCII，既不需要转义，也不受代码页影响。
  static String _encodeForPowerShell(String script) {
    final bytes = <int>[];
    for (final unit in script.codeUnits) {
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return base64Encode(bytes);
  }
}

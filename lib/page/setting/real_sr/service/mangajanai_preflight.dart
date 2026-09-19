import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';

/// NVIDIA 显卡信息（由 `nvidia-smi` 解析而来）。
class MangaJaNaiGpuInfo {
  const MangaJaNaiGpuInfo({
    required this.name,
    this.driverVersion,
    this.totalMemoryMiB,
  });

  final String name;
  final String? driverVersion;
  final int? totalMemoryMiB;

  @override
  String toString() =>
      '$name${driverVersion == null ? '' : '（驱动 $driverVersion）'}';
}

/// 安装前的环境预检结论。
///
/// 依据方案 §5 第 2/3 条与 §10.5：**开装前就把硬门槛如实告知**，
/// 而不是让用户下载到 80% 才发现不适合。
class MangaJaNaiPreflightReport {
  const MangaJaNaiPreflightReport({
    required this.targetPath,
    required this.freeBytes,
    required this.gpu,
    required this.nvidiaSmiAvailable,
  });

  /// 引擎将安装到的目录（用于展示「哪个盘」）。
  final String targetPath;

  /// 目标盘剩余空间；null 表示探测失败（此时不阻断，只提示）。
  final int? freeBytes;

  /// 检测到的 NVIDIA 显卡；null 表示没检测到。
  final MangaJaNaiGpuInfo? gpu;

  /// `nvidia-smi` 是否可用。与 [gpu] 的区别：false 通常意味着「没装驱动或没 N 卡」。
  final bool nvidiaSmiAvailable;

  /// 官方安装所需的空间（方案 §10：装完约 6 GB，峰值约 10 GB）。
  static const int requiredBytes = 10 * 1024 * 1024 * 1024;

  bool get hasNvidiaGpu => gpu != null;

  /// 磁盘是否够用。探测失败（null）时**不判为不足** —— 宁可放行也不要
  /// 因为一次 PowerShell 调用失败就把用户挡在门外。
  bool get diskOk => freeBytes == null || freeBytes! >= requiredBytes;

  /// 磁盘空间不足的缺口（字节）；够用时为 0。
  int get missingBytes {
    final free = freeBytes;
    if (free == null || free >= requiredBytes) return 0;
    return requiredBytes - free;
  }

  /// 目标盘盘符（`C:` 形式），用于文案。
  String get driveLabel {
    final root = p.rootPrefix(targetPath);
    return root.isEmpty ? targetPath : root;
  }
}

/// 安装前预检：磁盘空间 + NVIDIA 显卡。
///
/// 两者都只用系统自带手段探测（PowerShell / nvidia-smi），**不额外引入依赖**，
/// 且失败一律降级为「未知」而不是「不通过」：预检的目的是避免白下 4 GB，
/// 不是给用户设卡。
class MangaJaNaiPreflight {
  MangaJaNaiPreflight._();

  /// nvidia-smi 查询字段（逗号分隔，`noheader` 便于直接解析）。
  static const String _smiQuery = 'name,driver_version,memory.total';

  /// 探测 NVIDIA 显卡。
  ///
  /// 先试 PATH 上的 `nvidia-smi`（装了驱动的机器都会把
  /// `C:\Windows\System32` 加进 PATH），再试 System32 绝对路径。
  static Future<({MangaJaNaiGpuInfo? gpu, bool smiAvailable})>
  detectNvidiaGpu() async {
    final candidates = <String>[
      'nvidia-smi',
      if (Platform.environment['SystemRoot'] != null)
        p.join(
          Platform.environment['SystemRoot']!,
          'System32',
          'nvidia-smi.exe',
        ),
    ];

    for (final executable in candidates) {
      try {
        final result = await Process.run(executable, [
          '--query-gpu=$_smiQuery',
          '--format=csv,noheader',
        ], runInShell: false).timeout(const Duration(seconds: 15));
        if (result.exitCode != 0) continue;
        final gpu = parseNvidiaSmi('${result.stdout}');
        // 命令能跑通即视为有驱动；个别机器上查询不到 GPU 时会返回空行。
        return (gpu: gpu, smiAvailable: true);
      } on Object catch (e) {
        logger.d('nvidia-smi 探测失败（$executable）：$e');
      }
    }

    return (gpu: null, smiAvailable: false);
  }

  /// 解析 `nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader`。
  ///
  /// 输出形如 `NVIDIA GeForce RTX 4070 SUPER, 616.56, 12282 MiB`（多卡多行，取第一行）。
  static MangaJaNaiGpuInfo? parseNvidiaSmi(String stdout) {
    for (final line in stdout.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(',').map((e) => e.trim()).toList();
      if (parts.isEmpty || parts.first.isEmpty) continue;
      return MangaJaNaiGpuInfo(
        name: parts.first,
        driverVersion: parts.length > 1 && parts[1].isNotEmpty
            ? parts[1]
            : null,
        totalMemoryMiB: parts.length > 2 ? parseMemoryMiB(parts[2]) : null,
      );
    }
    return null;
  }

  /// 解析 `12282 MiB` / `8192MiB` / `12282` 形式的显存值。
  static int? parseMemoryMiB(String raw) {
    final match = RegExp(r'(\d+)').firstMatch(raw.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// 查询 [path] 所在磁盘的剩余空间（字节）；失败返回 null。
  ///
  /// 用 `Get-PSDrive` 而不是 `Win32_LogicalDisk`：后者需要在命令行参数里嵌引号，
  /// 经 Dart 的进程参数转义后容易出错，而 `Get-PSDrive -Name C` 完全不需要引号。
  static Future<int?> freeSpaceBytes(String path) async {
    final root = p.rootPrefix(path);
    final drive = root.replaceAll(RegExp(r'[\\/:]'), '');
    if (drive.isEmpty) return null;

    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-PSDrive -Name $drive).Free',
      ], runInShell: false).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) return null;
      return parseFreeSpace('${result.stdout}');
    } on Object catch (e) {
      logger.d('磁盘剩余空间探测失败：$e');
      return null;
    }
  }

  /// 解析 PowerShell 输出的字节数（可能带千位分隔符或小数）。
  static int? parseFreeSpace(String stdout) {
    final cleaned = stdout.trim().replaceAll(RegExp(r'[,\s]'), '');
    if (cleaned.isEmpty) return null;
    return int.tryParse(cleaned);
  }

  /// 完整预检。
  static Future<MangaJaNaiPreflightReport> check({
    required String targetPath,
  }) async {
    final results = await Future.wait([
      freeSpaceBytes(targetPath),
      detectNvidiaGpu(),
    ]);
    return MangaJaNaiPreflightReport(
      targetPath: targetPath,
      freeBytes: results[0] as int?,
      gpu: (results[1] as ({MangaJaNaiGpuInfo? gpu, bool smiAvailable})).gpu,
      nvidiaSmiAvailable:
          (results[1] as ({MangaJaNaiGpuInfo? gpu, bool smiAvailable}))
              .smiAvailable,
    );
  }
}

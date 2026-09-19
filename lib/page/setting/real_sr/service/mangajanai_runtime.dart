import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_bootstrap.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_downloader.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_engine.dart';
import 'package:zephyr/page/setting/real_sr/service/mjn_local_service.dart';

/// Breeze 托管的 MangaJaNai 运行环境（`<files>/mangajanai/`）的部署入口。
///
/// ## 与 `MangaJaNaiBootstrap` 的分工
///
/// - [MangaJaNaiBootstrap]：三条通道的**实现** —— ① 在线分阶段安装、③ 导入
///   离线压缩包（含内容校验与整体替换）、删除。本类的常量（[manualDownloadUrl]）
///   与校验器（`MangaJaNaiArchiveValidator`）也源自它。
/// - 本类是**编排层**：每个动作之前先停掉常驻服务（见下），之后再交回 Bootstrap。
///
/// ## 为什么安装/导入/删除前必须先停常驻服务
///
/// 常驻服务是用托管环境里的 `python.exe` 拉起来的，torch 还会持续持有模型文件。
/// Windows 上**删除或覆盖被占用的文件会直接失败**（不像 Linux 可以 unlink 后继续）。
/// 所以这三个动作都先 `MjnLocalService.stop()`：先关闭 stdin 让服务自我了结，
/// 宽限期内没退就强杀。用户完成后再点一次「检测 / 启动」即可重新拉起服务。
///
/// ## 目录布局（与 GUI 安装同构）
///
/// ```
/// <files>/mangajanai/
/// ├── python/python/python.exe      # 嵌入式 Python + 依赖 + torch
/// ├── backend/src/run_upscale.py    # chaiNNer 后端（CLI 入口）
/// ├── backend/ImageMagick/*.icc     # ICC profile，run_upscale 从 ../ImageMagick 读
/// ├── models/                       # 16 个链模型
/// └── service/                      # 常驻服务代码 + 日志 + 作业目录（运行时自行释放）
/// ```
class MangaJaNaiRuntime {
  MangaJaNaiRuntime._();

  /// 离线包直链（② 手动下载用），与 Bootstrap 的发布渠道同源。
  static const String manualDownloadUrl = MangaJaNaiBootstrap.manualArchiveUrl;

  /// 运行环境根目录（与 [MangaJaNaiBootstrap] 的安装目录一致）。
  static Future<String> installRoot() => MangaJaNaiBootstrap.installRoot();

  /// 托管运行环境是否**完整**就绪（[missingParts] 为空）。
  static Future<bool> get isReady async => (await missingParts()).isEmpty;

  /// 校验托管运行环境，返回缺失项描述；空列表表示通过。
  ///
  /// 与导入流程共用一个校验器（`MangaJaNaiArchiveValidator`）：设置页用它决定
  /// ① 通道显示「已就绪」还是「尚未安装」。注意用 [MangaJaNaiArchiveValidator
  /// .validateComplete]（全量语义）而不是 `validate`（部分补齐语义）——
  /// 就绪判定没有「部分补齐」可言。
  static Future<List<String>> missingParts() async =>
      MangaJaNaiArchiveValidator.validateComplete(await installRoot());

  /// 在线安装运行环境（① 通道），先停服务再调 Bootstrap。
  static Future<void> install({
    MangaJaNaiInstallProgress? onProgress,
    MangaJaNaiCancelToken? cancelToken,
    MangaJaNaiDownloadSource source = MangaJaNaiDownloadSource.auto,
    MangaJaNaiMirrorConfig mirrors = MangaJaNaiMirrorConfig.defaults,
  }) async {
    await MjnLocalService.instance.stop();
    await MangaJaNaiBootstrap.install(
      onProgress: onProgress,
      cancelToken: cancelToken,
      source: source,
      mirrors: mirrors,
    );
  }

  /// 删除托管运行环境（不影响本机 GUI 安装），先停服务再删。
  static Future<void> uninstall() async {
    await MjnLocalService.instance.stop();
    await MangaJaNaiBootstrap.uninstall();
    logger.d('已删除 Breeze 托管的 MangaJaNai 运行环境');
  }

  /// 导入离线压缩包（③ 通道），先停服务再调 Bootstrap。
  ///
  /// 校验不通过**不会**改动现有安装（Bootstrap 内部是「先全校验，再整体替换」），
  /// 因此这里不需要额外的确认步骤。
  static Future<void> importArchive(
    String archivePath, {
    MangaJaNaiInstallProgress? onProgress,
    MangaJaNaiCancelToken? cancelToken,
  }) async {
    await MjnLocalService.instance.stop();
    await MangaJaNaiBootstrap.importArchive(
      archivePath,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }
}

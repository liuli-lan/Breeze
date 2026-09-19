import 'package:material_ui/material_ui.dart';

/// 一组部署通道瓦片的文案。
///
/// 三通道（① 自动下载 ② 手动下载 ③ 导入压缩包）的**行为**在「内置 NCNN 模型」
/// 与「MangaJaNai 运行环境」之间完全一致，差别只在称呼（「模型」vs「运行环境」）
/// 与直链来源，因此文案由调用方注入 —— 组件本身不读 i18n，避免两套名词在这里
/// 混成一句话。
class DeployChannelTexts {
  const DeployChannelTexts({
    required this.busyTitle,
    required this.readyTitle,
    required this.deleteAction,
    required this.reinstallAction,
    required this.notReadyTitle,
    required this.notReadySubtitle,
    required this.installAction,
    required this.manualTitle,
    required this.manualUnsupported,
    required this.openUrlAction,
    required this.importTitle,
    required this.importSubtitle,
    required this.importAction,
  });

  /// ① 正在下载/安装。
  final String busyTitle;

  /// ① 已就绪。
  final String readyTitle;

  /// ① 已就绪时的两个动作。
  final String deleteAction;
  final String reinstallAction;

  /// ① 未安装。
  final String notReadyTitle;
  final String notReadySubtitle;
  final String installAction;

  /// ② 手动下载。
  final String manualTitle;

  /// ② 当前平台不支持时的说明。
  final String manualUnsupported;

  /// ② 的「打开链接」。
  final String openUrlAction;

  /// ③ 导入压缩包。
  final String importTitle;
  final String importSubtitle;
  final String importAction;
}

/// 部署通道瓦片组：① 自动下载 → ② 手动下载 → ③ 导入压缩包。
///
/// 三种通道缺一不可，各自解决一类用户：
/// - ① 正常联网用户，点一下走完；
/// - ② 自动下载反复失败（镜像/代理/下载器场景），给出直链自己去下；
/// - ③ **完全离线**：从别人那里拷来压缩包导入。这也是唯一能绕过
///   数 GB 在线下载的路径（包由用户自己获取，不构成 Breeze 再分发）。
///
/// 组件只负责呈现与回调分发，具体下载/校验/安装逻辑留在各自的服务类里
/// （内置模型是 `RealSrSuperResolution`，运行环境是 `MangaJaNaiRuntime`）。
class DeployChannelTiles extends StatelessWidget {
  const DeployChannelTiles({
    super.key,
    required this.texts,
    required this.ready,
    required this.downloading,
    required this.statusText,
    required this.manualDownloadUrl,
    required this.onDownload,
    required this.onDelete,
    required this.onImport,
    required this.onOpenManualDownload,
    this.progress,
    this.importing = false,
    this.onCancel,
    this.cancelLabel,
    this.importStatusText = '',
  });

  final DeployChannelTexts texts;

  /// 目标物（模型 / 运行环境）当前是否已就绪。
  final bool ready;

  /// ① 是否正在自动下载/安装。
  final bool downloading;

  /// ① 的下载进度，0..1；null 表示进度不可统计（显示不确定进度条）。
  final double? progress;

  /// ① 中的一行细节（阶段文案、MB 数、pip 输出行等），可为空。
  final String statusText;

  /// ② 的直链；null 表示当前平台不支持手动下载。
  final String? manualDownloadUrl;

  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onImport;

  /// ② 的「打开链接」；由调用方负责打开与失败提示（需要 i18n 与 toast）。
  final VoidCallback onOpenManualDownload;

  /// ③ 是否正在导入。
  final bool importing;

  /// ① / ③ 进行中的「取消」动作；为 null 则不支持取消。
  ///
  /// 取消的语义由调用方实现（例如给安装器一个 `MangaJaNaiCancelToken`），
  /// 组件只负责把它摆到进行中的瓦片上。
  final VoidCallback? onCancel;

  /// 「取消」按钮文案（[onCancel] 非空时必须提供）。
  final String? cancelLabel;

  /// ③ 进行中的一行细节（如「正在解压离线包…」）；为空时不占位。
  ///
  /// 导入离线包动辄数分钟，没有这一行用户会以为界面卡死。
  final String importStatusText;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDownloadTile(context),
        _buildManualDownloadTile(),
        _buildImportTile(),
      ],
    );
  }

  Widget _buildDownloadTile(BuildContext context) {
    if (downloading) {
      final percent = progress == null
          ? null
          : '${(progress! * 100).toStringAsFixed(1)}%';
      // 细节行：阶段文案与百分比按行拼接，两者都没有时不占位。
      final details = <String>[if (statusText.isNotEmpty) statusText, ?percent];
      return ListTile(
        leading: const Icon(Icons.downloading_outlined),
        title: Text(texts.busyTitle),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(details.join('\n')),
            ],
          ],
        ),
        // 取消做成 trailing 动作：进行中也只有它能立刻打断（杀进程 / 断连接）。
        trailing: (onCancel != null && cancelLabel != null)
            ? TextButton(onPressed: onCancel, child: Text(cancelLabel!))
            : null,
      );
    }

    if (ready) {
      return ListTile(
        leading: Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(texts.readyTitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: onDelete, child: Text(texts.deleteAction)),
            TextButton(
              onPressed: onDownload,
              child: Text(texts.reinstallAction),
            ),
          ],
        ),
      );
    }

    return ListTile(
      leading: const Icon(Icons.warning_amber_rounded),
      title: Text(texts.notReadyTitle),
      subtitle: Text(texts.notReadySubtitle),
      trailing: ElevatedButton(
        onPressed: onDownload,
        child: Text(texts.installAction),
      ),
    );
  }

  Widget _buildManualDownloadTile() {
    final url = manualDownloadUrl;
    if (url == null) {
      return ListTile(
        leading: const Icon(Icons.open_in_browser_outlined),
        title: Text(texts.manualTitle),
        subtitle: Text(texts.manualUnsupported),
      );
    }
    return ListTile(
      leading: const Icon(Icons.open_in_browser_outlined),
      title: Text(texts.manualTitle),
      subtitle: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: TextButton(
        onPressed: onOpenManualDownload,
        child: Text(texts.openUrlAction),
      ),
    );
  }

  Widget _buildImportTile() {
    return ListTile(
      leading: const Icon(Icons.file_open_outlined),
      title: Text(texts.importTitle),
      subtitle: Text(
        importing && importStatusText.isNotEmpty
            ? '${texts.importSubtitle}\n$importStatusText'
            : texts.importSubtitle,
      ),
      trailing: importing
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onCancel != null && cancelLabel != null) ...[
                  TextButton(onPressed: onCancel, child: Text(cancelLabel!)),
                  const SizedBox(width: 12),
                ],
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            )
          : TextButton(onPressed: onImport, child: Text(texts.importAction)),
    );
  }
}

import 'dart:async';

import 'package:zephyr/network/http/picture/picture.dart';
import 'package:zephyr/page/comic_read/json/common_ep_info_json/common_ep_info_json.dart';
import 'package:zephyr/page/comic_read/widgets/modes/read_mode_utils.dart';
import 'package:zephyr/type/enum.dart';

/// 负责把当前阅读位置之后的图片提前写入图片缓存。
///
/// 预加载只负责网络/文件缓存，不直接创建图片 Widget，避免把大量图片加入
/// 当前页面的布局树；真正显示时仍由阅读模式 Widget 负责加载和布局。
///
/// 各图片的预取互不等待（fire-and-forget）：超分不阻塞预取队列，否则
/// 后一页要等前一页的超分完成才开始下载，整个预取队列被串行卡死。
/// 同一张图的重复预取由 [_requestedKeys] 去重；超分调度器内部另有
/// 同路径去重兜底。
class ReaderImagePrefetchController {
  final Set<String> _requestedKeys = <String>{};
  bool _disposed = false;

  Future<void> prefetch({
    required List<ReadModeEntry> entries,
    required String comicId,
    required String from,
    required int count,
  }) async {
    if (_disposed || count <= 0 || entries.isEmpty) return;

    for (final entry in entries.take(count)) {
      if (_disposed) return;
      final doc = entry.doc;
      final chapterId = entry.chapterId;
      if (entry.type != ReadModeEntryType.image ||
          doc == null ||
          chapterId == null ||
          chapterId.isEmpty) {
        continue;
      }

      final resolvedChapterId = doc.storageChapterId.trim().isNotEmpty
          ? doc.storageChapterId
          : chapterId;
      final key = _buildKey(
        from: from,
        comicId: comicId,
        chapterId: resolvedChapterId,
        path: doc.path,
      );
      if (!_requestedKeys.add(key)) continue;

      unawaited(
        _prefetchOne(
          key: key,
          from: from,
          comicId: comicId,
          doc: doc,
          chapterId: resolvedChapterId,
        ),
      );
    }
  }

  Future<void> _prefetchOne({
    required String key,
    required String from,
    required String comicId,
    required Doc doc,
    required String chapterId,
  }) async {
    try {
      final cachedPath = await getCachePicture(
        from: from,
        url: doc.fileServer,
        path: doc.path,
        cartoonId: comicId,
        chapterId: chapterId,
        pictureType: PictureType.page,
        extern: doc.extern,
        // 不等超分：预取只负责把原图送进缓存，超分后台执行，
        // 完成后由 ImageDisplay 通过 ImageUpscaledEvent 热替换。
        waitForRealSr: false,
      );
      if (_disposed) return;
      if (cachedPath == '404') {
        _requestedKeys.remove(key);
      }
    } catch (_) {
      // 单张失败不影响其余图片；移除 key 允许下次触发时重试。
      _requestedKeys.remove(key);
    }
  }

  void dispose() {
    _disposed = true;
    _requestedKeys.clear();
  }

  String _buildKey({
    required String from,
    required String comicId,
    required String chapterId,
    required String path,
  }) => '$from|$comicId|$chapterId|$path';
}

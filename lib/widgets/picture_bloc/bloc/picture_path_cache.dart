import 'dart:io';

import 'package:zephyr/type/enum.dart';

/// 已解析图片路径的进程内同步缓存（LRU）。
///
/// 解决的问题：阅读页的图片组件随 PageView / ListView 的视口进出被反复销毁重建，
/// 每次重建都要新建 [PictureBloc] 走一遍异步加载（即使磁盘缓存命中也要等文件系统
/// IO），期间渲染的占位符会造成肉眼可见的闪烁——「翻页翻一半滑回去也会闪」就是它。
///
/// 有了这层缓存，组件挂载时**同步**查到路径即可首帧直接显示图片：
/// - 写入方：`getCachePicture` 每次成功返回路径前登记；
/// - 读取方：`ReadImageWidget` 创建 PictureBloc 前查询，命中则跳过整个异步往返。
///
/// 路径是稳定的（超分原地覆盖内容、不改路径），所以值不需要失效机制；
/// 唯一可能的失效是文件被清缓存删掉，读取时用一次同步 `stat` 校验兜底
/// （微秒级，不影响首帧时机），失效即回退到正常异步加载并清除该条目。
abstract final class PicturePathMemoryCache {
  /// 上限取整本漫画页数的一个宽松量级；条目只是路径字符串，内存可忽略。
  static const int _maxEntries = 512;

  /// 插入顺序即访问顺序（Dart 的 Map 字面量即 LinkedHashMap），保证 LRU
  /// 淘汰最久未用的。
  static final Map<String, String> _cache = <String, String>{};

  static String _key({
    required String from,
    required String path,
    required String cartoonId,
    required String chapterId,
    required PictureType pictureType,
  }) {
    return '$from\u241F$path\u241F$cartoonId\u241F$chapterId\u241F${pictureType.index}';
  }

  /// 登记一次成功解析。由 `getCachePicture` 在返回路径前调用。
  static void remember({
    required String from,
    required String path,
    required String cartoonId,
    required String chapterId,
    required PictureType pictureType,
    required String resolvedPath,
  }) {
    if (resolvedPath.isEmpty || resolvedPath == '404') return;
    final key = _key(
      from: from,
      path: path,
      cartoonId: cartoonId,
      chapterId: chapterId,
      pictureType: pictureType,
    );
    // remove 后再插入，把该条目挪到「最新」端。
    _cache.remove(key);
    _cache[key] = resolvedPath;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 同步查询已知路径；命中且文件仍存在时返回路径，否则 null。
  ///
  /// [File.existsSync] / [lengthSync] 是同步系统调用，微秒级完成，
  /// 不会推迟组件首帧——这正是「首帧即图」的前提。
  static String? lookup({
    required String from,
    required String path,
    required String cartoonId,
    required String chapterId,
    required PictureType pictureType,
  }) {
    final key = _key(
      from: from,
      path: path,
      cartoonId: cartoonId,
      chapterId: chapterId,
      pictureType: pictureType,
    );
    final resolved = _cache.remove(key);
    if (resolved == null) return null;

    var alive = false;
    try {
      final file = File(resolved);
      alive = file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      alive = false;
    }
    if (!alive) return null; // 条目已从 _cache 移除，等于淘汰

    _cache[key] = resolved; // 重新插回「最新」端
    return resolved;
  }

  /// 清空。应用退出前的清理钩子可用；常规使用不需要。
  static void clear() => _cache.clear();
}

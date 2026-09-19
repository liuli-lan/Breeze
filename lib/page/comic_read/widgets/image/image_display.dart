import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/comic_read/cubit/image_size_cubit.dart';
import 'package:zephyr/page/comic_read/cubit/reader_cubit.dart';
import 'package:zephyr/util/event/image_upscaled_event.dart';

/// 与 [FileImage] 等价的文件图片，但额外携带 [revision] 参与相等性判断。
///
/// 超分原地覆盖文件（路径不变、内容变）后，递增 revision 让 provider
/// 不再相等，从而触发 [Image] 重新解码；配合 gaplessPlayback 可在
/// 新帧解码完成前保留旧画面（无闪烁）。
class RevisionFileImage extends FileImage {
  final int revision;

  RevisionFileImage(File file, {required this.revision}) : super(file);

  @override
  bool operator ==(Object other) =>
      other is RevisionFileImage &&
      other.file == file &&
      other.scale == scale &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(file, scale, revision);
}

class ImageDisplay extends StatefulWidget {
  final String imagePath;
  final bool isColumn;
  final int pageSlotIndex;
  final int sizeCacheIndex;
  final Alignment imageAlignment;

  const ImageDisplay({
    super.key,
    required this.imagePath,
    required this.isColumn,
    required this.pageSlotIndex,
    required this.sizeCacheIndex,
    this.imageAlignment = Alignment.center,
  });

  @override
  State<ImageDisplay> createState() => _ImageDisplayState();
}

class _ImageDisplayState extends State<ImageDisplay> {
  /// 图片内容版本号，**按路径全局**而非放在 State 里。
  ///
  /// 超分原地覆盖文件后递增，驱动 [RevisionFileImage] 重新解码。之所以必须全局：
  /// 图片组件随视口进出被销毁重建，State 的 revision 会归零；而 imageCache 里的
  /// 条目是「超分后递增过的 revision」，归零的 key 必然 miss → 重挂载被迫重新
  /// 异步解码，表现为每次翻回/滑回都闪一下占位符。全局表让重建的实例直接拿到
  /// 当前 revision，命中已有缓存条目、同步出图。
  static final Map<String, int> _imageRevisions = <String, int>{};

  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  Timer? _einkDelayTimer;
  StreamSubscription<ImageUpscaledEvent>? _upscaledSub;

  double? _rawWidth;
  double? _rawHeight;
  bool _einkDelayFinished = true;
  bool _wasRowActive = false;

  /// 本组件是否已经成功出过帧。
  ///
  /// 用于区分「首次加载」（该显示占位符）与「已显示过、只是正在换图」
  /// （必须继续沿用上一帧）。见 [build] 中 frameBuilder 的说明。
  bool _hasShownImage = false;

  bool get isColumn => widget.isColumn;

  @override
  void initState() {
    super.initState();
    _resolveImageMeta();
    _upscaledSub = eventBus.on<ImageUpscaledEvent>().listen(_onImageUpscaled);
    _startEinkDelayIfNeeded(
      context.read<GlobalSettingCubit>().state.readSetting,
    );
  }

  /// 超分完成：文件路径不变、内容已覆盖为高清版。
  ///
  /// [FileImage] 的相等性只比较路径与 scale，必须 evict 旧缓存条目，
  /// 否则永远命中旧图；revision 递增（全局表）让 provider 不再相等，
  /// 配合 gaplessPlayback 在新帧解码完成前保留旧画面。
  void _onImageUpscaled(ImageUpscaledEvent event) {
    if (!mounted || event.path != widget.imagePath) return;

    final file = File(event.path);
    final oldRevision = _imageRevisions[event.path] ?? 0;
    PaintingBinding.instance.imageCache.evict(
      RevisionFileImage(file, revision: oldRevision),
    );
    // 全屏查看页用普通 FileImage，key 空间不同，一并清除其缓存条目
    // （全屏页不会自动刷新，但重开时即可读到高清版）。
    PaintingBinding.instance.imageCache.evict(FileImage(file));

    _stopListening();
    setState(() {
      _rawWidth = null;
      _rawHeight = null;
      _imageRevisions[event.path] = oldRevision + 1;
    });
    _resolveImageMeta();
  }

  @override
  void didUpdateWidget(covariant ImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isColumn != oldWidget.isColumn ||
        widget.imagePath != oldWidget.imagePath) {
      _stopListening();
      _rawWidth = null;
      _rawHeight = null;
      // 换了图：上一帧内容与当前图片无关，占位符逻辑重新生效。
      _hasShownImage = false;
      _resolveImageMeta();
    }

    if (widget.isColumn) {
      _einkDelayTimer?.cancel();
      _einkDelayFinished = true;
      _wasRowActive = false;
      return;
    }

    _startEinkDelayIfNeeded(
      context.read<GlobalSettingCubit>().state.readSetting,
    );
  }

  void _startEinkDelayIfNeeded(ReadSettingState readSetting) {
    if (isColumn) {
      _einkDelayTimer?.cancel();
      _einkDelayFinished = true;
      return;
    }

    if (!readSetting.einkOptimization) {
      _einkDelayTimer?.cancel();
      _einkDelayFinished = true;
      return;
    }

    _einkDelayTimer?.cancel();
    _einkDelayFinished = false;
    final delayMs = readSetting.einkDelayMs.clamp(50, 500);
    _einkDelayTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      setState(() {
        _einkDelayFinished = true;
      });
    });
  }

  void _resolveImageMeta() {
    final imageProvider = RevisionFileImage(
      File(widget.imagePath),
      revision: _imageRevisions[widget.imagePath] ?? 0,
    );
    final newStream = imageProvider.resolve(ImageConfiguration.empty);

    final newListener = ImageStreamListener(
      (ImageInfo imageInfo, bool synchronousCall) {
        if (!mounted) return;

        _rawWidth = imageInfo.image.width.toDouble();
        _rawHeight = imageInfo.image.height.toDouble();

        if (context.mounted) {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox != null && renderBox.hasSize) {
            _updateCubitSize(renderBox.size.width);
          }
        }
      },
      onError: (exception, stackTrace) {
        logger.e('Failed to resolve image size: $exception');
      },
    );

    _imageStream = newStream;
    _imageListener = newListener;
    newStream.addListener(newListener);
  }

  void _updateCubitSize(double actualWidth) {
    if (_rawWidth == null || _rawHeight == null || _rawWidth == 0) return;

    final index = widget.sizeCacheIndex;
    final cubit = context.read<ImageSizeCubit>();

    final double finalHeight = (_rawHeight! / _rawWidth!) * actualWidth;

    final currentCachedSize = cubit.getSize(index);

    if (!currentCachedSize.isCached ||
        (currentCachedSize.size.height - finalHeight).abs() > 0.5 ||
        (currentCachedSize.size.width - actualWidth).abs() > 0.5) {
      cubit.updateSize(index, Size(actualWidth, finalHeight));
    }
  }

  void _stopListening() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
  }

  @override
  void dispose() {
    _upscaledSub?.cancel();
    _stopListening();
    _einkDelayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final readSetting = context.select(
      (GlobalSettingCubit c) => c.state.readSetting,
    );
    final brightness = Theme.of(context).brightness;
    final backgroundColor = readSetting.resolveReaderBackgroundColor(
      brightness,
    );
    final foregroundColor = readSetting.resolveReaderForegroundColor(
      brightness,
    );
    final progressColor = foregroundColor.withValues(alpha: 0.3);
    final readMode = context.select(
      (GlobalSettingCubit c) => c.state.readSetting.readMode,
    );
    final currentPageIndex = context.select(
      (ReaderCubit c) => c.state.currentSlot,
    );
    final canUseEinkMask =
        !isColumn && readMode != 0 && readSetting.einkOptimization;
    final isActiveRowImage =
        !isColumn && currentPageIndex == widget.pageSlotIndex;

    if (canUseEinkMask && isActiveRowImage && !_wasRowActive) {
      _wasRowActive = true;
      _startEinkDelayIfNeeded(readSetting);
    } else if (!isActiveRowImage && _wasRowActive) {
      _wasRowActive = false;
    }

    if (!canUseEinkMask && !_einkDelayFinished) {
      _einkDelayTimer?.cancel();
      _einkDelayFinished = true;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        if (_rawWidth != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _updateCubitSize(width);
          });
        }

        return Align(
          alignment: widget.imageAlignment,
          child: Image(
            image: RevisionFileImage(
              File(widget.imagePath),
              revision: _imageRevisions[widget.imagePath] ?? 0,
            ),
            width: width,
            fit: isColumn ? BoxFit.fill : BoxFit.contain,
            alignment: widget.imageAlignment,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              final hasFrame = wasSynchronouslyLoaded || frame != null;
              if (hasFrame) _hasShownImage = true;

              // 墨水屏优化：翻页后先白屏、延迟结束再出图（行模式，用户显式开启）。
              if (canUseEinkMask && isActiveRowImage && !_einkDelayFinished) {
                return Container(width: width, color: Colors.white);
              }

              if (hasFrame) return child;

              // ★ 关键：provider 重新解析（超分原地覆盖内容后 revision 变化、
              // 或组件重挂载后换 key）期间，[Image] 因为 gaplessPlayback 为 true
              // **不会**清空 _imageInfo —— 传进来的 child 里仍然是上一帧的位图。
              //
              // 过去这里无条件返回占位符，等于把 gaplessPlayback 的保帧能力丢掉：
              // 于是每次换 key 重新解码（解码是异步的，大图要几十到几百毫秒）
              // 都会把已经显示好的画面闪成一块背景色 + 小转圈 ——
              // 表现为「翻页 / 捏合缩放 / 呼出菜单 / 翻一半滑回去时屏幕闪一下」，
              // 因为超分热替换就发生在这些操作的前后一瞬。
              //
              // 正确做法：只要本组件出过帧就直接沿用 child（旧图继续显示），
              // 新帧解码完成后 [Image] 自然会用新内容重建；占位符只服务于
              // 「从未出过帧」的首次加载。
              if (_hasShownImage) return child;

              return Container(
                width: width,
                color: backgroundColor,
                alignment: Alignment.center,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: progressColor,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

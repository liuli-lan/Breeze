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
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  Timer? _einkDelayTimer;
  StreamSubscription<ImageUpscaledEvent>? _upscaledSub;

  double? _rawWidth;
  double? _rawHeight;
  bool _einkDelayFinished = true;
  bool _wasRowActive = false;

  /// 图片内容版本号：超分原地覆盖文件后递增，驱动重新解码。
  int _imageRevision = 0;

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
  /// 否则永远命中旧图；[RevisionFileImage] 的 revision 让 provider
  /// 不再相等，配合 gaplessPlayback 在新帧解码完成前保留旧画面。
  void _onImageUpscaled(ImageUpscaledEvent event) {
    if (!mounted || event.path != widget.imagePath) return;

    final file = File(event.path);
    PaintingBinding.instance.imageCache.evict(
      RevisionFileImage(file, revision: _imageRevision),
    );
    // 全屏查看页用普通 FileImage，key 空间不同，一并清除其缓存条目
    // （全屏页不会自动刷新，但重开时即可读到高清版）。
    PaintingBinding.instance.imageCache.evict(FileImage(file));

    _stopListening();
    setState(() {
      _rawWidth = null;
      _rawHeight = null;
      _imageRevision++;
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
      revision: _imageRevision,
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
              revision: _imageRevision,
            ),
            width: width,
            fit: isColumn ? BoxFit.fill : BoxFit.contain,
            alignment: widget.imageAlignment,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) {
                if (!isColumn &&
                    canUseEinkMask &&
                    isActiveRowImage &&
                    !_einkDelayFinished) {
                  return Container(width: width, color: Colors.white);
                }
                return child;
              }

              if (isColumn) {
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
              } else {
                if (canUseEinkMask && isActiveRowImage && !_einkDelayFinished) {
                  return Container(width: width, color: Colors.white);
                }
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
              }
            },
          ),
        );
      },
    );
  }
}

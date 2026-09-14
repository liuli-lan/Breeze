import 'package:auto_route/auto_route.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/page/comic_read/comic_read.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/util/context/context_extensions.dart';
import 'package:zephyr/config/router/router.gr.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/widgets/picture_bloc/bloc/picture_bloc.dart';
import 'package:zephyr/widgets/picture_bloc/models/picture_info.dart';

class ReadImageWidget extends StatefulWidget {
  final PictureInfo pictureInfo;
  final int index;
  final bool isColumn;
  final int? cacheIndex;
  final int? displayNumber;
  final Alignment imageAlignment;

  const ReadImageWidget({
    super.key,
    required this.pictureInfo,
    required this.index,
    required this.isColumn,
    this.cacheIndex,
    this.displayNumber,
    this.imageAlignment = Alignment.center,
  });

  @override
  State<ReadImageWidget> createState() => _ReadImageWidgetState();
}

class _ReadImageWidgetState extends State<ReadImageWidget> {
  int get displayIndex => widget.displayNumber ?? widget.index + 1;
  int get cacheIndex => widget.cacheIndex ?? widget.index;
  bool get isColumn => widget.isColumn;

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
    final pictureInfoTemp = widget.pictureInfo.copyWith(
      pictureType: PictureType.page,
    );

    return BlocProvider(
      create: (context) {
        // 本会话已解析过的图片直接同步起步，首帧即图。
        //
        // 图片组件随 PageView / ListView 的视口进出被反复销毁重建（翻页翻一半
        // 滑回去再滑回来必然重建），若无此捷径，每次重挂载都要新建 bloc 走一遍
        // 异步加载——即使磁盘缓存命中也要等文件系统 IO，期间会闪出占位符。
        final cachedPath = PicturePathMemoryCache.lookup(
          from: pictureInfoTemp.from,
          path: pictureInfoTemp.path,
          cartoonId: pictureInfoTemp.cartoonId,
          chapterId: pictureInfoTemp.chapterId,
          pictureType: pictureInfoTemp.pictureType,
        );
        if (cachedPath != null) {
          return PictureBloc(
            initialState: PictureLoadState(
              status: PictureLoadStatus.success,
              imagePath: cachedPath,
            ),
          );
        }
        return PictureBloc()..add(GetPicture(pictureInfoTemp));
      },
      child: SizedBox(
        width: context.screenWidth,
        child: BlocBuilder<PictureBloc, PictureLoadState>(
          builder: (context, state) {
            switch (state.status) {
              case PictureLoadStatus.initial:
                return placeholder(
                  backgroundColor: backgroundColor,
                  foregroundColor: foregroundColor,
                );
              case PictureLoadStatus.success:
                return GestureDetector(
                  onLongPress: () {
                    context.pushRoute(
                      FullRouteImageRoute(imagePath: state.imagePath!),
                    );
                  },
                  child: Container(
                    color: backgroundColor,
                    child: ImageDisplay(
                      imagePath: state.imagePath!,
                      isColumn: isColumn,
                      pageSlotIndex: widget.index,
                      sizeCacheIndex: cacheIndex,
                      imageAlignment: widget.imageAlignment,
                    ),
                  ),
                );
              case PictureLoadStatus.failure:
                if (state.result.toString().contains('404')) {
                  return Image.asset(
                    'asset/image/error_image/404.png',
                    fit: BoxFit.fill,
                  );
                } else {
                  return Container(
                    color: backgroundColor,
                    child: InkWell(
                      onTap: () {
                        context.read<PictureBloc>().add(
                          GetPicture(widget.pictureInfo),
                        );
                      },
                      child: Center(
                        child: Text(
                          t.reader.imageLoadFailedRetry(
                            error: state.result.toString(),
                          ),
                          style: TextStyle(
                            fontSize: 20,
                            color: foregroundColor,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  );
                }
            }
          },
        ),
      ),
    );
  }

  Widget placeholder({
    required Color backgroundColor,
    required Color foregroundColor,
  }) => Container(
    color: backgroundColor,
    child: Center(
      child: Text(
        displayIndex.toString(),
        style: TextStyle(
          fontFamily: 'Pacifico-Regular',
          color: foregroundColor,
          fontSize: 150,
        ),
      ),
    ),
  );
}

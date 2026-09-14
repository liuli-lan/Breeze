import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:equatable/equatable.dart';
import 'package:stream_transform/stream_transform.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/util/error_filter.dart';
import 'package:zephyr/widgets/picture_bloc/bloc/picture_path_cache.dart';
import 'package:zephyr/widgets/picture_bloc/models/models.dart';

import 'package:zephyr/network/http/picture/picture.dart';

export 'package:zephyr/widgets/picture_bloc/bloc/picture_path_cache.dart';

part 'picture_event.dart';
part 'picture_state.dart';

const throttleDuration = Duration(milliseconds: 100);

EventTransformer<E> throttleDroppable<E>(Duration duration) {
  return (events, mapper) {
    return droppable<E>().call(events.throttle(duration), mapper);
  };
}

class PictureBloc extends Bloc<GetPicture, PictureLoadState> {
  /// [initialState] 用于「路径已知」的同步起步：阅读页图片组件随视口进出被
  /// 反复销毁重建，重建时若路径已在 [PicturePathMemoryCache] 里，就直接以
  /// success 状态构造——首帧即图，避免每次重挂载都闪一帧占位符。
  PictureBloc({PictureLoadState? initialState})
    : super(initialState ?? PictureLoadState()) {
    on<GetPicture>(
      _fetchImage,
      transformer: throttleDroppable(throttleDuration),
    );
  }

  Future<void> _fetchImage(
    GetPicture event,
    Emitter<PictureLoadState> emit,
  ) async {
    // 已显示图片时不再打回占位符：重复触发（失败重试、外部重载等）只更新
    // 结果，避免把正在显示的画面闪成 placeholder。
    if (state.status != PictureLoadStatus.success) {
      emit(state.copyWith(status: PictureLoadStatus.initial));
    }

    try {
      var picturePath = await getCachePicture(
        from: event.pictureInfo.from,
        url: event.pictureInfo.url,
        path: event.pictureInfo.path,
        cartoonId: event.pictureInfo.cartoonId,
        chapterId: event.pictureInfo.chapterId,
        pictureType: event.pictureInfo.pictureType,
        extern: event.pictureInfo.extern,
        usePlugin: event.usePlugin,
        // 显示路径不等超分：落盘即显示原图，超分后台完成后由
        // ImageDisplay 通过 ImageUpscaledEvent 热替换为高清版。
        waitForRealSr: false,
      );
      if (picturePath == '404') {
        throw Exception('404');
      }

      emit(
        state.copyWith(
          status: PictureLoadStatus.success,
          imagePath: picturePath,
        ),
      );
    } catch (e, s) {
      if (!e.toString().contains('404')) {
        logger.e(e, stackTrace: s);
      }
      emit(
        state.copyWith(
          status: PictureLoadStatus.failure,
          result: normalizeSearchErrorMessage(e),
        ),
      );
    }
  }
}

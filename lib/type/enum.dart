import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:zephyr/i18n/strings.g.dart';

@JsonEnum()
enum RealSrResolutionThreshold {
  @JsonValue('p540')
  p540,
  @JsonValue('p720')
  p720,
  @JsonValue('p1080')
  p1080,
  @JsonValue('p1440')
  p1440,
  @JsonValue('p2160')
  p2160;

  int get maxWidth => switch (this) {
    p540 => 540,
    p720 => 720,
    p1080 => 1080,
    p1440 => 1440,
    p2160 => 2160,
  };

  String get label => switch (this) {
    p540 => '< 540p',
    p720 => '< 720p',
    p1080 => '< 1080p',
    p1440 => '< 1440p',
    p2160 => '< 2160p',
  };
}

@JsonEnum()
enum RealSrNoiseLevel {
  @JsonValue('conservative')
  conservative(-1),
  @JsonValue('noDenoise')
  noDenoise(0),
  @JsonValue('denoise1x')
  denoise1x(1),
  @JsonValue('denoise2x')
  denoise2x(2),
  @JsonValue('denoise3x')
  denoise3x(3);

  final int value;

  const RealSrNoiseLevel(this.value);

  String get label => switch (this) {
    conservative => '保守',
    noDenoise => '无降噪',
    denoise1x => '降噪 1x',
    denoise2x => '降噪 2x',
    denoise3x => '降噪 3x',
  };
}

/// 超分引擎（Android / Windows / Linux 共用）。
///
/// - [ncnn]：内置 waifu2x / Real-CUGAN ncnn 方案，模型随应用下载。
/// - [mangaJaNai]：调用本机已安装的 MangaJaNaiConverterGui CLI 后端，
///   模型与 Python 运行时由 GUI 维护，仅 Windows 可用。
/// - [mangaJaNaiRemote]：把超分任务发到局域网内的 mjn-service
///   （把本机 GPU 包装成 HTTP 服务）。各平台都能用，是移动端接入本机
///   4070S 算力的方式；不需要客户端准备 Python 运行时与模型。
///
/// 平台可选范围由设置页决定：Android / Linux 提供 ncnn 与 mangaJaNaiRemote，
/// Windows 三种都提供。
@JsonEnum()
enum SrEngine {
  @JsonValue('ncnn')
  ncnn,
  @JsonValue('mangaJaNai')
  mangaJaNai,
  @JsonValue('mangaJaNaiRemote')
  mangaJaNaiRemote;

  String get label => switch (this) {
    ncnn => t.realSr.engineNcnn,
    mangaJaNai => t.realSr.engineMangaJaNai,
    mangaJaNaiRemote => t.realSr.engineMangaJaNaiRemote,
  };

  /// 是否属于 MangaJaNai 家族（本地 CLI 或远程服务端）。
  ///
  /// 两者共用放大倍率与灰度判定阈值，且都不走 NCNN 的并发池与分块设置。
  bool get isMangaJaNai => this != SrEngine.ncnn;

  /// 是否为远程服务端引擎。
  bool get isRemote => this == SrEngine.mangaJaNaiRemote;

  /// 是否为需要本机 Python 后端的本地 CLI 引擎。
  bool get isLocalCli => this == SrEngine.mangaJaNai;
}

@JsonEnum()
enum ExportType {
  @JsonValue('zip')
  zip,
  @JsonValue('folder')
  folder,
}

@JsonEnum()
enum ComicEntryType {
  @JsonValue('normal')
  normal,
  @JsonValue('favorite')
  favorite,
  @JsonValue('history')
  history,
  @JsonValue('download')
  download,
  @JsonValue('historyAndDownload')
  historyAndDownload,
}

@JsonEnum()
enum LoginStatus {
  @JsonValue('login')
  login,
  @JsonValue('loggingIn')
  loggingIn,
  @JsonValue('logout')
  logout,
}

@JsonEnum()
enum PictureType {
  @JsonValue('comic')
  comic,
  @JsonValue('cover')
  cover,
  @JsonValue('creator')
  creator,
  @JsonValue('favourite')
  favourite,
  @JsonValue('user')
  user,
  @JsonValue('category')
  category,
  @JsonValue('avatar')
  avatar,
  @JsonValue('page')
  page,
  @JsonValue('unknown')
  unknown,
}

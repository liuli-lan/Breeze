/// 单张图片超分完成事件。
///
/// 超分是原地覆盖：文件路径不变、内容被替换为高清版。显示层收到此事件后
/// 必须清除 ImageProvider 缓存并重新解码——[FileImage] 的相等性只比较
/// 路径与 scale，不主动失效就会一直命中旧图。
class ImageUpscaledEvent {
  final String path;

  const ImageUpscaledEvent(this.path);
}

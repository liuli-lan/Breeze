import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/real_sr/service/mangajanai_engine.dart';
import 'package:zephyr/page/setting/real_sr/service/real_sr_settings.dart';
import 'package:zephyr/src/rust/api/image.dart';
import 'package:zephyr/util/get_path.dart';

/// 批量超分调度器（仅 Windows / MangaJaNai 引擎）。
///
/// 动机：MangaJaNai 后端 `run_upscale.py` 每次启动都要重新初始化 Python 运行时、
/// 加载 torch 与超分模型，单张模式下的这部分固定开销远超推理本身。
/// 章节下载以 5 并发触发超分，若每张图各起一个进程，模型会被反复加载。
///
/// 策略：
/// - **攒批**：首张图入队后开启一个很短的收集窗口，窗口内到达的图合并为一批
///   （下载侧 5 并发，通常能攒到 5 张左右）。
/// - **批量单次调用**：整批交给 `run_upscale.py` 的文件夹模式，后端
///   `loaded_models` 会缓存模型，整批只加载一次。
/// - **单线程**：[_drain] 串行执行，同一时刻只有一个批次在跑；后端
///   `upscale_worker` 本身也是单 Thread + `Queue(maxsize=1)`，批内同样串行。
///   因此整个过程不会出现多个 Python 进程争抢 GPU。
///
/// 批内只有一张时不走文件夹模式，直接用单文件模式，避免无谓的目录开销。
class MangaJaNaiBatchScheduler {
  MangaJaNaiBatchScheduler._();

  static final MangaJaNaiBatchScheduler instance = MangaJaNaiBatchScheduler._();

  /// 批收集窗口。窗口内到达的图会合并成一批。
  ///
  /// 取值需要在「攒得够多」与「单张图的额外延迟」之间折中：超分本身以秒计，
  /// 百毫秒级的等待可以忽略，但窗口太长会让阅读器翻页明显变慢。
  static const Duration collectWindow = Duration(milliseconds: 150);

  /// 单批上限，达到即立刻开跑。
  ///
  /// 避免单批显存/内存峰值过高，也避免首批图等待过久。
  static const int maxBatchSize = 24;

  /// 单批整体超时。
  ///
  /// 文件夹模式对损坏图片没有容错：后端预处理线程抛异常后不会投递结束哨兵，
  /// 超分线程会永久阻塞在队列上导致进程不退出。这里用超时兜底，保证即使
  /// 遇到坏图也能终止进程并让后续批次继续。
  static const Duration batchTimeout = Duration(minutes: 30);

  /// 后端输出文件的扩展名。
  ///
  /// 后端按 `WebpSelected` 直接编码 WebP（q90），因此本层不再需要
  /// 「解码 PNG 再编码 WebP」的转码步骤。
  static const String _outputExtension = 'webp';

  final List<_PendingItem> _pending = <_PendingItem>[];
  Timer? _collectTimer;
  bool _draining = false;

  /// 提交一张待超分图片，返回该图超分（并转为 WebP、覆盖回原路径）完成的 Future。
  ///
  /// 同一路径在收集窗口内被重复提交时会复用同一个任务，避免重复超分。
  /// 失败只影响该图自身，不会牵连同批其他图片。
  Future<void> enqueue(String inputPath) {
    for (final existing in _pending) {
      if (existing.inputPath == inputPath) {
        return existing.completer.future;
      }
    }

    final item = _PendingItem(inputPath);
    _pending.add(item);

    if (_pending.length >= maxBatchSize) {
      // 达到批上限：立即开跑，避免首批等待过久与显存峰值过高。
      _kick();
    } else if (_pending.length == 1 && !_draining) {
      // 空队列的第一张：立即开跑，不付攒批窗口——阅读器首图
      // 不应该多等 150ms。已在执行的批次跑完后，其 while 循环会
      // 接住此间新入队的图片，攒批行为不受影响。
      _kick();
    } else {
      _collectTimer ??= Timer(collectWindow, _kick);
    }

    return item.completer.future;
  }

  void _kick() {
    _collectTimer?.cancel();
    _collectTimer = null;
    unawaited(_drain());
  }

  /// 串行消费所有待处理图片，保证同一时刻至多一个批次在执行。
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final batch = List<_PendingItem>.of(_pending);
        _pending.clear();
        await _processBatch(batch);
      }
    } finally {
      _draining = false;
      // 兜底：退出循环与标志复位之间若有新图入队（_kick 会因 _draining
      // 为 true 而直接返回），这里补一次调度，避免任务滞留。
      if (_pending.isNotEmpty && _collectTimer == null) {
        unawaited(_drain());
      }
    }
  }

  Future<void> _processBatch(List<_PendingItem> batch) async {
    final scale = await RealSrSettings.loadMangaJaNaiScale();
    final threshold = await RealSrSettings.loadMangaJaNaiGrayscaleThreshold();

    final workDir = await _newWorkDir();
    final inDir = p.join(workDir, 'in');
    final outDir = p.join(workDir, 'out');
    // 在 try 外声明：catch 需要用它把整批失败的异常逐个回传给等待方。
    final entries = <({_PendingItem item, int index})>[];

    try {
      await Directory(inDir).create(recursive: true);
      await Directory(outDir).create(recursive: true);

      // 统一转成 PNG 再交给后端：既保证扩展名被后端识别（无扩展名或
      // 格式与后缀不一致的缓存文件会被静默跳过），也让输入/输出文件名
      // 可预测（纯 ASCII 序号），不依赖原始文件名的字符集。
      for (var i = 0; i < batch.length; i++) {
        final item = batch[i];
        try {
          await convertImageToPng(
            inputPath: item.inputPath,
            outputPath: p.join(inDir, '$i.png'),
          );
          entries.add((item: item, index: i));
        } catch (e, s) {
          logger.w(
            'MangaJaNai 批量：输入准备失败，跳过 ${item.inputPath}',
            error: e,
            stackTrace: s,
          );
          item.completer.completeError(e, s);
        }
      }

      if (entries.isEmpty) return;

      logger.d(
        'MangaJaNai 批量超分：${entries.length} 张（scale=$scale, threshold=$threshold）',
      );

      if (entries.length == 1) {
        await MangaJaNaiEngine.upscale(
          inputPath: p.join(inDir, '${entries.single.index}.png'),
          outputPath: p.join(
            outDir,
            '${entries.single.index}.$_outputExtension',
          ),
          scale: scale,
          grayscaleThreshold: threshold,
        );
      } else {
        await MangaJaNaiEngine.upscaleFolder(
          inputDir: inDir,
          outputDir: outDir,
          scale: scale,
          grayscaleThreshold: threshold,
          timeout: batchTimeout,
        );
      }

      // 回写：后端已直接输出 WebP，无需再转码，覆盖回各自的原路径即可。
      for (final entry in entries) {
        final produced = File(
          p.join(outDir, '${entry.index}.$_outputExtension'),
        );
        if (!produced.existsSync()) {
          entry.item.completer.completeError(
            StateError('MangaJaNai 未产出结果: ${entry.item.inputPath}'),
          );
          continue;
        }
        try {
          await _replaceFile(produced.path, entry.item.inputPath);
          entry.item.completer.complete();
        } catch (e, s) {
          logger.w(
            'MangaJaNai 批量：回写失败 ${entry.item.inputPath}',
            error: e,
            stackTrace: s,
          );
          entry.item.completer.completeError(e, s);
        }
      }
    } catch (e, s) {
      // 整批失败（后端异常、超时等）：逐个失败，不影响后续批次。
      logger.w('MangaJaNai 批量超分失败', error: e, stackTrace: s);
      for (final entry in entries) {
        if (!entry.item.completer.isCompleted) {
          entry.item.completer.completeError(e, s);
        }
      }
    } finally {
      await _cleanup(workDir);
    }
  }

  Future<String> _newWorkDir() async {
    final cachePath = await getCachePath();
    final dir = Directory(
      p.normalize(p.join(cachePath, 'mangajanai-batch', const Uuid().v4())),
    );
    await dir.create(recursive: true);
    return dir.path;
  }

  /// 把 [from] 覆盖到 [to]。
  ///
  /// Windows 上目标已存在时 rename 会失败，跨卷时同样失败，因此退回复制。
  Future<void> _replaceFile(String from, String to) async {
    final src = File(from);
    try {
      await src.rename(to);
    } on FileSystemException {
      await src.copy(to);
      await src.delete();
    }
  }

  Future<void> _cleanup(String workDir) async {
    try {
      final dir = Directory(workDir);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      logger.w('MangaJaNai 批量工作目录清理失败: $workDir', error: e);
    }
  }
}

class _PendingItem {
  _PendingItem(this.inputPath);

  /// 图片原始路径，超分结果最终覆盖回此处。
  final String inputPath;

  final Completer<void> completer = Completer<void>();
}

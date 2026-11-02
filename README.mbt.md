# MoonTile

MoonTile 将多个图像切片上的目标检测框还原到原图坐标，并按类别执行非极大值抑制（NMS）。核心由 MoonBit 实现，不运行模型，也不读取或裁剪图片。它可作为检测器与 [MBMOT](https://github.com/python123-ops/mbmot) 跟踪、[MoonDetEval](https://github.com/python123-ops/moondeteval) 评估之间的组件。

当前已在 GitHub 开源，尚未发布到 Mooncakes。使用 MoonBit 0.10.14 工具链在源码目录运行：

```sh
moon test --target all --deny-warn
moon run cmd/main --target native -- examples/input.json
moon run cmd/main --target native -- examples/plan.json --plan
node examples/plan-consumer.mjs
moon run cmd/main --target native -- examples/partial-input.json
moon run cmd/main --target native -- examples/model-input.json
moon run cmd/main --target native -- examples/formats-input.json
moon run cmd/main --target native -- examples/clipped-input.json
moon run cmd/main --target native -- examples/complete-input.json
moon run cmd/main --target native -- examples/complete-input.json --inspect-grid 100
moon run cmd/main --target native -- examples/input.json --coco-map examples/coco-map.json
moon run cmd/main --target native -- examples/input.json --mbmot-frame 1
moon -C examples/consumer test --target all --deny-warn
node web/build.mjs
node web/test.mjs
node web/ui_test.mjs
node web/stream_test.mjs
node web/trace_stream_test.mjs
moon package
python validation/package_consumer.py --archive _build/publish/python123-ops-moontile-0.1.0.zip
```

`moon run` 读取 JSON 文件，成功时向标准输出写入一行 JSON；错误写入标准错误并返回退出码 2。示例为合成数据。运行 `node web/build.mjs` 后，从 `_build/site` 启动静态 HTTP 服务并打开 `index.html`。页面调用编译为 JavaScript 的同一 MoonBit 核心。

浏览器演示可输入图像、切片和重叠尺寸，预览切片位置与编号；选择“用此规划替换下方输入”会生成空检测列表并替换原有 JSON，然后可填入检测结果。修改规划参数后须重新生成，非法规划不会改动已有检测输入。超过 1000 个切片时图中只画前 1000 个，生成的输入和计算结果仍包含全部切片；超过 100 个切片时预览不显示编号。图像读取、裁剪和模型推理由调用方完成。

浏览器中还可选择本地 PNG、JPEG 或 WebP 作为切片与检测框的背景。图片只用于本地显示，不参与推理或上传；只有其浏览器解码尺寸与对应规划或预测的图像尺寸完全一致时才显示，否则页面提示尺寸不匹配。选择或移除图片不会修改预测输入；修改预测后需要重新运行，页面会清除旧预览。图片解码尺寸可能受浏览器方向处理影响，调用方应确保预测所用图像的方向和尺寸与预览一致。

“导入切片预测 JSON”可从本地读取 MoonTile 输入并立即处理；语法或字段无效时保留原有输入和结果；有规划但窗口不完整的有效输入会被导入并显示检查结果，修正后可运行合并。如果读取期间手动修改输入，或用规划替换输入，该文件不会覆盖新内容。页面可分别下载当前输入 JSON 和最近一次成功的结果 JSON；修改输入或处理失败后，需重新运行才能下载结果。文件均在浏览器本地处理。

## 使用与行为

`plan_tiles(width, height, tile_width, tile_height, overlap_x, overlap_y)` 生成覆盖原图的窗口，按照从上到下、从左到右编号。重叠量以整数像素表示；最后窗口贴住图像边缘，因此其实际重叠量可能大于请求值。图像小于窗口时，窗口尺寸缩小到图像尺寸。为避免意外分配，最多生成 100 万窗口。

需要按需处理大图窗口时，可以用相同参数创建 `TileGrid::new(...)`，通过 `length()` 获取总数，再用 `get(id)` 按编号读取窗口；无效编号返回 `None`。网格只保存布局参数，不分配完整窗口数组，便于调用方逐个裁剪、推理或分批处理。`plan_tiles` 基于同一网格生成数组，两种方式的编号和坐标一致；创建网格时会先检查总数，超过 100 万立即报错。`plan_tiles`、JSON 和 CLI 仍会为合法规划生成完整数组，内存使用随窗口数量增长。

外部程序可以使用 `moon run cmd/main --target native -- examples/plan.json --plan` 获取切片，或者调用 `plan_json`。请求包含图像尺寸 `image_width`、`image_height`，窗口尺寸 `tile_width`、`tile_height`，以及重叠像素 `overlap_x`、`overlap_y`；所有字段必须为 32 位整数。返回对象包含图像尺寸和 `tiles` 数组，数组项为 `{id,x,y,width,height}`。错误时 CLI 写入标准错误并以非零状态退出，不输出部分窗口。`examples/plan-consumer.mjs` 展示外部 Node.js 程序先获取窗口，再将窗口与预测组装为处理输入；示例预测是合成数据，实际使用时应替换为检测器对对应窗口产生的局部预测。JavaScript 构建还导出 `moontile_plan`，错误以带 `error` 字段的 JSON 对象返回。

`restore(tile, detection, image_width, image_height)` 验证切片和局部框并平移到原图。窗口边界采用半开区间；框使用连续 `xyxy`，面积为 `(x2-x1)*(y2-y1)`，不做 `+1`。局部框必须完全位于切片内，允许坐标位于切片边缘，不自动裁剪；退化、非有限、面积数值下溢以及平移后因浮点舍入失去正面积的框会被拒绝。检测分数须在 `[0,1]`，标识符和类别必须非负。

检测器输出的局部像素框可能越过切片边缘。需要裁剪时，MoonBit 调用方可显式使用 `restore_clipped(tile, detection, image_width, image_height)`；它先将连续框与切片相交，再还原至原图，保留检测来源。原始框必须有限且具有正面积；完全位于切片外、仅接触边缘、裁剪后退化或身份无效仍会报错。`restore` 保持严格拒绝越界框的行为。

JSON 中可在切片组设置 `"clip_local": true`，用于 `xyxy` 或 `xywh` 局部像素框，示例见 [examples/clipped-input.json](examples/clipped-input.json)。省略或设为 `false` 时不改变原来的行为，`null` 和非布尔值会报错；`true` 不能与该组 `transform` 同时使用，归一化格式也不能设置为 `true`。模型输入框需要按原有 `transform.clip` 处理。空切片也会检查选项；一组内有无效框时整个处理返回错误。CLI、浏览器、COCO 导出和视频流共用该规则。
MoonBit 调用方可用 `Box::from_xywh(x, y, width, height)` 转换连续像素框，或用 `Box::from_normalized_xyxy(...)`、`Box::from_normalized_cxcywh(...)` 转换归一化边界框及 YOLO 风格的归一化中心点框。归一化转换需要提供该框所在坐标空间的宽高：若框属于模型输入，应填写模型输入尺寸，再使用 `restore_model`；若框已经属于切片，应填写切片尺寸，再使用 `restore`。归一化后的框须完全落在 `[0,1]` 内，边界按浮点实际值严格判断；非有限、零面积和不可表示的结果会报错，不自动裁剪。像素 `xywh` 允许负起点，后续能否接受由还原和裁剪规则决定。

模型输出仍处于缩放、填充后的输入坐标时，可使用 `restore_model(tile, detection, image_width, image_height, transform)`。`ModelTransform` 描述实际预处理：`model_x = local_x * scale_x + pad_x`，纵轴同理；缩放必须为有限正数，左侧和顶部填充必须为有限非负数。框必须是模型输入上的绝对连续 `xyxy` 像素坐标，调用方负责提供实际缩放和填充值；已被推理框架还原的框应直接使用 `restore`。`clip=false` 时越出切片的框报错；`clip=true` 时先裁剪到切片，完全落在填充区或裁剪后失去面积的框仍报错。非有限结果、数值溢出和无效输入均被拒绝。

JSON 每个切片可选择性增加 `transform`，各切片可以使用不同参数，也可以和原有切片局部坐标混用，见 [examples/model-input.json](examples/model-input.json)。省略该字段沿用原有行为；即使检测列表为空也会验证变换参数。所有合并、COCO 和 MBMOT 输出共用同一转换流程。

每个切片还可以指定 `box_format`；同一切片内的检测框使用相同格式，不同切片可以混用。默认是 `"xyxy"`，保持原有输入兼容。示例见 [examples/formats-input.json](examples/formats-input.json)。

| `box_format` | `box` 字段 | 坐标空间 |
| --- | --- | --- |
| `xyxy` | `x1`, `y1`, `x2`, `y2` | 连续像素 |
| `xywh` | `x`, `y`, `width`, `height` | 连续像素 |
| `normalized_xyxy` | `x1`, `y1`, `x2`, `y2` | 归一化边界 |
| `normalized_cxcywh` | `cx`, `cy`, `width`, `height` | 归一化中心点及宽高 |

归一化格式必须同时提供切片组级别的 `coordinate_width` 和 `coordinate_height`，均为正整数。无 `transform` 时它们必须等于切片尺寸；有 `transform` 时须填写检测器输出所处的模型输入尺寸，由调用方确保与实际预处理一致。像素格式可省略这两个字段；如果提供，也必须成对且为正整数，但不参与像素框转换。空预测切片同样校验格式和尺寸。转换后的结果、浏览器预览、COCO 导出与两种视频流使用同一处理流程。

`suppress(detections, threshold, metric, class_agnostic=...)` 按得分降序执行贪心 NMS，同分保持输入顺序。默认按图像和类别分别处理；`class_agnostic=true` 只取消类别隔离，图像之间仍互不影响。支持 IoU 和交集除以较小框面积的 IoS，重叠度 **严格大于** 阈值时抑制。检测 ID 在同一调用中必须唯一，返回的抑制记录指出保留框 ID、被抑制框 ID 和重叠度。处理前会验证整个输入，错误不会返回部分结果。NMS 和外接框合并按图像、类别建立索引以跳过无关分组；NMS 对超过 64 个框的组进一步按水平位置建立空间块，跳过与候选框不相交的块，仍按得分排序选择最早的抑制来源。索引需要随检测数量增长的额外空间；框大范围重叠等情况下仍可能有二次方开销，外接框合并也仍有二次方最坏情况。CLI 一次读取完整文件，大规模输入应由调用方按图像拆分和限制大小。

对于跨切片的部分框，可以选择 `merge_envelopes`：先按分数和输入顺序选出种子，将与**原始种子框**重叠度严格超过阈值的框归入同一组，并输出覆盖整组的外接框。匹配不使用不断扩大的外接框，也不进行传递合并；代表框保留种子的 ID、图像、切片、类别与最高分，其他成员及其与种子的重叠度记录在 `suppressed` 中。默认按图像和类别隔离；`class_agnostic=true` 时可以跨类别合并，输出仍采用种子的类别。高重叠目标可能被合为一个框，阈值需结合具体数据验证。

`process_json` 使用 [examples/input.json](examples/input.json) 所示结构：每组包含窗口和属于该窗口的局部预测，返回 `restored`、`kept` 和 `suppressed`。可选字段 `strategy` 默认是 `"nms"`；设置为 `"greedy_nmm"` 后输出外接框，示例见 [examples/partial-input.json](examples/partial-input.json)。在合并策略下，`suppressed` 的记录表示被归入代表框的成员，`overlap` 相对于原始种子框。相同输入也能使用 COCO 导出、MBMOT 导出和流处理。CLI 用这些 API 执行同一流程；空切片同样会校验。序列处理时可逐帧调用，并自行保证帧号和跟踪器状态。

MoonBit 调用方可以使用类型化的 `process_tiles(image_width, image_height, tiles, config)` 一次完成还原和合并，无需组装 JSON。`TilePredictions` 包含 `tile`、`detections` 和可选 `transform`；`MergeConfig` 指定阈值、重叠度量、是否跨类别处理以及 `Nms` 或 `GreedyNmm` 策略。结果的 `restored` 保持输入顺序，`merged` 包含排序后的保留框和溯源记录。所有切片在一次调用中共用图像尺寸；不同图像 ID 的框互不合并，检测 ID 在整个调用中必须唯一。任一切片或检测无效时返回错误，不返回部分结果。完整类型化接入示例见 [examples/consumer/bridge_wbtest.mbt](examples/consumer/bridge_wbtest.mbt)。

逐切片接收结果时，可用 `TileAccumulator::new(image_width, image_height, config)` 创建累积器，并通过 `add_tile` 依次加入 `TilePredictions`。每次添加会先校验整个切片、转换坐标并检查标识是否重复；失败时先前数据保持不变，可以修正后重试。`tile_count` 和 `detection_count` 查询已接受的数量，`finish` 执行全局合并并返回独立快照，`reset` 清空数据但保留尺寸和配置。`finish` 不清空累积器，之后仍可添加；同分框按切片加入和框在切片内的顺序处理。累积器会保存已接收窗口和全部检测，内存随窗口及检测数量增长；它不会提前确定最终保留框。 检测器按批次返回结果时，可调用 `add_tiles` 一次加入多个切片：批次内以及与此前数据之间的重复切片或检测 ID、无效框和变换都会使整批失败，先前数据不受影响；空批次有效。批次内的输入顺序保持不变，同分框按加入顺序处理。校验期间会暂存本批还原后的框，所需额外内存随本批检测数量增长。

需要确认整个规划都已接收时，可调用 `TileAccumulator::finish_grid(grid)`。它要求网格与累积器图像尺寸相同，逐一核对每个规划切片的编号、位置和尺寸，并要求非空检测属于同一 `image_id`。没有检测的切片也必须加入空预测组；失败不会改变累积器，可以补齐后重试。窗口可乱序加入，同分框仍按加入顺序处理。该检查确认调用方提交了对应窗口，不能验证调用方实际运行了检测器；空预测组不携带可校验的图像 ID。普通 `finish()` 仍允许只处理部分窗口。

处理完一帧后不再需要保留累积状态时，可调用 `finish_take()`；需要同时检查切片完整性时调用 `finish_grid_take(grid)`。成功时直接把累积器已还原的检测数组交给结果，清除窗口及检测 ID，并允许重新使用累积器；先前快照及已取出的结果不会受后续添加或清空影响。检查或合并失败时状态保持不变。该方式避免 `finish()` 的一次检测数组复制，但仍需保存整帧检测、排序和合并所需的数据，尚未测量峰值内存。JSON、CLI 和 `process_tiles` 的一次性处理也使用该路径。

对 200 张真实图片的切片预测，逐项比较了快照、取出及复用后的结果；见[累积器取出验证结果](validation/scale/accumulator-take-results.json)。

可用 `python validation/memory_scale/run.py` 复现累积器资源测试。一次 Windows native release 测量中，30 万个合成检测的进程峰值工作集中位数为：快照接口 92.84 MiB、取出接口 90.57 MiB；合并耗时中位数分别为 165.4 毫秒和 183.2 毫秒。每种方式先预热一次，再交替运行三次；峰值包含进程启动、构造累积器、合并与结果核对，合并计时单独记录。数据为 10 类完全重合的合成框，2 毫秒采样可能漏掉进程退出前的短暂峰值，不能作为真实业务容量或性能结论。[结果文件](validation/memory_scale/results.json)记录原始样本和哈希；CI 在 Linux 上运行 1 万框的小规模正确性与采样检查。

调用 `TileAccumulator::inspect_grid(grid, max_reported=100)` 可在合并前获取 `GridInspection`：其中包含规划与已接收窗口数、缺失窗口数、位置或尺寸不匹配数、多余窗口数、各类问题的编号样本，以及检测是否混入多个图像 ID。`is_complete()` 判断是否满足 `finish_grid` 的窗口与图像规则。编号样本按升序返回各类最小 ID，默认每类最多 100 个；`max_reported` 可设为 0–10,000，设置为 0 时仍返回完整计数。巡检不修改累积器或执行合并，样本空间最多随该上限增长；它仍需扫描规划窗口、已接收窗口及检测。空预测窗口不带图像 ID，无法据此核实其归属。

JSON 输入可调用 `inspect_grid_json(source, max_reported=100)`，或使用 CLI 的 `--inspect-grid [LIMIT]` 在合并前检查；输入必须包含 `tile_plan`，报告包含 `complete`、完整计数、各类编号样本和 `mixed_images`。样本上限默认 100，允许 0–10000；无效输入、重复窗口或非法检测直接报错，CLI 不输出部分报告。浏览器的“检查切片完整性”按钮使用同一接口和默认上限，规划生成的输入自带 `tile_plan`；修改输入后会清除旧检查结果。此入口读取并校验完整 JSON 和全部预测，内存仍随输入规模增长。
已接收的窗口需要修正时，`replace_tile(group)` 用相同窗口 ID 原子替换整组预测；新窗口、检测、变换和 ID 都先通过校验，失败时保留旧数据。新检测可以复用被替换窗口自己的检测 ID，但不能与其他窗口冲突。成功后新检测排在其余已接收检测之后，因此相同分数的框可能改变保留顺序；先前 `finish()` 快照保持不变。`remove_tile(id)` 移除已接收窗口并释放其检测 ID，可用于删除错误编号后重新添加；未知窗口 ID 返回错误。两种操作都需遍历已接收检测并暂存其余检测，时间和临时空间随检测数量增长。替换后如需确认仍满足规划，应再次调用 `finish_grid`。
需要同时重试多个窗口时，`replace_tiles(groups)` 在提交前校验整批窗口、变换和检测 ID；任一项无效时整个累积器保持原样。被替换窗口之间可以交换检测 ID，但不能与未替换窗口冲突；空批次有效。成功后未替换的检测保持原顺序，新检测按批次顺序追加，因此同分框的保留结果可能改变。一次批量操作扫描已有检测并暂存替换结果，仍需随检测数量增长的内存；逐次调用 `replace_tile` 会重复扫描。

在一次本机 native release 合成测试中，2,000 个窗口、40,000 个检测，替换其中 500 个窗口：5 次测量的中位数为逐个替换约 491.4 毫秒、批量替换约 8.2 毫秒。计时只覆盖替换操作，不包含初始化、最终合并或模型推理；同一框重复出现的合成负载不代表实际生产吞吐量。测试逐项核对还原框、保留框和抑制记录，并对 200 张真实 COCO 图片中 740 个窗口执行批量与逐个替换结果对照。可用 `python validation/batch_bench/run.py` 复现，参数、样本、源码哈希和完整结果见 [results.json](validation/batch_bench/results.json)。
JSON 可选 `tile_plan` 对象指定 `tile_width`、`tile_height`、`overlap_x` 和 `overlap_y`，启用同一完整性检查，见 [examples/complete-input.json](examples/complete-input.json)。字段必须是 32 位整数，窗口规划使用输入图像尺寸，编号与 `plan_tiles` 一致。漏片、额外或重复编号、错误窗口尺寸和位置、混合图像 ID 都报错；不提供 `tile_plan` 时保留原有行为。CLI、浏览器、COCO 和 MBMOT 导出及视频流使用同一规则。
JSON 处理入口要求图像和切片尺寸、切片位置、检测标识和类别标识为 32 位整数；类别映射 ID 和流帧号也必须为整数。数值上为整数的 `1.0`、`1e0` 等写法可用，解析后的非整数值会报错；数值先按双精度解析，极接近整数或极小的数可能发生舍入。检测框坐标、分数和阈值仍可使用小数。以上检查适用于 MoonTile 的 JSON 入口；如果调用方直接使用 MoonBit 的通用 `FromJson` 解码公开类型，需要自行验证输入。

需要把合并结果交给 MoonDetEval 或其他 COCO bbox 评估器时，CLI 增加 `--coco-map`，输出 COCO 检测结果数组而不是诊断对象。映射文件是 `[{"class_id":0,"category_id":7}]` 形式的 JSON 数组；完整示例见 [examples/coco-map.json](examples/coco-map.json)。每个保留框的类别都必须有映射，重复的 `class_id`、负数 ID、格式错误和缺失映射会使命令报错，标准输出保持为空。多个 class 可以映射到同一个 category；类别映射发生在 NMS 之后，不影响原有的按检测类别去重。输出的 `bbox` 使用连续 `xywh`，顺序与保留结果一致，不裁剪，也不包含 MoonTile 内部检测 ID。

库调用可使用 `export_coco(detections, mappings)` 导出已有的原图坐标检测，或使用 `process_coco_json(source, mapping_source)` 一次完成还原、NMS 和导出。`export_coco` 保留输入顺序并检查重复检测 ID 和无效框，不会再次执行 NMS。

需要送入 MBMOT 时，CLI 的 `--mbmot-frame 1` 输出一行 `{"frame":1,"detections":[...]}`，每个检测包含原图连续 `xyxy`、`score` 和 `class_id`，可供 MBMOT 的 NDJSON replay 使用。每次命令处理一个输入文件和一个正整数帧号；调用方按帧依次运行并拼接输出行，保证帧号严格递增和坐标尺度一致。单帧输入中的检测必须属于同一 `image_id`；空检测帧也可导出。格式中不携带 MoonTile 的图像、切片或检测 ID，也不执行跟踪。`--mbmot-frame` 和 `--coco-map` 二选一。

库调用可使用 `export_mbmot(detections, frame)` 导出已有原图坐标检测，或调用 `process_mbmot_json(source, frame)` 完成还原、NMS 和导出。NMS 仍按分数决定保留哪些框，MBMOT 导出再将保留框恢复为原始输入顺序，以保留跟踪器看到的检测次序。无效帧号、非法框、重复检测 ID 或同帧混入多个图像 ID 均报错，不输出部分结果。多帧状态和轨迹生命周期由 MBMOT 管理。

连续帧可以用单个进程处理，无需每帧重启命令。标准输入为 NDJSON，每行是 `{"frame":1,"input":{...}}`；`input` 使用与 `examples/input.json` 相同的切片预测对象。可以先运行仓库内的三帧样例：

```sh
moon run cmd/main --target native -- --mbmot-stream < examples/stream.ndjson
```

每条成功输入即时输出一条可供 MBMOT replay 消费的 NDJSON，帧号必须是严格递增的正整数，允许跳帧；空检测帧有效。错误信息包含物理行号，CLI 以非零状态退出，先前完整输出仍保留；空行也按无效 JSON 处理。每个进程只处理一条流，跟踪仍由下游 MBMOT 完成；调用方须保证输入坐标尺度跨帧一致。CLI 按行读取，不限制单行大小，接入不受信任来源时应由调用方限制输入大小。

MoonBit 调用方也可用 `StreamSession::new()` 和 `process_line` 逐行处理。无效输入不会改变该会话的最后成功帧号，调用方可以修正并重试；`last_frame()` 查询进度，`reset()` 开始新流。CLI 遇错退出，不自动重试。

其他下游程序需要保留切片来源和抑制诊断时，可以对相同的 NDJSON 输入使用 `--trace-stream`：

```sh
moon run cmd/main --target native -- --trace-stream < examples/stream.ndjson
```

每帧输出 `{"frame":1,"result":{"restored":[...],"kept":[...],"suppressed":[...]}}`；`result` 与对该帧调用 `process_json` 的结果一致。MoonBit 调用方可用 `StreamSession::process_trace_line`，与 `process_line` 共用帧号状态。两种流模式都要求帧号严格递增、单帧检测属于同一图像，允许空检测帧；输入无效时不会推进会话。CLI 出错后保留先前完整帧并退出，不输出失败帧。

## 项目关联与验证

`examples/consumer` 是独立 MoonBit 模块，通过 workspace 引用源码，固定已发布的 MBMOT 0.3.0 和 MoonDetEval 0.1.0，展示框转换、显式类别映射、跟踪和 AP50 评估。测试还通过 MBMOT 自身解析器读取两帧切片合并结果，并检查跟踪身份延续。当前测试是合成样例，不代表模型精度。更高版本的 MoonDetEval 0.2.x 在本机 0.10.14 编译器上因 `Int32` 不可识别而未通过；不能将该 consumer 的结果推广到那些版本。

`validation/package_consumer.py` 将 `moon package` 生成的 ZIP 解压到临时目录，再从同一 ZIP 复制 consumer，使用独立 workspace 指向解压后的模块；`moon update` 获取 MBMOT、MoonDetEval 和其他依赖后，测试全部四个后端。脚本输出所用 ZIP 的 SHA-256，并在结束时清理临时目录。CI 运行同一检查，以发现缺失打包文件或依赖原仓库路径的问题。MoonTile 尚未发布到 Mooncakes，此检查不等同于验证从 Mooncakes 安装。

浏览器与原生 CLI 的 JSON 输出由 `web/test.mjs` 对照；核心测试覆盖切片、还原、NMS、类别隔离、同分、边界和非法输入。

`validation/grouping_compare.py` 使用合成的互不相交框对比索引优化前后的原生命令行；同时检查完整输出逐字节一致。一次 Windows 本地运行中，8000 框、100 类的 NMS 耗时中位数从约 0.165 秒降至 0.138 秒，贪心外接框合并从约 1.110 秒降至 0.148 秒；1200 框、单类别场景的 NMS 从约 0.0355 秒增加到 0.0367 秒，外接框合并从约 0.0451 秒增加到 0.0483 秒。每组预热一次、交替运行三次，耗时包含进程启动和 JSON 处理。具体样本、二进制及源码哈希见 `validation/grouping-results.json`；这些合成结果不代表真实检测任务的性能。

复现性能对照时，分别用优化前提交 `bdcc2f0` 和当前代码构建原生 release 可执行文件，然后运行：

```sh
python validation/grouping_compare.py --before <before-cli> --after <after-cli> --before-revision bdcc2f0 --repeat 3 --output <output.json>
```

`validation/sahi_compare.py` 从固定的 SAHI 0.11.14 源码中提取原始 NMS 和贪心 NMM 分组函数，并以 PyTorch 运行参考实现。固定种子的 80 组、每组 25 框的单图单类别无同分场景覆盖 IoU 和 IoS；NMM 外接框另按组内坐标核对，结果见 `validation/sahi-results.json`。本库在重叠度等于阈值时保留，SAHI 0.11.14 在相等时抑制或合并；脚本单独验证这一差异。本对照未涵盖多类别、掩码或同分行为。

`validation/sahi_layout.py` 对照同一固定版本的窗口生成及框平移：100 组尺寸和重叠参数的所有窗口一致；每组最多抽取 16 个窗口、共 1229 个合成框，平移结果一致。结果、固定种子、源码和本次二进制的哈希见 `validation/sahi-layout-results.json`。两库参数与边界规则存在差异：MoonTile 直接接收整数重叠像素，SAHI 接收比例并将相乘结果取整，例如 `29 / 50` 在本次运行中得到 28 像素；SAHI 的框平移可处理超出切片的框，而 MoonTile 默认拒绝这类输入。此对照只覆盖固定切片尺寸与二维框，不包含真实模型推理。

复现窗口对照需要 Git、Python 标准库和本项目的 MoonBit 工具链；将 SAHI 检出到指定提交后运行：

```sh
git clone https://github.com/obss/sahi.git _build/sahi-reference
git -C _build/sahi-reference checkout 0077a143abdabad2ac81eb375377c744662f7578
moon build cmd/main --target native
python validation/sahi_layout.py --sahi-dir _build/sahi-reference --binary <native-cli> --output validation/sahi-layout-results.json
```

`<native-cli>` 是构建生成的 `cmd/main/main` 可执行文件路径，Windows 上为 `main.exe`。脚本会核对参考仓库提交和所用源码内容；CI 同样运行该对照。

`validation/real_coco.py` 使用先前保存的 COCO val2017 标注和 YOLO11n 整图预测，先核对文件哈希，再将整张图作为单个切片重放。已运行 10 张图、2136 个预测，pycocotools 的 12 项 bbox 指标在重放和 COCO 导出后均与原结果一致；记录见 `validation/real-coco-results.json`。这验证真实整图数据的坐标和评估链路，不是逐切片推理验证。

同一组预测也用于检验 JSON 框格式：以 `xywh` 直接输入，或把已有预测通过数学计算转换为归一化 `xyxy`、归一化中心点格式后输入。三个格式的 12 项指标均与原始预测一致；最大框坐标误差分别为 0、约 `5.68e-14`、约 `8.53e-14` 像素。各自的哈希、参数及结果保存在 `validation/real-coco-xywh-results.json`、`validation/real-coco-normalized_xyxy-results.json` 和 `validation/real-coco-normalized_cxcywh-results.json`。归一化框是由已有整图预测转换得到，并非额外运行检测器产生的预测。

复现时使用之前保存的标注、预测和来源记录，并安装 `pycocotools`；下面以归一化中心点格式为例：

```sh
python validation/real_coco.py --ground-truth <ground_truth.json> --predictions <predictions.json> --provenance <results.json> --binary <native-cli> --count 10 --input-format normalized_cxcywh --output <output.json>
```

`--input-format` 还支持 `xyxy`、`xywh` 和 `normalized_xyxy`。脚本验证输入哈希、输出标识、顺序、坐标误差以及 COCO 指标；筛选规则、原推理参数和随机种子记录在结果文件中。

`validation/real_tiled_coco.py` 对 10 张 COCO val2017 图片实际裁剪并使用 YOLO11n 逐切片推理：窗口 256×256、重叠 64 像素，得到 59 个切片和 664 个有效预测。类别内 IoU NMS 阈值为 0.5，合并后保留 402 个、抑制 262 个；被抑制数量不等同于经标注确认的重复框数量。合并前后 MoonDetEval 的 AP 分别为 0.3295 和 0.3327，AP50 分别为 0.5063 和 0.5213；12 项指标与 pycocotools 逐项对照，最大差异约为 1.11e-16。这是选定 10 张图片、固定推理参数下的结果，不代表整体数据集的精度提升。脚本还逐框核对坐标平移、来源和 COCO 导出。原始逐切片局部预测、标注子集和完整指标分别保存在 [real-tiled-coco-predictions.json](validation/real-tiled-coco-predictions.json)、[real-tiled-coco-ground-truth.json](validation/real-tiled-coco-ground-truth.json) 和 [real-tiled-coco-results.json](validation/real-tiled-coco-results.json)。

标注源、图像地址、模型地址、哈希与选择方式见 [real-tiled-coco-source.json](validation/real-tiled-coco-source.json) 和结果文件。COCO 标注采用 [CC BY 4.0](https://cocodataset.org/#termsofuse)，图像版权和许可由各自来源决定，标注子集保留原始许可与图片元数据；仓库不包含图片或模型权重。本验证使用的 Ultralytics YOLO11 模型和工具提供 [AGPL-3.0 与企业许可](https://docs.ultralytics.com/models/yolo11)，它们是外部实验依赖，不属于 MoonTile 核心依赖。

复现需要根据结果文件中图片文件名和来源下载图片及权重，并准备 MoonTile 和对应版本的 MoonDetEval 原生命令。Python 环境使用 `ultralytics==8.3.0`、`torch==2.4.1`、`torchvision==0.19.1`、`numpy==1.24.4`、`opencv-python==5.0.0.93`、`pycocotools==2.0.7`；脚本验证权重与标注子集哈希，并记录图片及命令哈希。运行：

```sh
python validation/real_tiled_coco.py --ground-truth validation/real-tiled-coco-ground-truth.json --provenance validation/real-tiled-coco-source.json --images <image-cache> --weights <yolo11n.pt> --moontile <moontile-cli> --moontile-revision c4fe74eb9174945ee5da10ca394a67a7d5ea33d8 --moondeteval <moondeteval-cli> --moondeteval-revision c57bf0dde713546e93f5f44233d7d382334d83bd --count 10 --raw <predictions.json> --output <results.json>
```
不运行模型时，可使用 `python validation/replay_tiled_coco.py --binary <moontile-cli>` 回放保存的真实预测并检查坐标与合并数量；CI 运行该回放。

`validation/real_video.py` 重放 MBMOT 现有演示的 OpenCV HOG 检测流，将每帧整图作为一个窗口，经单个 MoonTile 流处理进程转成 MBMOT 输入，再与直接输入原始检测流的跟踪结果逐帧比较。已验证 90 帧、291 个检测，跟踪输出全部一致；其中 80 帧的输入检测并非按分数降序排列。来源、二进制哈希和命令见 `validation/real-video-results.json`。本验证没有使用真实切片推理，也不衡量跟踪精度。

### 扩大真实图片验证

[validation/scale](validation/scale) 将真实切片验证扩大到从 COCO val2017 分层选出的 200 张图片、1,406 个切片，包含 1,652 个标注、73 个标注类别和 11,657 条切片预测。按照互斥面积区间统计，标注中小目标 776 个、中目标 549 个、大目标 327 个；另有 25 条 crowd 标注。这个分层子集不是全量验证集，不能用其结果推断整个数据集上的效果。

[quality.py](validation/scale/quality.py) 对同一批真实预测检查 8 组配置：IoU NMS 阈值 0、0.3、0.5、0.7、1，IoS NMS 和贪心外接框合并（阈值 0.5），以及跨类别 IoU NMS（阈值 0.5）。每组逐图比较独立 Python 贪心实现与 MoonTile 的还原框、保留框和抑制溯源，并用 MoonDetEval 与 pycocotools 对照 12 项 COCO 指标。完整数字和来源哈希见 [quality-results.json](validation/scale/quality-results.json)。例如按类别 IoU NMS 阈值 0.5 时，保留 6,869 条预测，AP 为 0.1915、AP50 为 0.3260；八组的指标参考差异均不超过 1.67e-16。不同配置的指标变化仅描述这批样本，不代表普遍精度提升；被抑制数不等于人工核实的重复框数量。

完整复现沿用前述 YOLO11n 权重和 Python 依赖，使用以下入口；省略 `--infer`、图片与权重参数可直接回放目录中保存的真实预测和标注。两种方式都需要 MoonTile 和 MoonDetEval 原生命令。

```sh
python validation/scale/quality.py --infer --images <image-cache> --weights <yolo11n.pt> --moontile <moontile-cli> --moontile-revision 020358e83e0c88313ce2cf1694c549b2d24636e1 --moondeteval <moondeteval-cli> --moondeteval-revision c57bf0dde713546e93f5f44233d7d382334d83bd
```

CI 使用 Python 标准库回放全部 200 张图的原始切片预测，检查坐标和 NMS 结果数量；八组指标和外部参考评估需要上述完整 Python 环境。

使用同一批 200 张真实图片预测验证 `tile_plan`：200 个完整切片组的输出与原流程一致，分别人为删除一片或修改一片尺寸后，200 个漏片输入和 200 个错误窗口输入均被拒绝，标准输出为空。完整记录见 [grid-completeness-results.json](validation/scale/grid-completeness-results.json)；错误输入是为验证边界人为构造的。
针对同一批 200 张真实图片的预测，还对每张图人为注入一个漏片、一个尺寸错误和一个多余空窗口，检查 `inspect_grid` 能定位三类问题；修正后与相同输入顺序下的批处理逐项比较还原框、保留框和溯源记录，200 张均一致。验证程序为 [validation/grid_inspect/main.mbt](validation/grid_inspect/main.mbt)，结果与哈希见 [grid-inspection-results.json](validation/scale/grid-inspection-results.json)；真实框来自已有预测，窗口错误为人为注入。该对照也在 CI 运行。 同一数据集的 JSON 命令行入口回放中，200 个完整输入和 200 个同时注入三类窗口错误的输入均通过核对，记录见 [JSON 巡检结果](validation/scale/json-grid-inspection-results.json)。
另取上述真实预测中贴住切片边缘的 665 个框，将贴边坐标人为向切片外延伸 1 像素，覆盖 160 张图的 459 个切片；启用 `clip_local` 后，全部还原框、合并框和抑制记录与原始预测一致。这是基于真实预测构造的边界扰动，不是检测器直接输出的越界框。[扰动验证结果](validation/scale/clipping-boundary-results.json)记录各边界数量与输入哈希；CI 同样运行该回放。
`validation/real_tiled_video.py` 补充真实切片视频链路：读取 OpenCV 的 [vtest.avi](https://github.com/opencv/opencv/blob/4.x/samples/data/vtest.avi) 前 20 帧（768×576、10 FPS），每帧切成 6 个 384×384 窗口，重叠 128 像素，在每个窗口运行 OpenCV HOG 行人检测。MoonTile 对 143 个局部预测执行坐标还原和 IoU 0.4 的 NMS，保留 54 个，再逐帧送入 MBMOT；跟踪输出包含 20 帧，5 个轨迹 ID 在多帧出现。HOG 的分数是 SVM margin 的 sigmoid 变换，并非经过校准的概率；视频没有跟踪标注，轨迹数量和 ID 延续不能说明跟踪准确率，被抑制数量也不等同于人工确认的重复框数量。

[完整结果](validation/real-tiled-video-results.json)记录视频、二进制和输出哈希、参数及项目版本；[切片预测](validation/real-tiled-video-predictions.json)、[MBMOT 输入](validation/real-tiled-video-detections.json)和[跟踪输出](validation/real-tiled-video-tracks.json)可直接审阅。仓库不包含原视频，OpenCV 仓库的许可见其 [LICENSE](https://github.com/opencv/opencv/blob/4.x/LICENSE)。完整推理使用 `opencv-python==4.13.0.92`，需要视频及两个项目的原生可执行文件：

```sh
python validation/real_tiled_video.py infer --video <vtest.avi> --moontile <moontile-cli> --mbmot <mbmot-replay-cli> --moontile-revision 418f2582969c7b94075a9b09cdea7ceb28993888 --mbmot-revision 1021f4e7c24a8c865e114d97111ffd969f6b515f --frames 20
```

不重新执行图像检测时，可用 `python validation/real_tiled_video.py replay --moontile <moontile-cli> --mbmot <mbmot-replay-cli>` 回放真实预测，验证还原坐标、检测顺序及跟踪结果；不提供 `--mbmot` 时只验证 MoonTile 部分。CI 固定 MBMOT 提交并运行完整回放。
真实视频切片链路进一步扩展到同一视频前 150 帧、900 个切片：HOG 输出 955 个有效预测，MoonTile 保留 468 个并送入 MBMOT，得到 150 帧跟踪结果。19 个轨迹 ID 中有 18 个出现在多帧；该视频没有跟踪标注，这不构成身份正确率评估。原始预测、跟踪结果、来源及可执行文件哈希见 [validation/video-scale](validation/video-scale)；CI 使用固定版本的 MBMOT 回放全部 150 帧。

```sh
python validation/real_tiled_video.py infer --video <vtest.avi> --moontile <moontile-cli> --mbmot <mbmot-replay-cli> --moontile-revision adbe9bd --mbmot-revision 1021f4e7c24a8c865e114d97111ffd969f6b515f --frames 150 --raw validation/video-scale/predictions.json --output-frames validation/video-scale/detections.json --tracks validation/video-scale/tracks.json --report validation/video-scale/results.json
```
## 边界与参考

只处理二维轴对齐框；不包含掩码合并、旋转框、模型推理或视频解码。后处理参考 [SAHI](https://github.com/obss/sahi) 的公开问题定义；已验证范围和已知差异见上文。本项目为独立实现，Apache-2.0 许可。已有 [moonbit-visual-debug](https://mooncakes.io/docs/xlh123jjj/moonbit-visual-debug) 和 [moonbit-robot-vision-formats](https://mooncakes.io/docs/ppyj663/moonbit-robot-vision-formats) 主要提供视觉调试、格式交换和机器人视觉数据处理；发布前仍需复查 Mooncakes 名称和同类包。

一次 Windows native release 对照中，单图单类 10,000 个随机排序的不相交合成框的处理耗时中位数从 0.379 秒降至 0.142 秒；10,000 个完全重合的框分别为 0.110 秒和 0.110 秒。每组预热一次并交替测量三次，包含进程启动和 JSON 开销；这些数字不是生产吞吐量。对 200 张图的 11,657 个真实切片预测，新旧输出逐字节一致。[复现脚本](validation/nms_scale.py)和[完整结果](validation/nms-scale-results.json)记录参数、输入及二进制哈希。

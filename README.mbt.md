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

## 使用与行为

`plan_tiles(width, height, tile_width, tile_height, overlap_x, overlap_y)` 生成覆盖原图的窗口，按照从上到下、从左到右编号。重叠量以整数像素表示；最后窗口贴住图像边缘，因此其实际重叠量可能大于请求值。图像小于窗口时，窗口尺寸缩小到图像尺寸。为避免意外分配，最多生成 100 万窗口。

需要按需处理大图窗口时，可以用相同参数创建 `TileGrid::new(...)`，通过 `length()` 获取总数，再用 `get(id)` 按编号读取窗口；无效编号返回 `None`。网格只保存布局参数，不分配完整窗口数组，便于调用方逐个裁剪、推理或分批处理。`plan_tiles` 基于同一网格生成数组，两种方式的编号和坐标一致；创建网格时会先检查总数，超过 100 万立即报错。`plan_tiles`、JSON 和 CLI 仍会为合法规划生成完整数组，内存使用随窗口数量增长。

外部程序可以使用 `moon run cmd/main --target native -- examples/plan.json --plan` 获取切片，或者调用 `plan_json`。请求包含图像尺寸 `image_width`、`image_height`，窗口尺寸 `tile_width`、`tile_height`，以及重叠像素 `overlap_x`、`overlap_y`；所有字段必须为 32 位整数。返回对象包含图像尺寸和 `tiles` 数组，数组项为 `{id,x,y,width,height}`。错误时 CLI 写入标准错误并以非零状态退出，不输出部分窗口。`examples/plan-consumer.mjs` 展示外部 Node.js 程序先获取窗口，再将窗口与预测组装为处理输入；示例预测是合成数据，实际使用时应替换为检测器对对应窗口产生的局部预测。JavaScript 构建还导出 `moontile_plan`，错误以带 `error` 字段的 JSON 对象返回。

`restore(tile, detection, image_width, image_height)` 验证切片和局部框并平移到原图。窗口边界采用半开区间；框使用连续 `xyxy`，面积为 `(x2-x1)*(y2-y1)`，不做 `+1`。局部框必须完全位于切片内，允许坐标位于切片边缘，不自动裁剪；退化、非有限、面积数值下溢以及平移后因浮点舍入失去正面积的框会被拒绝。检测分数须在 `[0,1]`，标识符和类别必须非负。

模型输出仍处于缩放、填充后的输入坐标时，可使用 `restore_model(tile, detection, image_width, image_height, transform)`。`ModelTransform` 描述实际预处理：`model_x = local_x * scale_x + pad_x`，纵轴同理；缩放必须为有限正数，左侧和顶部填充必须为有限非负数。框必须是模型输入上的绝对连续 `xyxy` 像素坐标，调用方负责提供实际缩放和填充值；已被推理框架还原的框应直接使用 `restore`。`clip=false` 时越出切片的框报错；`clip=true` 时先裁剪到切片，完全落在填充区或裁剪后失去面积的框仍报错。非有限结果、数值溢出和无效输入均被拒绝。

JSON 每个切片可选择性增加 `transform`，各切片可以使用不同参数，也可以和原有切片局部坐标混用，见 [examples/model-input.json](examples/model-input.json)。省略该字段沿用原有行为；即使检测列表为空也会验证变换参数。所有合并、COCO 和 MBMOT 输出共用同一转换流程。

`suppress(detections, threshold, metric, class_agnostic=...)` 按得分降序执行贪心 NMS，同分保持输入顺序。默认按图像和类别分别处理；`class_agnostic=true` 只取消类别隔离，图像之间仍互不影响。支持 IoU 和交集除以较小框面积的 IoS，重叠度 **严格大于** 阈值时抑制。检测 ID 在同一调用中必须唯一，返回的抑制记录指出保留框 ID、被抑制框 ID 和重叠度。处理前会验证整个输入，错误不会返回部分结果。当前实现最坏需要比较二次方数量的框；CLI 一次读取完整文件，大规模输入应由调用方按图像拆分和限制大小。

对于跨切片的部分框，可以选择 `merge_envelopes`：先按分数和输入顺序选出种子，将与**原始种子框**重叠度严格超过阈值的框归入同一组，并输出覆盖整组的外接框。匹配不使用不断扩大的外接框，也不进行传递合并；代表框保留种子的 ID、图像、切片、类别与最高分，其他成员及其与种子的重叠度记录在 `suppressed` 中。默认按图像和类别隔离；`class_agnostic=true` 时可以跨类别合并，输出仍采用种子的类别。高重叠目标可能被合为一个框，阈值需结合具体数据验证。

`process_json` 使用 [examples/input.json](examples/input.json) 所示结构：每组包含窗口和属于该窗口的局部预测，返回 `restored`、`kept` 和 `suppressed`。可选字段 `strategy` 默认是 `"nms"`；设置为 `"greedy_nmm"` 后输出外接框，示例见 [examples/partial-input.json](examples/partial-input.json)。在合并策略下，`suppressed` 的记录表示被归入代表框的成员，`overlap` 相对于原始种子框。相同输入也能使用 COCO 导出、MBMOT 导出和流处理。CLI 用这些 API 执行同一流程；空切片同样会校验。序列处理时可逐帧调用，并自行保证帧号和跟踪器状态。

MoonBit 调用方可以使用类型化的 `process_tiles(image_width, image_height, tiles, config)` 一次完成还原和合并，无需组装 JSON。`TilePredictions` 包含 `tile`、`detections` 和可选 `transform`；`MergeConfig` 指定阈值、重叠度量、是否跨类别处理以及 `Nms` 或 `GreedyNmm` 策略。结果的 `restored` 保持输入顺序，`merged` 包含排序后的保留框和溯源记录。所有切片在一次调用中共用图像尺寸；不同图像 ID 的框互不合并，检测 ID 在整个调用中必须唯一。任一切片或检测无效时返回错误，不返回部分结果。完整类型化接入示例见 [examples/consumer/bridge_wbtest.mbt](examples/consumer/bridge_wbtest.mbt)。

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

`validation/real_coco.py` 使用先前保存的 COCO val2017 标注和 YOLO11n 整图预测，先核对文件哈希，再将整张图作为单个切片重放。已运行 10 张图、2136 个预测，pycocotools 的 12 项 bbox 指标在重放和 COCO 导出后均与原结果一致；记录见 `validation/real-coco-results.json`。这验证真实整图数据的坐标和评估链路，不是逐切片推理或精度提升验证。真实逐切片预测数据仍未取得。

`validation/real_video.py` 重放 MBMOT 现有演示的 OpenCV HOG 检测流，将每帧整图作为一个窗口，经单个 MoonTile 流处理进程转成 MBMOT 输入，再与直接输入原始检测流的跟踪结果逐帧比较。已验证 90 帧、291 个检测，跟踪输出全部一致；其中 80 帧的输入检测并非按分数降序排列。来源、二进制哈希和命令见 `validation/real-video-results.json`。本验证没有使用真实切片推理，也不衡量跟踪精度。

## 边界与参考

只处理二维轴对齐框；不包含掩码合并、旋转框、模型推理或视频解码。后处理参考 [SAHI](https://github.com/obss/sahi) 的公开问题定义；已验证范围和已知差异见上文。本项目为独立实现，Apache-2.0 许可。已有 [moonbit-visual-debug](https://mooncakes.io/docs/xlh123jjj/moonbit-visual-debug) 和 [moonbit-robot-vision-formats](https://mooncakes.io/docs/ppyj663/moonbit-robot-vision-formats) 主要提供视觉调试、格式交换和机器人视觉数据处理；发布前仍需复查 Mooncakes 名称和同类包。

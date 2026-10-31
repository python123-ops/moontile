# MoonTile

MoonTile 将多个图像切片上的目标检测框还原到原图坐标，并按类别执行非极大值抑制（NMS）。核心由 MoonBit 实现，不运行模型，也不读取或裁剪图片。它可作为检测器与 [MBMOT](https://github.com/python123-ops/mbmot) 跟踪、[MoonDetEval](https://github.com/python123-ops/moondeteval) 评估之间的组件。

当前已在 GitHub 开源，尚未发布到 Mooncakes。使用 MoonBit 0.10.14 工具链在源码目录运行：

```sh
moon test --target all --deny-warn
moon run cmd/main --target native -- examples/input.json
moon -C examples/consumer test --target all --deny-warn
node web/build.mjs
node web/test.mjs
```

`moon run` 读取 JSON 文件，成功时向标准输出写入一个 JSON 对象；错误写入标准错误并返回退出码 2。示例为合成数据。运行 `node web/build.mjs` 后，从 `_build/site` 启动静态 HTTP 服务并打开 `index.html`。页面调用编译为 JavaScript 的同一 MoonBit 核心。

## 使用与行为

`plan_tiles(width, height, tile_width, tile_height, overlap_x, overlap_y)` 生成覆盖原图的窗口，按照从上到下、从左到右编号。重叠量以整数像素表示；最后窗口贴住图像边缘，因此其实际重叠量可能大于请求值。图像小于窗口时，窗口尺寸缩小到图像尺寸。为避免意外分配，最多生成 100 万窗口。

`restore(tile, detection, image_width, image_height)` 验证切片和局部框并平移到原图。窗口边界采用半开区间；框使用连续 `xyxy`，面积为 `(x2-x1)*(y2-y1)`，不做 `+1`。局部框必须完全位于切片内，允许坐标位于切片边缘，不自动裁剪；退化、非有限、面积数值下溢以及平移后因浮点舍入失去正面积的框会被拒绝。检测分数须在 `[0,1]`，标识符和类别必须非负。

`suppress(detections, threshold, metric, class_agnostic=...)` 按得分降序执行贪心 NMS，同分保持输入顺序。默认按图像和类别分别处理；`class_agnostic=true` 只取消类别隔离，图像之间仍互不影响。支持 IoU 和交集除以较小框面积的 IoS，重叠度 **严格大于** 阈值时抑制。检测 ID 在同一调用中必须唯一，返回的抑制记录指出保留框 ID、被抑制框 ID 和重叠度。处理前会验证整个输入，错误不会返回部分结果。当前实现最坏需要比较二次方数量的框；CLI 一次读取完整文件，大规模输入应由调用方按图像拆分和限制大小。

`process_json` 使用 [examples/input.json](examples/input.json) 所示结构：每组包含窗口和属于该窗口的局部预测，返回 `restored`、`kept` 和 `suppressed`。CLI 用这个 API 执行同一流程；空切片同样会校验。序列处理时可逐帧调用，并自行保证帧号和跟踪器状态。

## 项目关联与验证

`examples/consumer` 是独立 MoonBit 模块，通过 workspace 引用源码，固定已发布的 MBMOT 0.3.0 和 MoonDetEval 0.1.0，展示框转换、显式类别映射、跟踪和 AP50 评估。当前测试是合成样例，不代表模型精度。更高版本的 MoonDetEval 0.2.x 在本机 0.10.14 编译器上因 `Int32` 不可识别而未通过；不能将该 consumer 的结果推广到那些版本。

浏览器与原生 CLI 的 JSON 输出由 `web/test.mjs` 对照；核心测试覆盖切片、还原、NMS、类别隔离、同分、边界和非法输入。

`validation/sahi_compare.py` 从固定的 SAHI 0.11.14 源码中提取原始 NMS 函数，并以 PyTorch 运行参考实现。固定种子的 80 组、每组 25 框的单图单类别无同分场景覆盖 IoU 和 IoS；结果见 `validation/sahi-results.json`。本库在重叠度等于阈值时保留，SAHI 0.11.14 在相等时抑制；脚本单独验证这一差异。本对照未涵盖切片布局、多类别或同分行为。

`validation/real_coco.py` 使用先前保存的 COCO val2017 标注和 YOLO11n 整图预测，先核对文件哈希，再将整张图作为单个切片重放。已运行 10 张图、2136 个预测，pycocotools 的 12 项 bbox 指标重放前后一致；记录见 `validation/real-coco-results.json`。这验证真实整图数据的坐标和评估链路，不是逐切片推理或精度提升验证。真实逐切片预测数据仍未取得。

## 边界与参考

只处理二维轴对齐框；不包含掩码合并、旋转框、模型推理或视频解码。后处理参考 [SAHI](https://github.com/obss/sahi) 的公开问题定义；已验证范围和已知差异见上文。本项目为独立实现，Apache-2.0 许可。已有 [moonbit-visual-debug](https://mooncakes.io/docs/xlh123jjj/moonbit-visual-debug) 和 [moonbit-robot-vision-formats](https://mooncakes.io/docs/ppyj663/moonbit-robot-vision-formats) 主要提供视觉调试、格式交换和机器人视觉数据处理；发布前仍需复查 Mooncakes 名称和同类包。

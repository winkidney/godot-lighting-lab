# Godot Lighting Lab · 光照实验室

一个用来学习**法线、光照模型、阴影、全局光照、后处理和场景氛围**的 Godot 4.7 交互实验项目。

项目分为 5 个学习模块。每个模块都有：

- 一个参考场景
- 一组可调参数：控件上显示英文属性名，悬停后在底部显示中文说明
- 一组预设，包括刻意制造问题的“故障演示”
- 一套通用调试工具：引擎 Debug View、A/B 快照对比、GPU 耗时统计、参数导出

所有贴图和几何体都由代码程序生成，项目不依赖任何外部素材。

## 运行

需要 Godot **4.7.x**（标准版即可，不需要 .NET 版本），以及支持 Vulkan 的显卡。项目使用 **Forward+** 渲染器，因为 SDFGI、VoxelGI、体积雾、SSR、SSIL 都只在 Forward+ 下可用。

```bash
make run              # 打开实验室 (从模块 01 开始)
make run MODULE=4     # 直接打开模块 04
make editor           # 用 Godot 编辑器打开项目
make validate         # 无窗口校验：所有模块/参数/预设 + UI 冒烟测试
make capture          # 开窗口，把每个模块 × 每个预设截图到 captures/
make capture ONLY=03  # 只截某个模块 (可用逗号分隔多个)
```

脚本会在 `PATH`、`$GODOT` 和 `~/.local/bin/godot` 中查找 Godot 可执行文件。

## 界面

| 区域 | 内容 |
| --- | --- |
| 顶栏 | **Debug View** 下拉框（引擎内置调试视图）、A/B 快照、导出参数、截图、帮助 |
| 左栏 | 模块列表、预设/配方列表（点击即应用）、机位书签 |
| 右栏 | 参数面板（按组折叠）：第一行是英文属性名、中文简称和“默认”按钮，第二行是编辑控件 |
| 底栏 | 说明面板：模块概述、预设说明、当前悬停参数的详细解释 |
| 左上角 | FPS、CPU 时间、**GPU 时间**、draw calls、图元数、显存 |

| 操作 | 功能 |
| --- | --- |
| 左键 / 右键拖拽 | 环绕相机 |
| 中键或 Shift + 拖拽 | 平移 |
| 滚轮 | 缩放 |
| W A S D / Q E | 移动观察点 |
| `1` / `2` / `Tab` | 把当前参数存为快照 A / 存为快照 B / 在 A、B 之间切换 |
| `F` | 回到默认机位 |
| `H` | 隐藏或显示界面（隐藏后画面不再被面板遮挡） |
| `F12` | 截图到 `captures/` |
| `F1` | 帮助 |

相机使用离轴投影（lens shift），所以观察中心始终落在左右面板之间的空白区域。

## 学习路线

建议按顺序学习。每个模块先读底部的「概述」和其中的「试一试」，再依次点开左侧预设。

1. **01 法线与法线贴图**
   - 内容：顶点法线与平滑组、切线空间 (TBN)、法线贴图编码、OpenGL 与 DirectX 绿通道约定、色彩空间错误、缺失切线、用高度求导的 bump mapping。
   - 调试模式：view_mode 可以把世界法线、视图法线、切线、副切线、UV、贴图原色、扰动后的法线、N·L 直接画成颜色。
2. **02 光照模型对比**
   - 内容：在 `light()` 里手写 Lambert、Half-Lambert、Phong、Blinn-Phong、Toon，与 Godot PBR 并排对比；roughness × metallic 球阵。
   - 调试方法：用 `term_view` 单独显示 N·L、N·H、菲涅尔等单项；用箭头可视化 N/L/V/H/R 五个向量。
3. **03 光源类型与阴影**
   - 内容：平行光、点光、聚光（含投影纹理）、面光源（AreaLight3D，4.7 新增）。
   - 阴影参数：bias、normal bias、PSSM 级联、PCSS 软阴影、阴影图集与过滤质量。
   - 故障演示：阴影痤疮、peter-panning、级联接缝、阴影距离过短。
4. **04 GI、环境与后处理**
   - 场景：Cornell box 风格的房间。
   - 内容：SDFGI、VoxelGI（运行时烘焙）、反射探针、SSAO、SSIL、SSR、天空与环境光、5 种色调映射、辉光、距离雾与高度雾、体积雾与 FogVolume、自动曝光、景深、1D/3D LUT 调色、抗锯齿与渲染缩放。
5. **05 场景氛围配方**
   - 7 个配方：晴朗正午、黄金时刻、阴天柔光、月夜、丁达尔光、霓虹雨夜、恐怖。
   - **12 个图层**可以逐个关掉，用来拆解每一层在配方中的贡献。
   - 任意两个配方之间可以插值；`time_of_day` 驱动日夜循环。
   - 自定义后处理 shader：暗角、颗粒、色差、色调、暗部提升。

更多资料：

- 概念速查：[docs/concepts.md](docs/concepts.md)
- 光照问题排查清单（症状 → 原因 → 用哪个 Debug View 看 → 怎么修）：[docs/debug-checklist.md](docs/debug-checklist.md)

## 推荐的调试习惯

- **先隔离，再调整**：先用 Debug View 只看一种贡献，例如 Lighting、Normal Buffer、SSAO、SDFGI、PSSM Splits，确认问题出在哪一层，再去改参数。
- **A/B 对比**：改参数前按 `1` 存为 A，改完按 `2` 存为 B，然后用 `Tab` 来回切换。比凭记忆对比可靠得多。
- **看 GPU 时间**：打开或关闭一个效果，观察左上角的 GPU ms 变化，就能估算它的开销。
- **导出参数**：把与默认值不同的参数复制到剪贴板（格式为 `key = 值  # 节点.属性 说明`），可以作为笔记，或者搬到自己的项目里。

## 项目结构

```
scenes/main.tscn, scenes/modules/*.tscn   场景只挂脚本，内容全部由代码生成
scripts/lab/lab_module.gd                  模块基类：参数注册、读写、预设、插值、快照、校验
scripts/lab/lab_shell.gd                   主界面：模块切换、预设、Debug View、A/B、截图
scripts/lab/param_panel.gd                 根据参数规格自动生成 UI
scripts/lab/orbit_camera.gd                环绕相机 (离轴投影)
scripts/lab/vector_gizmos.gd               TBN 线框与光照向量箭头
scripts/lab/perf_overlay.gd                性能统计
scripts/lib/proc_textures.gd               高度图 → Sobel → 法线贴图；cookie 投影纹理；1D/3D LUT
scripts/lib/mesh_tools.gd                  重建平直/平滑法线，去掉或翻转切线
scripts/lib/scene_kit.gd                   几何体、材质、灯光、环境、色温
scripts/modules/0X_*.gd                    5 个学习模块
shaders/normal_common.gdshaderinc          手写的 TBN 法线贴图与 bump mapping
shaders/normal_map_lab.gdshader            带光照的法线贴图材质
shaders/normal_debug.gdshader              向量可视化 (无光照)
shaders/lighting_models.gdshader           在 light() 中实现的经典光照模型
shaders/post_process.gdshader              全屏自定义后处理
tools/run.py                               启动 / 校验 / 截图入口
tools/validate_runtime.gd                  无窗口校验 (参数/预设)
tools/ui_smoke_test.gd                     UI 冒烟测试 (滑杆/开关/下拉、A/B、配方插值、图层)
tools/capture_runtime.gd                   批量截图
```

### 添加参数或预设

在模块的 `_build_params()` 中调用对应的注册函数：

```gdscript
group("Shadows 阴影")
add_range("sun.shadow_bias", _sun, "shadow_bias", 0.0, 4.0, 0.005, "深度偏移：……说明……")
add_enum("env.tonemap_mode", _env, "tonemap_mode", [["Linear", 0], ["AgX", 4]], "色调映射：……")
add_bool("layer.fog", self, "layer_fog", "雾图层：……", {"meta": true})
```

各参数的含义：

- `target`：要修改的对象，可以是节点、Resource，也可以是模块脚本自己的代理变量（在 setter 里做联动）。
- `property`：目标对象上真实的属性名；对 ShaderMaterial 可以写成 `shader_parameter/<uniform>`。
- tip 的写法：第一个 `：` 之前的文字会作为中文简称显示在控件旁边。

预设在 `get_presets()` 中返回，内容是相对默认值的差异：

```gdscript
"预设名": {"sun.shadow_bias": 0.0, "_note": "说明", "_camera": "机位名", "_debug": Viewport.DEBUG_DRAW_PSSM_SPLITS}
```

修改后运行 `make validate`。它会检查：

- 每个属性是否真实存在
- 每个参数取最小值、最大值和默认值时能否正常写入
- 每个预设引用的 key、值的类型和机位名是否正确

## 教学视频

`video/` 目录用实验室自己录一条约 8 分钟的简体中文教学视频。画面由导演脚本自动驱动实验室生成（切换模块、套用预设、平滑拖动参数、切换 Debug View、运镜），再用 Godot 的 Movie Maker 按固定 30 fps 逐帧渲染，所以运行时的卡顿不会出现在成片里。

```bash
make video-check                 # 校验 plan.json 引用的模块/预设/参数/机位 (也包含在 make validate 中)
make video-tts                   # 逐句配音 (需要 Asset Workbench、Higgs 模型与 AW_TTS_PROJECT/AW_TTS_REFERENCE，GPU 忙时自动等待)
make video-assemble              # 时间轴、旁白混音 (-16 LUFS)、字幕 (ass/srt)、章节、讲稿
make video-preview CH=c2 FROM=c2s4   # 实时预览某一章 (无声音)
make video-render [CH=c1,c2] [JOBS=4]  # Movie Maker 渲染，每章一个进程，可并行；编码后删除 PNG
make video-encode                # 拼接 + 烧录字幕 + 混入旁白
make video-verify                # 时长、黑场、响度、每个镜头的抽帧总览图
make video-covers                # B 站封面 16:9 (1920×1080) 与 4:3 (1600×1200)
make video-bgm [SRC=曲子.m4a]    # 背景音乐：按乐句拼接补足时长、侧链压低、混音，输出 *-bgm.mp4
make video-records               # 把制作记录复制到 video/records/ (入库)
```

| 文件 | 作用 |
| --- | --- |
| `video/plan.json` | 分章、分镜头的讲稿与动作时间轴，唯一的事实来源。`sub` 是字幕，`say` 是给 TTS 的读法（如 “N 点乘 L”），`seed` 可按句覆盖 |
| `video/pipeline.py` | 各阶段入口；所有时间都对齐到整帧，旁白、字幕和导演的帧时钟一致 |
| `video/aw_tts.py` | 按句提交 AW `audio.tts`（Higgs TTS 3 Q8_0 参考克隆），按文本哈希缓存；显存被占用时等待，失败自动重试 |
| `video/asr_check.py` | 可选：离线 Whisper 转写后与讲稿按拼音比对，只作辅助，最终以人工试听为准 |
| `video/mix_bgm.py`、`video/bgm.json` | 背景音乐：参数与分析记录在 json 中（来源哈希、拼接点、电平、侧链），脚本按它复现混音；画面与字幕原样复制 |
| `video/build_covers.py` | 封面：干净的实机截图 (隐藏叠加层) + Z 工坊像素黑体 (原生 12px 整数倍放大) |
| `video/fonts/` | Z Labs Pixel 12px 简中字体、SIL OFL 1.1 许可与来源 |
| `video/records/` | 这一版成片的制作记录：每句配音的 AW 任务/seed/哈希、渲染与编码来源、验证结果、ASR 核对、封面记录、发布说明与章节 |
| `tools/tutorial_director.gd` | 导演脚本：`--check` 校验、`--chapter` 渲染/预览、`--stills [--clean --at=shot:秒]` 截图 |
| `scripts/tutorial/tutorial_overlay.gd` | 章节标题卡、参数 HUD、公式卡、进度条、片尾卡 |

制作要点：

- **配音**：参考音色是 AW 自带的 Kokoro zf_001 合成女声，不是真人录音。Higgs 的许可要求注明 “This audio was created with Boson AI's Higgs Audio: https://www.boson.ai/higgs-audio”，片尾卡和发布说明里都已包含。配音前设置 `AW_TTS_PROJECT`（一个带 audio 领域规格的 AW 项目，原始配音与每句的任务记录都留在这里）和 `AW_TTS_REFERENCE`（AW 自带音频范例所在目录）。建议用 `aw project init --runtime ""` 绑定该项目，这样 `aw up` 不会拉起共享 H3 服务。
- **渲染**：Movie Maker 按项目视口尺寸录制，所以渲染期间用临时 `override.cfg` 设为 1920×1080，结束后自动删除。PNG 编码在 Godot 主线程上，单进程约 5–7 帧/秒；`JOBS=5` 并行时约 30 帧/秒（每个进程约需 1–1.5 GB 显存）。
- **入库范围**：源码与 `video/records/` 入库；成片、帧、分章视频、旁白混音、字幕与封面图都可以由上面的命令重新生成，留在 `video/build/` (已忽略)。

## 已知问题

- **SDFGI 需要几帧收敛**；切换到 VoxelGI 时会在运行时烘焙一次，画面会卡顿片刻。
- **LightmapGI** 只能在编辑器里烘焙，所以只在文档里介绍，没有放进运行时切换。
- 在模块 04 打开过反射探针后退出，Godot 4.7.2 会打印 `7 RIDs of type "Texture" were leaked`。这是引擎在退出时释放资源的行为，不影响使用。
- `ambient_light_energy` 的坑：环境光来源为 Sky 且 `ambient_light_sky_contribution = 1` 时，`ambient_light_energy` **完全不起作用**，它只缩放 `ambient_light_color` 那一部分。所以本项目用 `sky_contribution` 作为天空环境光的强度旋钮。

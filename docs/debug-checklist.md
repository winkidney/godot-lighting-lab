# 光照问题排查清单

通用排查步骤：

1. 先用顶部 **Debug View** 只看某一层贡献，确定问题出在哪一层。
2. 然后用 **A/B 快照**（`1` / `2` / `Tab`）验证每一次修改的效果。
3. 留意左上角的 **GPU ms**，避免为修一个小问题付出过大的性能代价。

## 阴影

| 症状 | 可能原因 | 怎么看 | 怎么修 |
| --- | --- | --- | --- |
| 表面布满条纹或摩尔纹（阴影痤疮） | `shadow_bias` / `shadow_normal_bias` 太小；光线掠射 | 降低太阳仰角时更明显（模块 03 预设 ①） | 先加 `shadow_normal_bias`，再微调 `shadow_bias` |
| 阴影和物体脱开、薄物体没有阴影 | bias 太大 | 看接触点（模块 03 预设 ②） | 降低 bias；把薄物体做厚一点 |
| 远处没有阴影 | 超出 `directional_shadow_max_distance` | Debug View → PSSM Splits | 增大 `max_distance`（会降低精度）或启用 `fade_start` |
| 阴影清晰度在某个距离突变 | 级联交界 | PSSM Splits | 开启 `blend_splits`；调整 `split_1/2/3` |
| 阴影锯齿、细小物体的阴影闪烁 | 阴影图集分辨率低；过滤质量为 Hard | Directional Shadow Atlas | 增大图集；提高 soft filter 质量；缩短 `max_distance` |
| 点光阴影边缘扭曲 | 使用 Dual Paraboloid 模式且模型面数低 | Shadow Atlas | 改用 Cube 模式 |
| 背光面的 Half-Lambert 或 wrap 光照不起作用 | `light()` 中的 `ATTENUATION` 包含自身阴影 | 模块 02 预设 ⑨ | 对该物体关闭投影，或者单独处理阴影 |

## 法线与材质

| 症状 | 可能原因 | 怎么看 | 怎么修 |
| --- | --- | --- | --- |
| 凹凸方向反了（凸起像凹陷） | 法线贴图是 DirectX 约定 | 掠射光下观察（模块 01 预设 ⑦） | 导入时翻转绿通道 |
| 表面整体偏暗，像被某个方向的光压着 | 法线贴图被当成 sRGB 颜色采样 | view_mode → Normal Map Texel | 按 Normal Map（线性数据）导入 |
| 法线贴图方向随机错乱 | 网格缺少切线 | view_mode → Tangent | 导出或导入时生成切线（MikkTSpace） |
| 镜像 UV 的接缝处凹凸反转 | 切线手性（w）处理不当 | view_mode → Binormal | 重新烘焙；检查导出设置 |
| 硬边物体出现奇怪的渐变 | 法线被平滑过了 | 模块 01 预设 ③ | 设置硬边或平滑组；拆分顶点 |
| 远处的细节闪烁 | 高光走样或法线贴图走样 | 移动相机观察 | 开启 TAA；生成 mipmap；提高粗糙度 |

## 亮度与颜色

| 症状 | 可能原因 | 怎么看 | 怎么修 |
| --- | --- | --- | --- |
| 暗部死黑 | 没有环境光或 GI | Debug View → Lighting / GI Buffer | 启用天空环境光、SDFGI 或 VoxelGI，或加补光 |
| 调 `ambient_light_energy` 没有效果 | 来源为 Sky 且 `sky_contribution = 1` | — | 改用 `ambient_light_sky_contribution`，或调整天空亮度 |
| 高光变成一片纯色或死白 | 使用了 Linear 色调映射，或曝光过高 | Debug View → Internal Buffer | 改用 AgX 或 ACES；降低曝光 |
| 画面整体发灰、缺少对比 | 曝光或色调映射的白点不合适；雾太浓 | 关掉 Fog 或 Volumetric 图层对比 | 调整 `tonemap_white` 或 AgX 的 contrast；降低雾密度 |
| 室内亮度时明时暗 | 开启了自动曝光 | Debug View → Scene Luminance | 调小 `auto_exposure_speed` 或收窄 min/max 感光度范围 |
| 发光物体不发光 | `emission_energy` 不够；辉光阈值太高 | — | 提高 emission；降低 `glow_hdr_threshold` |

## 全局光照与反射

| 症状 | 可能原因 | 怎么看 | 怎么修 |
| --- | --- | --- | --- |
| 室内漏光，墙外的光透进来 | 墙比 SDFGI 体素还薄 | Debug View → SDFGI | 把墙做厚；减小 `min_cell_size`；开启 `use_occlusion` |
| 室内被天空光照得过亮 | SDFGI 读取了天空光 | — | 关闭 `sdfgi_read_sky_light`；VoxelGI 开启 `interior` |
| 移动物体后 GI 不更新 | VoxelGI 或 Lightmap 是烘焙结果 | — | 重新烘焙；动态场景改用 SDFGI |
| 镜面地板的反射边缘突然消失 | SSR 只能反射屏幕内的内容 | 转动相机观察 | 加 ReflectionProbe 作为兜底；调整 `ssr_fade_out` |
| 室内反射位置不对 | 反射探针没有开盒体投影 | — | 开启 `box_projection`，并让探针盒子贴合房间 |

## 雾与体积雾

| 症状 | 可能原因 | 怎么修 |
| --- | --- | --- |
| 看不到光柱 | 体积雾密度太低；`anisotropy` 太小；没有遮挡物制造缝隙 | 提高密度和 `anisotropy`；加大光源的 `light_volumetric_fog_energy`；降低环境光 |
| 画面被雾“洗白” | 体积雾太浓；雾覆盖了天空 | 降低密度；减小 `volumetric_fog_sky_affect` |
| FogVolume 不显示 | 没有开启全局体积雾 | 开启 `volumetric_fog_enabled`（全局密度可以设为 0） |
| 移动相机时雾有拖影 | 开启了时间重投影 | 降低 `temporal_reprojection_amount` 或关闭它 |
| 体积雾出现块状或条带 | froxel 分辨率不足 | 缩短 `volumetric_fog_length`；调整 `detail_spread` |

## 性能

| 现象 | 排查方法 |
| --- | --- |
| GPU 时间偏高 | 在模块 05 里逐个关掉 Volumetric、GI、Screen Space 图层，看 GPU ms 下降了多少 |
| 灯多以后变慢 | 用 Debug View → Cluster Omni/Spot Lights 观察每个屏幕区块受多少盏灯影响；减小 range；只给少数灯开阴影 |
| 阴影开销大 | 点光阴影要渲染 6 次；减少投影的点光数量，或改用聚光 |
| 画面整体太贵 | `scaling_3d_scale` < 1，配合 FSR 2（模块 04 的 Viewport 组） |

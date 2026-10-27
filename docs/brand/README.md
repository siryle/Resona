# Resona 视觉标识

品牌名来自 resonance（共鸣）的联想。标识将字母 **R**、黑胶唱片和向外扩散的声波融合，表达“整理自己的音乐，让收藏产生共鸣”。

- `resona-brand.png`：横向品牌展示稿。
- `resona-icon.png`：独立方形图标原图。
- `../../internal/web/static/icon.png`：Web 使用版本。
- `../../ios/Resona/Assets.xcassets/AppIcon.appiconset/AppIcon.png`：iOS 1024 × 1024 图标，由系统裁切圆角。
- `../../ios/Resona/Assets.xcassets/BrandIcon.imageset/BrandIcon.png`：客户端界面内标识。

色彩以暖橙 `#C45A37`、墨黑 `#292C27`、暖白 `#F6F4EF` 和鼠尾草绿 `#E9EDDF` 为主，界面沿用这一组颜色。Logo 的生成图存在轻微色彩和质感变化，界面色值以设计令牌为准。

使用内置 imagegen 生成，两次提示分别为品牌展示与独立图标。生成提示摘要：

> Resona self-hosted music library identity. Merge R, a vinyl record and resonant wave arcs into a memorable simple emblem. Warm burnt orange, espresso black and ivory. Elegant contemporary wordmark, generous negative space, independent hi-fi label aesthetic. Standalone square iOS icon uses an ivory emblem on orange, without text or baked-in rounded corners.

完整提示词见 [prompts.md](prompts.md)。

当前交付为 PNG 视觉资产；需要印刷或严格单色应用时，可进一步制作人工校准的矢量母版。

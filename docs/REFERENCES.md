# 设计参考

- [missuo/kumone](https://github.com/missuo/kumone)：原生 SwiftUI 的音乐库、专辑展示、迷你播放器与沉浸播放体验参考。Resona 客户端统一连接自己的 Go 服务端。
- [jxxghp/MoviePilot](https://github.com/jxxghp/MoviePilot)：任务化的识别、刮削、整理、入库及错误记录流程参考。Resona 实现的是音乐工作流，不依赖 MoviePilot Python 服务。
- [seed680/moviepilot-plugins](https://github.com/seed680/moviepilot-plugins)：音乐保存机器人与 Telegram 本地 API 插件的功能移植；Go 实现接入 Resona 的鉴权、持久化与入库。版本、来源提交和 GPL 许可见 [第三方声明](../THIRD_PARTY.md)。
- [amarnathcjd/gogram](https://github.com/amarnathcjd/gogram)：本地音乐接收的纯 Go MTProto 协议实现，固定版本源码随仓库交付，无需构建外部 Telegram Bot API / TDLib。
- [MusicBrainz Web Service](https://musicbrainz.org/doc/MusicBrainz_API)：在线音乐元数据。请求串行限流，间隔至少 1.1 秒；标题和艺术家必须匹配，已知时长偏差不超过 5 秒，只补充缺失字段。
- [Cover Art Archive](https://coverartarchive.org/)：匹配到正式发行版本后尝试获取封面，下载内容有大小和图片尺寸上限，缓存为 JPEG。
- [FFmpeg / FFprobe](https://ffmpeg.org/)：音频标签读取和本地封面提取，作为容器系统工具调用。
- [LRCLIB API](https://lrclib.net/docs)：在线同步歌词及纯文本歌词。按标题、艺术家、专辑及时长匹配，串行限流并遵守 `Retry-After`，下载失败保留已有歌词。

本项目未复制 Kumone 或 MoviePilot 主项目的源码或图像；移植的 Seed680 插件保留来源及许可声明。服务端采用 Go 标准库、已纳入仓库的 Go MTProto 协议源码、内嵌 HTML / CSS / JavaScript，客户端采用 Apple 系统框架。外部元数据及封面可能受各自的授权和服务条款约束。

QQ、网易云、酷狗与 iTunes 来源由独立 Go 适配器接入，客户端仍只连接 Resona。公开接口可能变化；仅列出已验证可用的来源，不提供需要额外账号或未验证的适配器。

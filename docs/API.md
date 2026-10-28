# Resona API v1

同源 Web 使用 `HttpOnly`、`SameSite=Strict` 会话 Cookie；原生客户端使用 `Authorization: Bearer <token>`。除健康检查、初始化状态、首次设置和登录之外，所有接口都需要认证。所有 JSON 写请求必须设置 `Content-Type: application/json`，跨域写请求会被拒绝。

## 初始化与登录

```http
GET /api/v1/auth/status
```

响应示例：`{"initialized": false, "username": "admin"}`。

首次访问须先设置密码，部署不需要密码环境变量：

```http
POST /api/v1/auth/setup
Content-Type: application/json

{"password": "a-strong-password-you-choose"}
```

成功返回 `201 {"initialized":true}`。仅能成功一次；密码少于 8 个字符或超过 1024 字节返回 `400`；已初始化返回 `409`。密码设置和登录为两个独立操作。

```http
POST /api/v1/auth/login
Content-Type: application/json

{"username":"admin","password":"a-strong-password-you-choose"}
```

响应包含 `token`、`username`、`expires_in`（604800 秒）并设置浏览器 Cookie。未初始化返回 `428`，凭据不正确返回 `401`。同一直接连接 IP 在 15 分钟内最多 8 次登录尝试，成功登录重置计数，超限返回 `429`。最多同时保留 128 个活跃会话。会话持久化，服务重启不使其失效；过期或主动退出后需重新登录。

`GET /api/v1/auth/session` 查询当前账号，`POST /api/v1/auth/logout` 注销当前会话。

## 音乐库

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/healthz` | 无需登录，返回服务状态和版本 |
| GET | `/api/v1/system` | 版本、曲目 / 专辑 / 艺术家数、总大小 / 时长、目录配置 |
| GET | `/api/v1/tracks` | 分页歌曲列表 |
| GET | `/api/v1/tracks/{id}` | 单首歌曲 |
| GET | `/api/v1/tracks/{id}/matches` | 搜索候选；可选 `title`、`artist`、`source` |
| PUT | `/api/v1/tracks/{id}/metadata` | 保存人工更正并锁定元数据 |
| PUT | `/api/v1/tracks/{id}/favorite` | `{"favorite":true}` 或 `false` |
| GET / HEAD | `/api/v1/tracks/{id}/stream` | 原始音频，支持 HTTP Range / 206 |
| GET | `/api/v1/tracks/{id}/cover` | 已缓存的 JPEG 封面 |
| GET | `/api/v1/tracks/{id}/lyrics` | UTF-8 LRC 或纯文本，缺失时 404 |
| POST | `/api/v1/tracks/{id}/lyrics/scrape` | `{}` 获取歌词；可选 `source`、`replace:true` |
| POST | `/api/v1/tracks/{id}/lyrics/embed` | `{}` 将当前歌词写入音频标签；已有标签歌词需 `replace:true` |
| GET | `/api/v1/albums` | 聚合专辑 |
| GET | `/api/v1/artists` | 聚合艺术家 |
| GET | `/api/v1/artists/avatar?name=艺术家名称` | 按需获取并缓存艺术家头像，需要登录 |
| GET / PUT | `/api/v1/sources` | 查询来源能力 / 保存默认来源 |
| GET | `/api/v1/jobs` | 最近 30 次扫描记录 |
| DELETE | `/api/v1/jobs/{id}` | 删除已结束的任务记录；不影响音乐库与文件 |
| DELETE | `/api/v1/jobs` | `{"ids":["id1","id2"]}` 批量删除，或 `{"all":true}` 删除全部已结束记录 |
| POST | `/api/v1/library/scan` | `{}` 后台遍历本地音乐库并更新索引，返回 202；不处理导入目录、不联网刮削、不写入音频；与整理、编辑互斥，任务标记 `index_only:true` |
| POST | `/api/v1/jobs/scan` | `{}` 整理入库，`{"rescrape":true}` 重新读取已有音乐标签并刮削 |

歌曲列表参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `library` | 全部 | `local` / `cloud`；也适用于专辑、艺术家及系统统计 |
| `search` | 空 | 标题、艺术家、专辑不区分大小写匹配 |
| `favorite` | 空 | `true` 只返回收藏 |
| `album` | 空 | 聚合专辑 ID |
| `artist` | 空 | 艺术家名称（包含专辑艺术家） |
| `offset` | `0` | 跳过数量 |
| `limit` | `100` | 每页数量，最大 500 |

返回 `{"items":[...],"total":0,"offset":0,"limit":100}`。专辑、艺术家和任务返回 `{"items":[...]}`。歌曲 API 不暴露文件系统路径。

歌曲的 `has_embedded_lyrics` 表示文件标签中是否有歌词：`true` / `false`，旧索引未探测时为 `null`。不包含外置 LRC 或在线歌词缓存。`GET /api/v1/tracks/{id}?check_lyrics=true` 可补充检测并持久化旧索引的标签状态；管理页面分批检测当前页的未知项。

歌曲列表和单曲详情的 `has_lrc_lyrics` 表示当前是否存在可读取的同名 `.lrc` 旁挂文件。它独立于 `has_embedded_lyrics`，不包含在线缓存或标签内歌词。仅检查返回页内曲目的本地文件，不访问 115 或探测音频；空白、过大、不可读或越出库目录的文件返回 `false`。

歌曲字段包含 `id`（本地音频 SHA-256；网盘为账号与文件 ID 的稳定 SHA-256 摘要）、`title`、`artist`、`album_artist`、`album`、`year`、`genre`、`number`、`disc`、`duration`（秒）、`format`、`bitrate`（bit/s）、`sample_rate`（Hz）、`size`（字节）、`favorite`、`added_at`，及可选的 `artwork`、`mbid`、`release_id`、`metadata_source`（实际信息来源）、`metadata_locked`（人工更正后为 `true`）。

艺术家列表返回 `name`、`tracks` 和可选的 `artwork`（Resona 同源头像地址）。列表查询不访问外部来源；客户端请求 `artwork` 时，服务端按刮削优先级在已启用的 QQ 音乐、网易云音乐中搜索同名艺术家，失败则尝试下一来源。网易云请求 500×500 缩略图；头像下载校验来源域名、5 MiB 大小和 2000×2000 尺寸上限，转换为 JPEG 后持久缓存；后续请求直接读取本地缓存，浏览器私有缓存有效期为一天。无匹配头像或艺术家不在可见曲库中返回 `404`；无匹配结果缓存 6 小时，来源临时故障返回 `502` 并附带 `Retry-After: 60`，不会写入无匹配缓存。空名称与 `Unknown Artist` 不返回头像地址。客户端可在图片不可用时继续显示名称首字占位。

歌曲还包含 `library`（`local` / `cloud`）、`hash_algorithm`、`content_hash` 和 `unavailable`。本地内容摘要为 SHA-256，网盘内容摘要为 115 提供的 SHA-1；不要将网盘歌曲 ID 用作内容校验。云端曲目生成 STRM 后按文件名发布基础信息，预探测成功后补全标签、时长与封面；歌词标签检测读取后台缓存。

`artwork` 为受保护的相对 API 路径，请携带当前认证访问。音频地址不接受 URL token，避免凭据进入日志和历史记录。

扫描是异步任务，创建成功返回 `202` 和任务对象；同一时间已有任务返回 `409`。任务状态为 `running`、`completed`、`completed_with_errors` 或 `interrupted`。字段包括 `phase`、`processed`、`imported`、`skipped`、`errors`、`started_at`、`ended_at`、`items`。条目包含 `filename`（文件名，无绝对路径）、`track_id`（入库或跳过已有曲目时）、`title`、`artist`、`album`、`source`、`duration`（秒，旧条目无法补充时为 0）、`state` 和可选 `message`。条目状态为 `processing`、`imported`、`imported_with_warnings`、`skipped`、`failed`、`interrupted`；旧任务可能没有条目。在线刮削不可用时保留本地标签并记录提示。识别后若同库已有同名同歌手曲目，则记录 `skipped` 并保留来源文件；相同标题但不同演唱者，以及不同库的同名同歌手曲目互不阻挡。

删除任务要求认证和同源写入，成功返回 `204`；记录不存在返回 `404`，运行中返回 `409`。仅删除历史记录，音频、歌词、收藏和曲库索引保持不变。任务详情由列表响应中的 `items` 和 `errors` 展示；提示仅在记录能唯一关联到文件条目时使用该条目的 `track_id`。

批量删除 `DELETE /api/v1/jobs` 必须二选一提供非空 `ids`（最多 30 个，不得重复）或 `all:true`。所选含不存在的记录返回 `404`，含运行中记录返回 `409`，整批不删除；`all:true` 自动保留运行中任务。成功返回 `200 {"deleted":2,"skipped_running":1}`。Web 支持全选、取消选择和删除确认，选择状态在任务轮询刷新时保留；单行任务记录点击名称进入详情，窄屏在列表内部横向滚动。

错误统一为 `{"error":"说明"}`。没有 CORS 跨域开放，也没有匿名音频直链。

## 识别更正

`GET /api/v1/tracks/{id}/matches?title=歌曲名&artist=艺术家&source=qq` 返回 `{"source":"QQ音乐","items":[...]}`，省略参数时使用当前歌曲信息和默认刮削源；艺术家可传空字符串以扩大搜索范围。候选包含可编辑元数据、实际 `source`、`duration`，部分来源还提供 `source_id`。MusicBrainz 正式发行版本分别列出，最多 20 个候选，且附带相关性 `score`；其余普通来源最多 10 个。`source=auto` 按优先级跳过禁用项，优先返回时长一致且歌曲身份可信的来源候选；无法获得一致结果时按身份和时长偏差排序已找到的候选；`source=smart_tag` 综合已启用的普通来源，按歌曲信息匹配评分排序，最多 20 项。均需人工核对后保存。所有来源失败返回 `502`，无候选返回空数组。MusicBrainz 请求间隔至少 1.1 秒，其余来源至少 500 毫秒。

```http
PUT /api/v1/tracks/{id}/metadata
Content-Type: application/json

{"title":"青花瓷","artist":"周杰伦","album":"我很忙","album_artist":"周杰伦","year":"2007","genre":"Pop","number":3,"disc":1,"mbid":"","release_id":""}
```

此接口完整替换可编辑标签。歌曲名称、艺术家必填；空专辑艺术家回退到艺术家；年份为空或四位数字；曲序、碟号为 0–9999；单个文本字段最多 1024 字节且不能包含控制字符；两个 MusicBrainz ID 为空或标准 UUID。可传候选 `source`，手工编辑默认 `manual`。未传可选字段会清空或归零；禁止修改路径、ID、音频参数等其他字段。成功返回最新歌曲对象。人工标签在重新扫描与刮削时保留，收藏、加入时间和音频内容保持不变。保存更正立即按 `专辑艺术家/专辑/歌曲名-歌手.格式` 整理并同步迁移同名 LRC；网盘只迁移本地 STRM 及 LRC，远端音频保持不变。同库已有同名同歌手歌曲、扫描或网盘后台任务进行中返回 `409`，不保存本次更正。移动或索引保存失败返回 `500`，保留原文件与原索引。重新刮削也使用该目录规则。歌曲身份改变会清除在线歌词缓存，本地 LRC 和内嵌歌词保留。

## 歌词刮削

`POST /api/v1/tracks/{id}/lyrics/scrape` 从所选 `source` 获取歌词，省略时使用保存的默认歌词源。核对标题、艺术家、已知专辑和时长（偏差最多 2 秒）。LRCLIB 优先同步 LRC，其次纯文本；QQ、网易云和酷狗读取来源提供的歌词。不下载空内容，LRCLIB 还会排除标记为纯音乐的记录，单首歌词上限 1 MiB。无需 API Key；手动触发或在扫描中为没有标签歌词的曲目补全，联网扫描受 `SCRAPE_ENABLED` 控制。

成功返回 `200 {"text":"[00:01.00]歌词","source":"LRCLIB","synced":true,"fetched_at":"..."}`；保存到数据卷后，Web 与 iOS 共用 `GET .../lyrics` 读取。GET 返回 UTF-8 文本（LRC 或纯文本），`X-Lyrics-Source` 为 `LRCLIB`、`qq`、`netease`、`kugou`、`local` 或 `embedded`。读取顺序为保存的在线版本、同名 LRC、音频标签内嵌歌词。旧索引首次读取时探测并缓存内嵌歌词，无需重新导入。

`POST /api/v1/tracks/{id}/lyrics/embed` 将同样优先级的当前歌词写入音乐库音频标签，支持 MP3、FLAC、M4A、OGG、Opus，其他格式返回 `415`。不重新编码音频，保留其他可映射标签、音轨与内嵌封面；验证写入结果后才发布新索引，失败保留原音频。已有标签歌词需传 `replace:true`，否则 `409`；无歌曲或歌词时 `404`；扫描或其他标签写入进行中时 `409`。

写入会改变文件 SHA-256，成功返回**新 ID** 的完整歌曲对象（`has_embedded_lyrics:true`），调用方应替换旧歌曲对象、播放流 URL 和队列引用。任务条目同步更新；单独写入歌词不会修改导入文件，整理任务成功后才清理来源，重新扫描不会重复入库。旧 ID 不再作为可播放内容提供，避免破坏 Apple 离线下载的 SHA-256 校验约定；已有离线副本仍可独立播放。单纯写入歌词保留原文件名，原子替换音频并同步索引，失败会恢复原音频；不会因为标签引起的哈希变化而追加短摘要。不同来源的同名不同内容仍保留短摘要防覆盖规则。

已有歌词而未明确传 `replace:true`，或获取期间歌曲身份改变，返回 `409`。替换成功也保留原始 LRC 文件和音频标签；任何网络、匹配或保存失败均保留已有版本。曲目不存在或无匹配返回 `404`，外部服务异常返回 `502`，服务繁忙或限流返回 `429` 并携带 `Retry-After`。请求串行执行、间隔至少 500 毫秒，遵守上游限流的等待时间；此期间重复请求不会继续访问上游。人工更正与歌词操作均要求登录。

## 来源设置

`GET /api/v1/sources` 返回 `{"items":[{"id":"qq","name":"QQ音乐","metadata":true,"lyrics":true},...],"settings":{"metadata":"musicbrainz","lyrics":"lrclib","metadata_priority":["qq","netease","kugou","musicbrainz","itunes","migu","kuwo","smart_tag"],"metadata_disabled":["smart_tag"]}}`。

`PUT /api/v1/sources` 接受 `metadata`、`lyrics`，以及可选的 `metadata_priority`、`metadata_disabled`、`lyrics_priority`、`lyrics_disabled`。优先级必须完整且不重复地列出所有元数据源；禁用列表须是有效且不重复的元数据源子集，并至少保留一个普通来源。省略这两个新字段时保留已有设置，`metadata_disabled:[]` 明确启用全部来源。成功返回同样结构。设置保存在数据卷，未设置的旧安装继续使用 MusicBrainz / LRCLIB。

只有 `metadata:"auto"` 的扫描和自动候选搜索使用优先级与禁用列表；指定普通来源不受禁用列表影响。自动扫描遇到服务错误、空结果或匹配不可信时继续下一来源，成功后停止，全部失败保留本地标签并记录提示。`smart_tag` 本身为组合源，只查询启用的普通来源，避免递归；候选保留实际来源及匹配评分。不支持的 ID、能力不符、非法排序或禁用列表、未知字段返回 `400`，查询和修改均要求认证。

| ID | 元数据 | 歌词 |
| --- | --- | --- |
| `musicbrainz` | 是 | 否 |
| `qq` | 是 | 是 |
| `netease` | 是 | 是 |
| `kugou` | 是 | 是 |
| `itunes` | 是 | 否 |
| `migu` | 是 | 否 |
| `kuwo` | 是 | 否 |
| `smart_tag` | 是（多源匹配排序） | 否 |
| `lrclib` | 否 | 是 |
| `auto` | 按已保存的元数据顺序和禁用列表匹配 | 按已保存的歌词顺序和禁用列表匹配 |

歌词优先级必须完整包含 `lrclib`、`qq`、`netease`、`kugou`，禁止重复；禁用列表至少保留一个歌词源。未传歌词优先级 / 禁用列表时保留已有设置，初始优先级为 `["lrclib","qq","netease","kugou"]`，初始禁用列表为空。仅 `lyrics:"auto"` 使用歌词顺序与禁用列表，匹配成功后停止，具体来源不受列表影响。

自动补全只填写缺失标签，按歌曲身份和时长严格匹配；不确定的结果保留本地信息。上游服务不可用时可切换其他来源。

## 文件管理（服务端 Web）

`GET /api/v1/files?root=filesystem&path=/` 浏览任意服务器可访问路径；`root` 可为 `filesystem`、`library`、`inbox`、`plugins`。路径为空时进入所选快捷目录，绝对路径不受快捷目录范围限制，支持上级路径和目录链接。响应 `{"items":[{"name":"song.flac","path":"/music/library/song.flac","type":"FLAC","size":123,"modified":"...","blocked":false}],"path":"/music/library"}`。目录在前、按名称排序，设备与套接字等特殊条目标记不可操作。

`POST /api/v1/files/operations` 接受 `{"action":"move","root":"filesystem","paths":["/music/inbox/song.flac"],"target_root":"filesystem","target":"/music/library"}`。`action` 为 `copy` / `move` / `rename` / `delete`；`rename` 仅选择一个条目，`target` 是新文件全路径；复制 / 移动的 `target` 为已有目录；删除无需目标。相对路径基于 `root` 快捷目录解析；目标来源省略时沿用 `root`。最多单次 100 项，禁止同时选择父目录及其子条目，递归复制最多 10000 条目，目标同名时不覆盖。

成功返回 `200 {"completed":2}`；部分失败返回 `409 {"error":"已完成 1 项；…","completed":1}`，已完成项保留。移动 / 重命名 / 删除同步更新音乐库路径或移除已离库的索引，复制不自动入库。扫描 / 写入标签期间返回 `409`。操作有磁盘与索引失败回滚及启动恢复记录；删除由 Web 明确确认后提交。不支持对文件系统根目录本身执行批量修改。仅管理员可访问；Docker 内权限与挂载决定实际可操作范围。

整理入库成功保存曲库索引、完成歌词处理并校验目标音频后，删除导入目录或插件收件目录中的来源音频与已迁移的同名 LRC。失败、来源被修改、目标校验不通过时保留来源。索引扫描不删除文件；同名同歌手但不同内容的跳过项保留。

## 系统日志（服务端 Web）

`GET /api/v1/logs` 接受可选 `level=DEBUG|INFO|WARN|ERROR`、`category=system|scan|plugin|settings|strm|probe|playback`、`search`（最多 512 字节）及 `limit`（1–2000，默认 2000）。返回 `{"items":[{"time":"...","level":"INFO","category":"system","message":"..."}],"counts":{"DEBUG":0,"INFO":1,"WARN":0,"ERROR":0},"retained":1,"capacity":2000}`。日志按新到旧排列；计数使用当前类别 / 关键词筛选但忽略选中等级，便于显示等级页签。

`playback` 对应网页「302 播放」类别。云端播放请求记录歌曲、请求方法、是否强制刷新、响应状态和耗时；成功跳转仅记录 CDN 主机，不记录直链、签名、Cookie 或认证令牌。`302` 日志表示服务端已发出跳转，不代表播放器已实际播放；地址获取失败与来源不可用分别记录 `502`、`503`。

`DELETE /api/v1/logs` 清空已保存的轮转文件及内存记录，保留一条清空审计记录，成功 `204`。所有接口均需认证，写入受同源验证保护。记录持久化、按大小轮转、最多在内存保留 2000 条，错误信息和控制台输出均先脱敏。

## 内置插件

以下接口均要求管理员会话，沿用同源写入限制。

- `GET /api/v1/plugins`：返回 `items`，包含插件 `id`、名称、参考版本、作者、描述、配置、运行状态及目录。秘密字段始终为空，用 `has_token`、`has_api_hash`、`has_proxy_password` 表示是否已保存；运行状态为 `disabled` / `starting` / `running` / `error`，机器人可带 `last_saved`。
- `PUT /api/v1/plugins/musicsaverbot`：配置 `{enabled,token,api_url,whitelist}`。Token 留空保留，`api_url` 留空为云端，`local` 为内置本地服务，其余为 HTTP / HTTPS 根地址；白名单为按空白分隔的正整数 Telegram 用户 ID。使用 `local` 时需先启用本地 API。成功持久化后重启机器人，返回最新插件列表。
- `PUT /api/v1/plugins/telegramlocalapi`：配置 `{enabled,api_id,api_hash,port,proxy_type,proxy_host,proxy_port,proxy_user,proxy_password,log,cleanup_hours}`。秘密字段留空保留；端口为 1024–65535，`proxy_type` 为 `""` / `http` / `socks5`，清理间隔为 0–8760 小时（0 关闭）。启用要求凭据完整；Go 服务端已内置，无需外部程序。本地 API 被运行中的机器人使用时不能直接停用，返回 `409`。修改本地服务配置会同时重启依赖它的机器人。
- `POST /api/v1/plugins/{id}/restart`：重启指定插件及其依赖方，未启用的插件保持停用。
- `POST /api/v1/plugins/telegramlocalapi/clean-cache`：协调暂停服务，删除独立下载缓存目录中超过 24 小时的普通文件，然后恢复原配置；不跟随符号链接、不删除会话与音乐来源。
- `POST /api/v1/plugins/musicsaverbot/logout-cloud`：保留的云端 Bot API 注销接口，仅用于外部服务迁移；内置 Go 服务无需执行。机器人须停用且已保存 Token，运行中返回 `409`，云端失败返回 `502`。

本地回环服务仅提供机器人 Token 保护的 `POST /bot{token}/getUpdates`、`getFile`、`sendMessage`。待处理消息先持久化，再向音乐保存机器人交付；仅在下次轮询确认 offset 后清理队列，下载失败不确认。文件下载直接流式写磁盘并校验大小，受 2 GiB / 1 MiB / 5 MiB 边界限制。此服务不实现通用 Bot API，也不暴露到容器外部。

PUT 提交完整配置对象（秘密字段允许留空），拒绝未知字段。非法配置返回 `400`，未知插件或操作返回 `404`，持久化失败返回 `500` 且保留原配置。运行状态不代表真实 Telegram 凭据已验证，连接错误由状态消息反馈，轮询遇到限流会按上游等待时间重试。

## 115 网盘音源

以下接口均需 Resona 登录。采用参考项目的 Cookie 扫码登录（`web` 二维码令牌，所选设备的登录结果），无需 `client_id`，不使用 Open API 或 PKCE。服务端验证账号后私有保存 Cookie，不向客户端返回 Cookie、扫码签名或旧版访问 / 刷新令牌。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/cloud115` | 设置、连接状态、后台进度、状态计数和分页文件；支持 `state`、`offset`、`limit`（默认 100，最大 500） |
| PUT | `/api/v1/cloud115` | 完整保存 `root_id`、`root_path`（可选显示路径）、`base_url`、`enabled`、`sync_schedule:{mode:"manual"或"daily",time:"HH:mm"}`、`download_lyrics`、`download_http` |
| GET | `/api/v1/cloud115/account` | 读取真实账号 `id`、`name`、`avatar`、`membership`、`space:{total,used,remaining}`（字节）；容量不可用为 `null`，资料失败返回 502，保留已有 Cookie |
| GET | `/api/v1/cloud115/folders?parent=0` | 读取一级子目录，返回 `items:[{id,name}]`、`parent`、完整 `path` 与 `breadcrumbs:[{id,name}]`；界面每页显示 50 个文件夹 |
| POST | `/api/v1/cloud115/auth` | `{"client_type":"alipaymini"}` 创建或刷新登录二维码；`{}` 默认支付宝，无需预先配置应用或地址；返回 `url`、`expires_at`、`client_type` |
| GET | `/api/v1/cloud115/auth/qr` | 本地生成的二维码 PNG；过期返回 410 |
| GET | `/api/v1/cloud115/auth` | 轮询状态；0 等待、1 已扫码、2 登录确认且账号及 Cookie 已验证并保存；负数为取消或过期，失效二维码返回 410 |
| POST | `/api/v1/cloud115/disconnect` | `{}` 清除 Cookie、停用音源，保留已有曲目但标记不可用 |
| POST | `/api/v1/cloud115/sync` | `{}` 启动目录树同步并批量生成 STRM，按文件名发布基础曲目、刷新网盘音乐库，不启动探测；成功 202；未授权、未启用或生成任务已运行 409；探测期间可生成；目录树或分页失败保留已有索引 |
| POST | `/api/v1/cloud115/probe` | `{}` 将待探测歌曲加入持久化 FIFO 队列；可用 `{"track_id":"..."}` 指定单曲；成功 202，同一歌曲不重复入队；生成期间 409 |
| POST | `/api/v1/cloud115/retry` | `{}` 将失败项加入同一队列，或 `{"track_id":"..."}` 指定重新探测；队列运行中可继续入队，成功 202；生成期间 409 |

扫码方式 `client_type` 白名单：`alipaymini`（支付宝）、`wechatmini`（微信）、`115android`（安卓）、`115ios`（iOS）、`web`（网页）、`115ipad`（PAD）、`tv`（TV）。切换方式或刷新均创建新二维码会话，设备类型绑定在服务端会话中；轮询参数不能改变设备类型。以上方式均使用 115 客户端扫码，所选方式决定 Cookie 的登录设备，可能使同类设备旧会话下线。

状态响应包含服务端 `timezone`，每日同步按此时区执行。计划持久化，保存后立即重算下一次执行时间，重启后恢复；任务运行时跳过重叠执行。旧 `interval_minutes` 参数仍接受：正值转换为每天 `03:00`，`0` 转换为仅手动；新客户端应使用 `sync_schedule`。`GET/PUT /api/v1/settings/scan` 同样返回和保存每日或手动整理计划；旧 `mode:"interval"` 输入在校验后转换为每日计划，沿用 `time` 或默认 `03:00`。

上游状态接口未扫码时可能长轮询约 30 秒，HTTP 超时为 45 秒；空状态响应视为继续等待。长轮询不持有扫码会话锁，刷新或切换方式无需等待旧轮询结束；旧会话迟到的确认结果返回 409，不换取 Cookie 或覆盖新会话。

条目状态为 `pending`、`probing`、`ready`、`skipped`、`failed`、`missing`，包含远端相对路径、名称、文件 ID、稳定歌曲 ID、摘要及错误原因；`queued` 表示条目已入探测队列。状态响应保留聚合 `busy` 与生成任务 `message`，新增 `sync_busy`、`probe_busy`、`probe_current`（当前歌曲 ID，空字符串表示空闲）、`probe_queued`（不含当前歌曲的等待数量）和 `probe_message`。生成与探测为独立任务，定时同步只生成。预探测仅有一个工作线程，当前歌曲完成后才处理下一首；失败继续后续歌曲，持久化队列并在服务启动时恢复已入队工作，未入队条目不自动探测。生成过程中若文件更新，旧探测结果不会发布；已消失或其他账号的队列项跳过。完整遍历后才标记远端缺失，失败请求不会清空已有音乐库。

云端 `/tracks/{id}/stream` 鉴权后返回 `302 Location: <115 HTTPS 下载地址>`，不代理音频；不可用的来源返回 `503`，上游地址获取失败返回 `502`。请求中的 User-Agent 用于上游下载地址获取及短时缓存分组；`?refresh=1` 强制重新获取。客户端跟随重定向时不得向 CDN 转发 Resona 认证。`/cover` 与 `/lyrics` 读取服务端缓存，云端 `/lyrics/embed` 返回 `415`。生成的 STRM 引用相同的受保护播放接口。

目录通过 Cookie Web 接口读取：`/files/get_info` 获取所选目录 PickCode，`/files/downfolders` 分页获取目录树，`/files?cur=0` 分页读取递归文件清单。批量读取失败时回退 `/files?cur=1` 逐目录扫描，根目录 `0` 直接使用此方式。目录浏览使用同一个 Web 列目录接口。读取请求的 HTTP 405 / 429 最多重试 3 次，遵循 `Retry-After`（最长 120 秒）或 1 / 2 / 4 秒退避；网络错误、5xx 与登录失效不自动重试。115 API 请求直连，不使用系统 HTTP 代理。单次限制 10000 个目录、100000 个文件，只有完整验证成功才提交索引。

直链仍通过 `/app/chrome/downurl` 的 RSA 加密协议获取，无 Web GET 的 200 MB 限制。需要额外 Cookie 的 CDN 地址被拒绝，Cookie 不随重定向传给客户端。上游报告登录失效时清除 Cookie、标记曲目不可用并提示重新扫码，不进行 Open API 令牌刷新。升级旧版接入时保留曲目、STRM 与收藏，但须重新扫码登录。

音乐库和插件收件目录中由服务生成、整理、复制或移动的目录和文件显式设置 `0777`；数据卷中的凭据、索引与日志继续使用各自的私有权限。

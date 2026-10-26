# nvim-radio

参考 [radio-cli](https://github.com/hmgle/radio-cli) 实现的 Neovim 电台播放器。
Neovim Lua 插件作为控制器，`mpv` 作为独立播放进程，`ffmpeg` 作为独立录音进程。
无需账号或 API key。

- 浏览 [Radio Browser](https://www.radio-browser.info/) 目录，本地搜索
  （大小写不敏感，支持中文地区名，如"刚果"匹配两个刚果），按国家、语言、
  标签、最低码率过滤，按点击量、投票、码率或名称排序。
- 播放任意 HTTP(S) 流或已保存的自定义电台（支持备用 URL）；收藏、历史、
  自定义电台与录音记录保存在本地 SQLite 数据库中，radio-cli 可直接共用。
- 以流拷贝方式录制 MP3、AAC、Vorbis、Opus 流，附带元数据 JSON sidecar 与
  崩溃恢复。
- 键盘驱动的浮动窗浏览器、statusline 组件与状态 HUD，零第三方插件依赖。

[English](README.md) | **简体中文**

## 环境要求

| 依赖 | 说明 |
| --- | --- |
| Neovim 0.10+ | LuaJIT 构建（使用 FFI 访问 SQLite） |
| `mpv` | 播放，通过 JSON IPC socket 控制 |
| `ffmpeg`、`ffprobe` | 录音与流探测 |
| `libsqlite3` | FFI 绑定所需的共享库 |
| `curl` | 访问 Radio Browser API |

执行 `:RadioDoctor` 可检查宿主环境。如果 SQLite 不在标准库路径中（例如 NixOS），
请在加载插件前通过 `vim.g.sqlite_clib_path` 或 `SQLITE_CLIB_PATH` 指定共享库路径。

## 安装

[lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "hmgle/nvim-radio",
  opts = {
    volume = 80,
    keys = {
      toggle = "<leader>r",
      pause = "<leader>rp",
      record = "<leader>rr",
      status = "<leader>rs",
    },
  },
  cmd = { "Radio", "RadioPlay", "RadioSync", "RadioRecord" },
}
```

mini.deps：

```lua
MiniDeps.add("hmgle/nvim-radio")
require("radio").setup({ volume = 80 })
```

## 快速开始

```vim
:Radio              " 打开电台浏览器
:RadioSync          " 同步 Radio Browser 目录
:RadioPlay <UUID>   " 播放已保存电台（或任意 http(s) URL）
:RadioStatus        " 播放/录音状态 HUD
:RadioDoctor        " 环境诊断
```

浏览器按当前过滤条件打开：`i` 搜索，`F` 过滤，`Enter` 播放，`r` 录音，`q`
关闭。过滤值菜单支持前缀搜索和上下翻页。结果分页浏览（`L` / `H`），顶栏实时显示
播放与录音状态。随机排序在当前会话中
保持顺序稳定，避免翻页时重复显示电台。`:RadioSync` 按每页 1000 个电台分页拉取并原子发布；目录缩水超过 25%
时需要确认才会接受。

## 浏览器键位

| 按键 | 功能 |
| --- | --- |
| `Enter` / `o` / 双击 | 播放选中项 |
| `i` / `/` | 本地搜索 |
| `F` | 国家 / 语言 / 标签 / 最低码率过滤 |
| `s` | 切换排序：点击量、名称、码率、投票、随机 |
| `n` | 按当前过滤条件随机播放 |
| `f` | 收藏 / 取消收藏 |
| `r` | 开始 / 停止录制当前电台 |
| `R` / `F5` | 同步目录 / 刷新列表 |
| `[` / `]` | 切换来源：电台、收藏、历史、自定义、录音 |
| `L` / `H`、`PageDown` / `PageUp` | 下一页 / 上一页结果 |
| `y` / `Y` | 复制 UUID / 流 URL（或录音 ID / 路径） |
| `d` | 删除录音（需确认） |
| `O` | 打开录音目录 |
| `q` / `Esc` | 关闭 |

## 命令

| 命令 | 功能 |
| --- | --- |
| `:Radio` | 开关浏览器 |
| `:RadioPlay <UUID\|URL>` | 播放电台或 HTTP(S) 流 |
| `:RadioStop` / `:RadioPause` / `:RadioMute` | 播放控制 |
| `:RadioVolume <+n\|-n\|n>` | 调整或设置音量 |
| `:RadioRecord [时长] [--output-dir 目录]` | 录制当前电台 |
| `:RadioRecordStop` | 停止并发布录音 |
| `:RadioRandom [查询]` | 随机播放 |
| `:RadioSync` | 同步目录 |
| `:RadioStatus` | 状态 HUD |
| `:RadioDoctor` | 环境诊断 |
| `:RadioDevices` | 列出 mpv 音频输出设备 |
| `:RadioFavorites [add\|remove <UUID>]` | 管理收藏 |
| `:RadioHistory` | 最近成功播放记录 |
| `:RadioRecordings [list\|play ID\|remove ID [--index-only]]` | 管理录音 |
| `:RadioStationAdd <名称> <URL>` | 添加自定义电台 |
| `:RadioStationRemove <UUID>` | 删除自定义电台 |
| `:RadioOpenRecordings` | 打开录音目录 |

时长支持 `30`、`45s`、`10m`、`2h`，范围 1 秒到 365 天。
输出目录中的空格需用反斜杠转义，例如：
`:RadioRecord 30 --output-dir /tmp/My\ Music`。

## 配置

`setup()` 选项与默认值：

```lua
require("radio").setup({
  mpv = "mpv",
  ffmpeg = "ffmpeg",
  ffprobe = "ffprobe",
  volume = 80,
  normalize_loudness = false,   -- mpv dynaudnorm
  audio_device = nil,           -- 例如 "alsa/plughw:CARD=USB,DEV=0"
  playback_timeout_secs = 12,
  resume = false,               -- false | true | "selection"
  api_url = nil,                -- 固定 Radio Browser 服务器
  connect_timeout_secs = 5,
  request_timeout_secs = 20,
  auto_sync_days = 7,           -- 0 关闭后台同步
  recording_dir = nil,          -- 默认 <数据目录>/recordings
  probe_timeout_secs = 5,
  recording_min_free_mb = 16,
  single_instance = true,       -- 数据目录 flock 锁
  debug = false,
  data_dir = nil,               -- 默认 $XDG_DATA_HOME/nvim-radio
  keys = {},                    -- 可选的全局键位
  ui = { width = 0.8, height = 0.8, border = "rounded", preview = true },
})
```

`resume = true` 恢复上次电台的播放和浏览来源；`"selection"` 只恢复来源，
不开始播放；`false` 从电台列表开始，不恢复播放。

配置为 Lua 表而非 radio-cli 的 `config.toml`，键名与 radio-cli 的 TOML 设置
一一对应。全局键位名：`toggle`、`pause`、`mute`、`volume_up`、
`volume_down`、`record`、`status`、`random`、`stop`，默认均不绑定。
键位设为 `false` 表示禁用；省略键名则不绑定。`ui.width` 和 `ui.height`
是相对于 Neovim 窗口大小的比例（大于 0 且不超过 1），不是列数或行数。

### 路径

| 项目 | 路径 |
| --- | --- |
| 数据目录 | `$XDG_DATA_HOME/nvim-radio`（`$NVIM_RADIO_DATA_DIR` 可覆盖） |
| 数据库 | `<数据目录>/radio.db` |
| 录音 | `<数据目录>/recordings/` |
| 运行时（socket、锁） | `<数据目录>/run/` |

## 状态栏

```lua
-- lualine
require("lualine").setup({
  sections = {
    lualine_x = { function()
      return require("radio").statusline()
    end },
  },
})
```

或内置状态栏：

```lua
vim.o.statusline = "%f %m %= %{v:lua.require('radio').statusline()}"
```

## 录音

录音采用流拷贝，不重新编码。开始录制前会探测编码并选择容器。

录音要求当前播放的是目录电台或自定义电台。通过 `:RadioPlay` 直接播放的临时 URL，
需要先用 `:RadioStationAdd` 保存并播放该电台后才能录音。本地录音播放不能再次录制。
插件界面提示统一使用英文。

| 流编码 | 输出 |
| --- | --- |
| MP3 | `.mp3` |
| AAC（含常见 HLS AAC） | `.aac` |
| Vorbis | `.ogg` |
| Opus | `.opus` |

录音先写入 `.part` 文件，停止后用 `ffprobe` 校验再发布，且不会覆盖已有文件。
JSON sidecar 记录电台、曲目、时间戳、编码、时长、大小与重连次数。被中断的
录音保留部分文件，标记为 `interrupted`，下次启动时恢复。切换电台会结束当前
录音；暂停播放不会暂停录音。

录音所在文件系统需要支持硬链接，以保证原子发布。创建硬链接失败时，
插件会保留部分音频并报告错误。

退出时会取消尚未完成的目录请求和录音探测，并给录音有限的收尾时间。
超时录音保留 `.part` 文件与恢复元数据；数据库与会话锁会一直保留到相关
录音写入进程和播放器退出。

## Lua API

```lua
local radio = require("radio")

radio.setup({ volume = 70 })
radio.play("https://example.com/live.mp3")     -- URL 或电台 UUID
radio.pause()
radio.volume(5)
radio.record("30m")                            -- radio.record_stop() 结束
radio.random({ query = "jazz", country = "FR" })
radio.sync({ accept_shrink = false })
radio.stations({ query = "news", limit = 20 }) -- 返回 电台列表, 总数
radio.favorites()
radio.history()
radio.recordings()
radio.station_add("My Station", "https://example.com/live", { "https://example.com/backup" })
radio.statusline()
```

## 与 radio-cli 的差异

- 配置使用 `setup{}` Lua 表，而非 `config.toml`。
- 服务器发现直接使用 `all.api.radio-browser.info` 镜像列表；radio-cli 会
  额外先尝试 DNS SRV 查询。实际服务器集合相同。
- artwork 终端图形、TUI、shell 补全与 man 页是 radio-cli 特有功能，本插件
  没有对应实现。
- 会话互斥与 radio-cli 共用 `<data_dir>/run/media.lock` 上的 `flock`。
  退出或崩溃后由操作系统释放所有权，锁文件保留；`single_instance = false` 会关闭互斥
  和录音自动恢复。之后以独占会话打开数据目录，且没有其他 nvim-radio 会话存活时才会恢复；
  `force = true` 也跳过恢复。所有 nvim-radio 会话启动后都会持有 `run/recovery.lock`
  的共享锁，包括绕过 `media.lock` 的会话；恢复需要同时独占这两把锁。
- 数据库 schema 与 radio-cli 一致，两个工具可共用数据目录（但同时只能有
  一个媒体会话）。

## 开发

```sh
stylua --check lua plugin tests
nvim --headless -l tests/run.lua                    # 完整测试
NVIM_RADIO_TESTS=test_player nvim --headless -l tests/run.lua
nvim --headless -u NONE -l tests/benchmark_sync.lua # 5 万条电台的同步耗时
```

测试使用进程内 HTTP 服务器与真实 `mpv`/`ffmpeg`/`ffprobe`；目录测试使用
本地假 Radio Browser 服务器，默认测试无需外网。锁测试会启动独立的
Neovim 进程，生命周期测试覆盖取消、强制终止子进程与恢复。
CI 在 Neovim 0.10.0 与最新稳定版上运行完整测试，使用 mpv 的静音输出。

## 许可证

MIT，见 [LICENSE](LICENSE)。附带的中文国家/地区名表受
[Unicode License V3](LICENSE.unicode) 约束。

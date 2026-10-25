# PerfMonitor

一个面向 Apple Silicon 的 macOS 性能监控工具，包含主面板、菜单栏、悬浮窗，以及命令行（CLI）、HTTP API 和 MCP 三种程序接口。重点回答这几个问题：谁在吃性能、多热、多耗电、有没有撞温度墙、瓶颈在哪、充电和接口对外供电各是多少。

## 下载安装（给朋友）

**要求**：Apple Silicon Mac（M 系列或 A18 Pro），macOS 14 及以上。CPU 功耗在 macOS 27 上依赖 AppleCLPC 计数器，目前支持的芯片见 `CLPC.swift`；不在列表里的会退回到按进程能耗估算。

1. 到 [Releases](../../releases) 下载 `PerfMonitor.zip`，解压后把 `PerfMonitor.app` 拖进「应用程序」。
2. 这个 App 没有 Apple 开发者签名，第一次打开会被 macOS 拦截。任选一种方式放行：
   - 在终端执行下面这条命令，然后正常双击打开：
     ```bash
     xattr -dr com.apple.quarantine /Applications/PerfMonitor.app
     ```
   - 或者先双击一次，然后去「系统设置 → 隐私与安全性」，点「仍要打开」。
3. 可选：安装命令行工具和 MCP 接口：
   ```bash
   ln -sf /Applications/PerfMonitor.app/Contents/MacOS/perfmon ~/.local/bin/perfmon
   claude mcp add -s user perfmonitor -- ~/.local/bin/perfmon mcp
   ```

也可以自己从源码构建（见下一节）。

## 从源码构建

```bash
./scripts/build-app.sh      # 生成 PerfMonitor.app（ad-hoc 签名，带图标）
./scripts/install-cli.sh    # 把 perfmon 链接到 ~/.local/bin
open PerfMonitor.app
```

需要 Xcode 15 及以上（Swift 6 工具链）。全程不需要 root。

## 界面

- **界面风格**：
  - 系统原生工具栏，进程列表放在原生的右侧检查器面板里（可拖动调宽，也可以隐藏）。
  - 窗口背景透出桌面模糊；在 macOS 26 及以上，卡片、工具栏按钮和进程区控件都用 Liquid Glass。
  - 卡片会铺满窗口，窗口太小时才出现滚动；窗口足够宽时自动排成三列。
- **主面板**：瓶颈诊断、温度、功耗、CPU（各核心的占用和频率）、GPU（含热限频）、内存（含换页和磁盘 I/O）、充电与供电、硬件信息、传感器（可以展开全部传感器）、进程表。
- **进程浏览器**（相当于活动监视器）：
  - 分为 CPU / 内存 / 能耗 / 磁盘 / 网络五个标签页。
  - 三种视图：所有进程 / 按应用合并 / 层级。
  - 筛选：我的进程、系统进程、其他用户、有窗口的、活跃的、使用 GPU 的。
  - 列宽可拖动、列可拖动排序、点表头排序；在表头右键可以显示或隐藏列，这些设置都会保存。
  - 双击进程打开详情：路径、父进程、启动时间、代码签名、沙盒，打开的文件和网络端口，以及「采样」（`sample` 的调用栈报告）。
  - 右键菜单：采样、限制到能效核、发送信号、退出 / 强制退出、在访达中显示、拷贝 PID 和路径。
  - 可用的列：% CPU、CPU 时间、线程、空闲唤醒、% GPU、GPU 时间、种类（Apple / Intel）、内存、实际内存、峰值内存、功耗、平均功耗、累计能耗、阻止睡眠、磁盘读写、网络收发、PID、父 PID、用户、启动时间。
- **菜单栏**：常驻显示 SoC 温度和整机功耗；点开后可以看占用最高的进程，也能开关悬浮窗。
- **悬浮窗**：始终置顶，所有桌面都显示，点击它不会抢走当前窗口的焦点。可以拖动，位置会被记住。从主面板右上角的画中画按钮或菜单栏开启。
- **性能档位**：电池和电源两种供电状态可以分别设为“低功耗 / 自动”；支持的机型还会多出“高性能”。
  - 默认每次切换都要输入 Mac 登录密码。点一下锁形按钮做一次授权，以后切换就不需要密码了。授权会安装 `/etc/sudoers.d/perfmonitor`，安装前先用 `visudo` 校验，规则只允许当前用户执行 `pmset -a/-b/-c lowpowermode 0|1` 和 `powermode 0|1|2`。再点一次锁形按钮即可移除。
  - MacBook Neo 没有“高性能”模式：`pmset -g cap` 里只有 `lowpowermode`，所以“自动”就是最高档。这台机器的持续性能真正受限于被动散热的温度墙。

## 程序接口

只要 PerfMonitor.app 在运行，下面三种接口的数据都直接取自它（同一份数据，不会重复采样）。App 没运行时，CLI 和 MCP 会自己采样（大约需要 1 秒）。

### CLI

```bash
perfmon status            # 一句话摘要、瓶颈诊断、各项指标、最忙的应用
perfmon status --json
perfmon processes --sort power --limit 10
perfmon sensors
perfmon hardware
perfmon watch
```

### HTTP（只读，只监听 127.0.0.1:47823）

```bash
curl http://127.0.0.1:47823/v1/status
curl "http://127.0.0.1:47823/v1/processes?sort=memory&limit=5"
curl http://127.0.0.1:47823/v1/sensors
curl http://127.0.0.1:47823/v1/hardware
curl http://127.0.0.1:47823/v1/findings
```

JSON 字段统一使用 snake_case，单位写在字段名里：`_pct`、`_w`、`_c`、`_mhz`、`_bytes`、`_bps`。

### MCP（供 Claude Code 等 agent 使用）

```bash
claude mcp add perfmonitor -- ~/.local/bin/perfmon mcp
```

提供 4 个只读工具：`get_system_status`、`get_top_processes`、`get_sensors`、`get_hardware_info`。

## 数据来源

| 指标 | 来源 |
|---|---|
| CPU / ANE 功耗 | macOS 27 上：AppleCLPC 能耗计数器（nJ）；更早的系统：IOReport Energy Model |
| GPU 功耗、频率、热限频 | IOReport（GPU Energy、GPU Performance States、CLTM） |
| 整机功耗 | SMC `PSTR` |
| 充电功率 / USB-C 输入 / 接口对外供电 | AppleSmartBattery：电压×电流、`PowerTelemetryData`、`PowerOutDetails`、`AdapterDetails` |
| 温度 | SMC `Tp0*` `Te0*` `Tg0*` 等，以及 HID PMU/NAND/电量计传感器 |
| 每个进程的功耗 | `proc_pid_rusage` v6 的 `ri_energy_nj`（读不到的系统进程按 CPU 时间估算，标「≈」） |
| 硬件信息 | sysctl、IORegistry、`system_profiler`、CGDisplay 显示模式，以及 Apple 官方规格（MacBook Neo） |

### 为什么 macOS 27 上 CPU 功耗会读到 0

macOS 27 把 IOReport “Energy Model” 组里所有 mJ 单位的计数器（CPU、ANE、DRAM 等）都冻结了，只有 `GPU Energy`（nJ）还在走。macmon 和 Stats 都有人报告过这个问题，MacBook Neo 上也一样。macmon v0.9.0 改为订阅 AppleCLPC 驱动的聚合能耗计数器，绕开了这个问题，本项目沿用了同样的方法。A18 Pro 对应的驱动是 `AppleT8140CLPC`。DRAM 功耗目前没有替代来源，所以界面上不单独显示。

参考：[vladkens/macmon#76](https://github.com/vladkens/macmon/issues/76)、[exelban/stats#3659](https://github.com/exelban/stats/issues/3659)。

## 资源占用（MacBook Neo 实测，2 秒刷新）

| 状态 | CPU 占用 | 内存 |
|---|---|---|
| 主面板在前台 | 约 4% | 约 110 MB |
| 主面板关闭、被遮挡、隐藏或在其他桌面（只剩菜单栏） | 约 1% | 同上 |

主面板不可见时会直接卸掉整棵视图树，既不重绘也不占用视图内存；进程扫描（最大的采样开销）也降为每 3 次采样做一次。

内存方面，采样引擎本身只占约 9 MB，剩下的基本都是 SwiftUI/AppKit 界面运行时的开销。

其他优化：
- 图表改用单次 Canvas 绘制，不再用 Swift Charts。
- 进程表改用 AppKit 原生 NSOutlineView，固定行高；平铺模式下每一行是固定的“槽位”，刷新时只改写可见单元格的文字，不重建任何视图。
- 左右两栏由 GeometryReader 给定固定尺寸，避免布局时测量所有进程行。
- SMC 键的元数据只读一次后缓存。
- 菜单栏文字只在内容变化时才重绘。

## 已知限制

- 系统和其他用户的进程（例如 WindowServer）不允许普通权限读取详细信息。它们的 CPU 时间和常驻内存改由 Apple 自带的 `ps` 获取；线程数、空闲唤醒、磁盘读写、打开的文件和采样只能看你自己的进程。
- 每个进程的网络流量来自 `nettop`，只在打开「网络」页时采集，每次约耗 30 ms CPU。
- 活动监视器里的「缓存」页（内容缓存服务）、Spindump、系统诊断、Spotlight 诊断没有集成：前者需要开启共享服务，后三者需要管理员权限，并且是给 Apple 或开发者排查问题用的诊断包。

- 传感器标注中带「*」的，是根据数值比对推测出来的。
- MacBook Neo 的内存和 SoC 在同一个封装里，没有独立的内存温度传感器。
- “PD 档位表最高 W”来自充电器上报的 PD 档位表，不一定等于这台 Mac 能接受的最大充电功率。
- “限制到能效核”只能作用于当前用户自己的进程。

## 致谢

- [exelban/stats](https://github.com/exelban/stats)（MIT）：SMC、IOReport 和 HID 的声明与读取方式。
- [vladkens/macmon](https://github.com/vladkens/macmon)（MIT，© 2024 vladkens）：AppleCLPC 能耗通道的报告 ID 和通道结构。

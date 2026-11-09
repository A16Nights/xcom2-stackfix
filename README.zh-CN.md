# XCOM 2 StackFix — 终结 0xC00000FD 闪退

提高 XCOM 2 的线程栈保留大小，让装了大量 MOD 的存档不再在战术战斗中因
**栈溢出（`0xC00000FD`）** 直接闪退。

> **状态：** 已完成逆向、已打补丁、已在《天选者之战》中实机确认 ——
> 原本必崩的场景完整打了两局，零崩溃。工具通过解析 PE 头定位字段，
> 不绑定某一个游戏版本。

[English](README.md) | 简体中文

---

## 问题

在装了很多 MOD 的大战役里，游戏有时会把一个非常大的数组**一次性**搬到线程栈上。
制作本工具期间收集到的六份真实崩溃转储显示，单次请求的栈大小是：

| 崩溃转储 | 请求栈大小 | 数组元素数 |
|---|---:|---:|
| 最小的 | 5.6 MB | 233 581 |
| 最大的 | **10.0 MB** | 417 707 |
| 实测峰值 | **10 024 968 字节**（9.56 MiB） | — |

`XCom2.exe` 的线程栈保留只有 **5 000 000 字节（约 4.77 MiB）**
（PE 可选头里的 `SizeOfStackReserve`）。比这更大的请求会直接越过保护页，
进程在任何代码来得及捕获之前就已经没了：

```
0xC00000FD  STACK_OVERFLOW
  XCom2.exe+0x10a3f18   _chkstk        <- 向下探测越过保护页
  XCom2.exe+0xa29850    调用者          <- sub rsp, rax，rax = 元素数 * 24
```

这个数组是**数据驱动**的 —— 战役越大（MOD 越多、单位越多、历史越长），它就越大。
所以这个崩溃只出现在长期游玩、MOD 很多的战役里，而且多发生在敌方回合的
可视化阶段，或者某个 MOD 把 AI 队伍交给玩家操控的时候。

**这不是一个 MOD。** 游戏永远不会加载它，启动器里也没有开关。
它是一个工具，对你的**自己那份** `XCom2.exe` 打一次补丁。这里不分发任何游戏文件。

## 原因

这个请求是合法的 C++ 代码（一次 `TArray` 拷贝），编译器生成的指令完全正确：

```asm
0xa298fc   call  _chkstk          ; 为 rax 字节的栈做预留
0xa29901   sub   rsp, rax         ; ……然后一次性占走
```

`rax` 就是被拷贝数组的字节大小：`Num * 24`（每个元素三个 8 字节字段）。
`Num = 417 707` 时，这就是一条指令要 10 024 968 字节。`_chkstk` 逐页向下探测，
碰到保留区之外的一页，Windows 就抛出 `STATUS_STACK_OVERFLOW`。

脚本层挡不住它，任何基于时间的看门狗也来不及反应 —— 栈在一条指令里就已经没了。
唯一能动的杠杆，是线程一开始**被给了多少**栈。那就是可执行文件头里的一个字段。

## 修复方式

改 `XCom2.exe` 的 PE 可选头里的一个字段：

```
SizeOfStackReserve  @ 可选头 +0x48（8 字节，PE32+）
    5,000,000  ->  33,554,432   (32 MiB)
```

工具只写这一处。

| 字段 | 偏移 | 改动前 | 改动后 |
|---|---|---:|---:|
| `SizeOfStackReserve` | 可选头 `+0x48` | 5 000 000 | 33 554 432 |
| `SizeOfStackCommit` | 可选头 `+0x50` | 5 000 000 | **不变** |

`SizeOfStackCommit`（每个线程立即获得的物理内存）**永远不碰**。
保留（reserve）只是**地址空间**：64 位进程有 128 TB，145 个线程 × 32 MiB ≈ 4.6 GB
的保留完全无所谓。栈照旧按需逐页增长，只是天花板抬高了。
实测峰值请求 9.56 MiB，留了 **3.3 倍余量**。

`restore` 只回滚**那 8 个字节**。同一份可执行文件上另外打的代码补丁 ——
例如 [SaveFix](https://github.com/A16Nights/xcom2-savefix) —— 不会被它破坏，反过来也一样。

## 用法

同一处补丁有两种实现。两者都从解析出的 PE 头读字段，都在写入前备份，
都在写完后回读校验。

**PowerShell** —— 不需要 Python，任何现代 Windows 都能用：

```console
powershell -ExecutionPolicy Bypass -File tools\StackFix.ps1 Status
powershell -ExecutionPolicy Bypass -File tools\StackFix.ps1 Apply
```

`workshop/item/StackFix.bat` 是这个脚本的双击启动器。不带参数时先出报告，
然后问你要不要直接打补丁，所以全程不用开命令行窗口；带参数时原样透传。
Windows 拒绝访问游戏目录时，它还会自动以管理员权限重试同一个操作。

**Python 3.8+** —— 只用标准库，不需要 `pip install`：

```console
# 取仓库
git clone https://github.com/A16Nights/xcom2-stackfix.git
cd xcom2-stackfix

# 1. 看看工具找到了什么，你的游戏是不是已经打过补丁
python tools/xcom2_stackfix.py status

# 2. 打补丁（默认 32 MiB）。先关掉游戏 —— 它锁着可执行文件。
python tools/xcom2_stackfix.py apply

# 3. 复核
python tools/xcom2_stackfix.py status
```

改动之前会在可执行文件旁边写一份备份：`XCom2.exe.stackbak`。

```console
# 换成别的值（支持 8 到 1024 MiB）
python tools/xcom2_stackfix.py apply 64

# 全部还原
python tools/xcom2_stackfix.py restore

# 只看会发生什么，不写盘
python tools/xcom2_stackfix.py apply 32 --dry-run
```

工具通过 Steam 注册表和 `libraryfolders.vdf` 自动找游戏，
原版和《天选者之战》都支持。找错了可以用 `--exe PATH` 直接指定。

### 该选多大

默认 32 MiB，因为那是实测最大请求的 3.3 倍。如果你 MOD 列表特别长、想要更多余量，
64 MiB 在实际使用中代价完全一样（保留是地址空间，不是内存）。
低于你需要的峰值没有意义 —— `apply` 会拒绝任何不大于实测峰值的取值。

### 支持的可执行文件

| 版本 | 可选头 | 字段偏移 | 状态 |
|---|---|---:|---|
| 天选者之战 | `+0x48` | 随构建变化 | ✅ 实机验证 |
| 原版 | `+0x48` | 随构建变化 | 补丁路径完全相同 |

和按字节特征码定位的补丁不同，这里**没有需要搜索的特征码**：
字段就在解析出来的可选头里的固定位置，所以工具对任一版本的任一构建都直接可用，
不需要维护签名表。不是 64 位 PE 镜像的文件一律拒绝。

## 用之前要知道的事

* **打补丁前关掉游戏。** Steam 锁着可执行文件。
* **Steam 的「验证游戏文件完整性」和游戏更新会还原原始可执行文件。** 之后重跑 `apply`。
* **引擎自己创建的 worker 线程不受影响。** 有些线程在代码里显式指定了栈大小，
  不继承头部这个值；实测进程里有 52 个这样的 5 MiB 线程，另外 91 个继承到了打过补丁的 32 MiB。
  目前观测到的每一次崩溃都发生在跟随头部取值的线程上 —— 但本工具没法为它看不见的线程做承诺。
* **栈溢出本身就是致命的。** 如果某次请求真的超过了新的保留值，游戏照样会死。
  真遇到了就把这个值再调大。
* **这是不受支持的修改。** 与 Firaxis Games、2K、Take-Two 无关联、未获其认可、
  也不受其支持。详见 [`DISCLAIMER.md`](DISCLAIMER.md)。

## 验证过程

* **崩溃取证。** 六份独立崩溃转储，全是 `0xC00000FD`，返回地址完全相同
  （`+0xa29901`），`_chkstk` 栈帧也相同 —— 同一条代码路径，不是一堆互不相关的故障。
* **数字。** 元素数 233 581–417 707，每元素 24 字节，得出每次请求 5.6–10.0 MB。
  峰值 10 024 968 字节，这就是默认值取 32 MiB 的依据。
* **磁盘层面。** 打过补丁的可执行文件与备份逐字节比对，差异恰好 4 个字节 ——
  就是 `0x02000000` 的低半部分替换掉 `0x004C4B40`。
* **运行时映射。** 没有任何注入器在跑的情况下，直接读运行中进程内存里的 PE 头，
  `SizeOfStackReserve = 33,554,432`。说明改动来自文件本身，不是调试器。
* **打对了线程。** 读每个线程的真实保留大小（TEB 里的 `StackBase − DeallocationStack`），
  91 个线程为 32 MiB，其中包括**全部 34 个起始地址落在游戏自身镜像内的线程** ——
  也就是所有真正跑游戏代码的线程。
* **实机。** 原本必崩的场景完整打了两局：接管外星人队伍 105 次，零崩溃，正常退出。

> 如果你想自己复核，有个**坑**值得知道：`StackBase − StackLimit` 在打过补丁的进程上
> 依然恒读约 4.77 MiB。`StackLimit` 是**当前已提交**的边界，不是保留值。
> 保留值要看 `StackBase − DeallocationStack`，位于 `TEB + 0x1478`。

## 仓库结构

```
tools/xcom2_stackfix.py  补丁工具，Python（status / apply / restore）
tools/pe_util.py         零依赖的 PE 读取器
tools/StackFix.ps1       同一工具的 PowerShell 版，不需要 Python
tools/check_vdf.py       工坊构建文件的离线校验器
workshop/item/           订阅者实际收到的东西：清单、说明、启动器、工具、预览图
workshop/workshop_build.vdf  该目录的 SteamCMD 上传配置
workshop/make_preview.py 重新生成 ModPreview.jpg（需要 Pillow）
docs/TECHNICAL.md        崩溃是怎么定位的、字段是怎么确定的
docs/PE_STACK.md         SizeOfStackReserve 到底做什么、不做什么
docs/WORKSHOP.md         为什么这个工坊条目是一个工具，以及它怎么发布
README.md                英文说明
DISCLAIMER.md            法律声明
```

`workshop/item/` 里就是发布到创意工坊的
**[WOTC] StackFix — Stop the 0xC00000FD Crash** 的全部内容：

> https://steamcommunity.com/sharedfiles/filedetails/?id=3836166241

工坊条目分发的是 PowerShell 工具；订阅者拿它去改自己的可执行文件，
所以条目里没有任何游戏文件。这些文件也没有第二份拷贝：
仓库目录**就是**上传源，`workshop_build.vdf` 指向它，
所以重新克隆一份再跑 SteamCMD 就能更新线上条目。

## 相关工作

* **[SaveFix](https://github.com/A16Nights/xcom2-savefix)** —— 同一个思路用在不同
  的硬编码上限上：存档头 65 535 字符的限制。两个补丁可以在同一份可执行文件上共存，
  各自只改自己的字节。
* 把这些转储贡献出来的，大多是那些把 AI 队伍交给玩家操控的 **Direct Control** 分支，
  因为操控一个庞大的敌方回合正是让数组变大的原因。修好栈并不会改变那个 MOD 的行为。

## 许可

本仓库中的代码采用 [MIT](LICENSE)。不包含也不再分发任何游戏代码、
游戏可执行文件或游戏资源。

# NitSync

菜单栏小工具：让外接显示器的亮度按 nit 跟随 MacBook 内屏。用户文档见 README.md，这里记录改代码时需要知道、但从代码里不容易看出来的事。

## 构建与运行

```bash
./build.sh                                   # swiftc 直接编译，产物 build/NitSync.app（ad-hoc 签名）
open build/NitSync.app
open build/NitSync.app --args --calibrate        # 启动后直接进入亮度校准
open build/NitSync.app --args --calibrate-color  # 启动后直接进入颜色校准
open build/NitSync.app --args --calibrate-grey   # 直接开始灰阶（没法发按键时用来截图检查）
open build/NitSync.app --args --calibrate-primaries  # 直接开始原色
open build/NitSync.app --args --reset-color      # 清除颜色校准、换回原描述文件、删文件，然后退出
```

版本号用 1.0.0 格式（语义化版本），写在 `Info.plist` 的 `CFBundleShortVersionString`，发布时打 `v1.0.0` 这样的 git 标签；`CFBundleVersion` 是构建号，每次发布加 1。

分发用 `./release.sh`：Developer ID 签名（`--options runtime --timestamp`）→ `notarytool submit --wait`（钥匙串配置名默认 `NitSync`，`NOTARY_PROFILE` 可改）→ `stapler staple` → `dist/NitSync-<版本>.zip`（上传公证用的 zip 放临时目录，公证结果不是 Accepted 就失败退出，失败时 dist/ 里不会留下像正式版的未公证包）；`--install` 再装到 /Applications。签名身份自动取钥匙串里第一个 Developer ID Application（`SIGN_IDENTITY` 可改）。加强型运行时下实测正常：dlopen 系统私有框架（IOKit 的 IOAVService、DisplayServices）、ColorSync、IOKit 读写都不需要额外的 entitlement。

没有 Xcode 工程，也没有自动测试。改完至少要 `./build.sh` 无错误无警告，再在实机上验证（见下文「验证方法」）。重新运行前先 `pkill -x NitSync`。

## 结构

| 文件 | 作用 |
|---|---|
| `main.swift` | AppDelegate、菜单栏和菜单 |
| `Localization.swift` | `L("English text")` / `L("format %1$@", args…)`：按英文原文查本地化表，缺译文时显示英文 |
| `SyncEngine.swift` | 采样循环、渐变跟随、按 SDR/HDR 分发；`DDCWriter` 串行化 DDC 写入 |
| `BuiltinDisplay.swift` | 读内屏 nit（`disp0` 帧缓冲的 `IOMFBBrightnessLevel`） |
| `DDC.swift` | IOAVService 上的 DDC/CI 读写，读 EDID |
| `EDID.swift` | 解析厂商、型号、序列号、CTA-861 HDR 静态元数据 |
| `HDRBrightness.swift` | HDR 模式：DisplayServices 设系统亮度级别，读外接帧缓冲的 nit |
| `Screens.swift` | NSScreen/CGDisplay ↔ DDC 显示器的对应（靠 EDID 数字） |
| `Calibration.swift` | nit → DDC 值的分段线性映射，每台显示器一套 |
| `CalibrationOverlay.swift` | 全屏校准：所有屏幕上显示同物理尺寸的白块，键盘操作；分亮度、颜色两种模式 |
| `CalibrationOverlay+Color.swift` | 颜色模式的流程和文字：白色（W）或三档灰（G）、二选一提问、题间熄灭、结果确认、纯黑背景 |
| `ColorCalibration.swift` | `Staircase`（单轴阶梯法）、`ColorSession`（两轴随机穿插、随机起点）、`ColorCalibration`（白色和各档灰分别多轮平均，最多 5 轮；白色存在 `runs`，灰阶存在 `greyRuns`，旧数据只有 `runs` 也能读） |
| `ColorMath.swift` | `WhiteShift`（mired 冷暖 + Duv 绿紫）→ 白点 xy → 按外接屏 ICC 原色矩阵解出通道增益 → 色调表系数；`table(points:)` 按各档结果生成整条色调表 |
| `ColorCorrector.swift` | 由各档结果生成色调表（按显示器缓存）、算 HDR 亮度补偿系数；只在校准预览时直接写色调表，结束时 `CGDisplayRestoreColorSyncSettings` 让系统从描述文件重新载入 |
| `DisplayProfiles.swift` | 把校准写进描述文件：复制出厂描述文件，改名、写 `vcgt`、改原色坐标，设为显示器的当前用户级自定义描述文件；记录原来的条目，移除时写回 |
| `ICCProfile.swift` | 最小的 ICC 读写：保留文件头，重排标签表；`XYZ `、`vcgt`（16 位表）、`desc`、`mluc` 标签构造 |
| `PrimaryCalibration.swift` | 原色：`Primary`、`PrimaryShift`（u'v' 里的色相、饱和度）、`PrimaryMath`（按想要的显示变化反向移动描述文件原色，并重新缩放保持白点）、`PrimarySession`（6 个阶梯穿插） |
| `CalibrationOverlay+Primaries.swift` | 原色的流程和画面：外屏色块用候选描述文件换算出的设备值、按屏幕当前色彩空间直接画出（不切描述文件） |
| `Icon/AppIcon.icon` | Icon Composer 文档：`fill` 为 `automatic`（背景由系统按外观提供），两组图层（笔记本在上，显示器在下），每组的 `layers` 里排在前面的在上层。SVG 图层画布 1024×1024，整体用 `translate(29 32)` 居中。太阳是自己画的：SF Symbols 的许可不允许用在应用图标里 |
| `Icon/build-icon.sh` | `actool` 编译出 `Resources/Assets.car` 和 `AppIcon.icns`（都已提交），再用 Icon Composer 自带的 `ictool` 导出浅色、深色预览图。`ictool` 在 `Icon Composer.app/Contents/Executables/`，`xcrun` 找不到；渲染外观可选 Default、Dark、TintedLight、TintedDark、ClearLight、ClearDark |

## 本地化

- 基础语言英文，另有日文、简体中文、繁体中文。代码里所有界面文字都写成 `L("English text")`，英文原文就是键。
- 译文在 `Localization/translations.json`（每个键一条，ja / zh-Hans / zh-Hant 并排）。`build.sh` 先跑 `Localization/build-strings.py`：从源码里收集所有 `L("…")` 的键，检查每种语言都有译文、占位符（个数、类型、编号）和键一致，然后生成 `Resources/<语言>.lproj/Localizable.strings`（不提交，已在 `.gitignore`）。缺译文或占位符不对，构建直接失败。
- 带参数的句子用编号占位符（`%1$@`、`%2$ld`），各语言可以调整顺序。避免英文单复数：计数一律写成「runs so far: %ld」这类形式。英文用美式拼写（color、gray）。
- 繁体中文用台湾用语：內建螢幕、外接螢幕、校正、描述檔、儲存。日文：内蔵ディスプレイ、外部ディスプレイ、カラープロファイル。
- 换语言测试：`open -n build/NitSync.app --args -AppleLanguages "(ja)" --calibrate-color`。
- README 有英文（`README.md`）、日文（`README.ja.md`）、简体中文（`README.zh-Hans.md`）三版，改一版要同步另外两版；截图在 `docs/`，是英文界面。

## 私有接口与实测事实

全部通过 `dlopen`/`dlsym` 运行时查找，找不到就降级，不要改成链接。

- **内屏亮度**：`disp0` 下 `IOMobileFramebufferShim` 的 `IOMFBBrightnessLevel`，16.16 定点，单位 nit。它是背光级别，等于 SDR 白 × 当前 EDR 余量（`NSScreen.maximumExtendedDynamicRangeColorComponentValue`）：屏上有 EDR（HDR）内容时余量在约 2 s 内升到 16，读数跟着涨到上千 nit，SDR 白和画面都不变；内容消失后余量要过一段时间才降回。平时余量也常是 1.2 而不是 1。实测 SDR 白 86 nit 时，余量 1.2 读 103，余量 16 读 1378，爬升过程中两者之比偏差不超过 2 %；余量降回（内容消失约 15 s 后，约 2 s 降完）时外接屏也不动。用参考预设做了绝对校验：「HDR 视频（P3-ST 2084）」SDR 白固定 100 nit，读数 1000、余量 10（屏上没有 HDR 内容也是 10）；「摄影（P3-D65）」固定 160 nit，读数 160、余量 1。所以 NitSync 用读数 ÷ 余量（`BuiltinDisplay.sdrNits`）；外接帧缓冲的读数不受 EDR 影响，不用除。亮度键会让这个值在约 250 ms 内渐变（ease-out）；`DisplayServicesSetBrightness` 则是一步跳过去。
- **DDC**：`DCPAVServiceProxy`（`Location == "External"`）+ `IOAVServiceCreateWithService` / `WriteI2C` / `ReadI2C`，地址 0x37/0x51。DDC/CI 要求两次命令间隔 ≥ 50 ms，`DDCWriter` 用 60 ms。读 VCP 的回复（AW2725Q 实测）：`6E 88 02 00 10 00 00 64 00 22 E2`，最后一字节是 0x50 与前面所有字节的异或；有这个帧头但校验不对就当作读坏了，重读（读坏的最大值会影响整个会话）；完全没有帧头的回复仍按 `02 00 <vcp>` 认（别的显示器或转接器可能格式不同，不能因此丢掉整台显示器）。
- **EDID**：`IOAVServiceCopyEDID`，从 DDC 用的同一个服务取，不产生 DDC 通信。
- **屏幕对应**：`CGDisplayVendorNumber` / `ModelNumber` / `SerialNumber` 等于 EDID 里的原始厂商号、产品码、数字序列号。外接帧缓冲（`dispextN`）上的 `DisplayAttributes.ProductAttributes` 也有同样三个数（`LegacyManufacturerID`、`ProductID`、`SerialNumber`）。DDC 服务在 `dcpextN` 下，和 `dispextN` 不在一棵子树里，所以都靠 EDID 数字对应，不靠注册表路径。
- **HDR 判断**：`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1`。HDR 下显示器接收并保存 DDC 亮度值，但不改背光。
- **HDR 亮度**：信号是 PQ（绝对亮度），macOS 决定 SDR 白放在多少 nit，外接帧缓冲的 `IOMFBBrightnessLevel` 就是这个值。`DisplayServicesSetBrightness(id, 0…1)` 设置它，异步生效，调用约 0.02 ms，读回在 150 ms 内更新。AW2725Q 上实测：级别 0→1 对应 4→200 nit，表在 `HDRBrightness.table`。
- **`DisplayServicesSetBrightnessSmooth(id, delta)`**：第二个参数是增量，不是目标值（亮度键就是这么调的）。

- **色调表**：`CGSetDisplayTransferByTable` 在外接屏开着 HDR 时同样生效（用户目测确认过）。截图拿到的是色调表处理之前的画面，看不出效果。色调表归设置它的进程所有，进程退出后系统自动恢复 ColorSync 设置。
- **自定义描述文件的层级**：`ColorSyncDeviceSetCustomProfiles` 写「所有用户」级需要管理员权限，普通进程写会返回成功但不生效。系统设置选描述文件写的是「当前用户」级。把当前用户级设成 `kCFNull` 会清掉这一级原有的条目（包括系统设置写的那条），所以移除时要把记录的原条目显式写回，不能清空。设备信息里的 `CustomProfiles` 立刻反映变化；`CGDisplayCopyColorSpace` / `NSScreen.colorSpace` 要等进程处理完事件才更新，验证是否生效看硬件色调表最可靠。
- **`vcgt` 在 HDR 下会被载入**：描述文件切换后约 0.3 s，硬件色调表就等于它的 `vcgt`（读回验证过），切回原描述文件后复原。描述文件的原色坐标在 HDR 下同样影响显示（用户目测确认：绿原色写偏后整屏偏紫红）。
- **灰阶落在色调表的哪里**：色调表按设备编码值索引，外屏描述文件的 TRC 和 sRGB 几乎一样，所以 sRGB 灰 v 正好落在索引 v（用系统色彩转换算过）。用户目测验证：灰阶条上把索引 0.25、0.5 附近一窄段去掉红/蓝，青条在 25、黄条在 53–54（黄色偏亮侧更显眼，估读偏差），外屏白 174 nit 和 40 nit 时位置都不变。所以 HDR 下色调表不是在 PQ 编码之后才套用，按 sRGB 灰值放档位是对的。
- **色调表塌成全 0（黑屏）**：一个测试工具同时改了 HDR 亮度和色调表然后退出后，外屏的「回退表」变成了全 0：任何进程退出或调用 `CGDisplayRestoreColorSyncSettings` 后都回到全 0。把自定义描述文件切到出厂再切回来（`DisplayProfiles.reload`）才恢复。`SyncEngine.rescueBlackTables` 每 1 s 检查一次，表顶端连续两次低于 0.05 就自动这样恢复（只算一次会把系统睡眠、锁屏、重新配置时的淡出当成故障；睡着的显示器跳过；预览时不动，10 s 内最多一次）；故意清零后 1.9 s 恢复。
- **显示器配置文件**：两块屏的 ICC 都是系统生成的 v2 配置文件（内屏来自出厂数据，外接屏来自 EDID），白点都是 D65，`vcgt` 是恒等。`rXYZ` 等原色是相对 D50 的，要用 Bradford 变换回配置文件自己的白点（D65）再用。

## 颜色校准

- 参数：冷暖用 mired（感知上更均匀），绿紫用 CIE 1960 uv 里离普朗克轨迹的距离（Duv），零点就是 D65。
- 增益：用外接屏原色矩阵解出目标白点需要的线性 RGB，除以原生白点的，再归一到最大值 1（色调表只能往下调）。色调表作用在编码值上，所以系数取增益的 1/2.2 次方。指数只影响每步调多少，结果由人眼判断。
- 灰阶：档位是 sRGB 灰 1、0.5、0.25、0.12（0.12 是亮度校准界面的深灰背景，用户就是在这里看出色差的：白色对上后暗灰仍偏色，说明两块屏各通道暗部曲线不同，单一系数修不了）。每档的增益先归一到亮度不变，再统一乘一个让白色不超过 1 的系数，所以各档亮度比例不变、只改颜色，HDR 只需补这一个系数。档与档之间按灰度值的对数插值，最暗档以下、最亮档以上保持端点的值。没有白色结果时，白色按最亮的灰档的颜色、明暗为 0 补一个点（白框是判断灰阶明暗的参照，白色跟着变的话明暗题就看不出变化，保存后白色也会被一起压暗）。增益下限 0.01：超出色域的偏移会要求负的通道增益，`pow` 得到 NaN，而 `min(1, NaN)` 是 1，整条通道会变成全开。生成的表强制单调、不超过 1。验证：各档实际色度和目标差 ≤ 0.0002，各档亮度比例差 < 0.5%；只有白色时和旧的单系数结果逐项相同。
- 颜色模式背景用纯黑：两块都是 OLED，黑在两边一样；深灰背景本身有色差，会影响对白色的判断。
- 灰阶明暗：`WhiteShift.lightness`（档位亮度的变化，单位是档/stop，白色恒为 0）。在两块屏之间直接比绝对亮度不可靠（用户在并排对比里连 39% 的差别都看不出），所以灰块外围一圈白框，问的是「灰对照白框」的比例。表里在颜色增益之后再乘 2^lightness，档间同样按对数插值。参数：起点 ±0.3 档，步长 0.2，最小 0.025（约 1.7%）。模拟：判断噪声 0.05/0.1/0.25 档时误差约 2%/4%/10%，一轮灰阶约 28 题。旧数据没有 lightness 字段，按 0 读入。
- 亮度补偿：只在 HDR 下做（目标 nit 除以亮度损失系数）。SDR 的亮度校准本身是目测的，补偿会和它重复计算。
- 阶梯法参数：冷暖起点偏移 ±30 mired，步长 16，最小 2；绿紫起点 ±0.008，步长 0.005，最小 0.0006；每轴 6 次反转或 18 题结束，取最后 4 次反转点的平均。
- 「看不出差别」：值不动，记一次反转。模拟过的替代方案（抛硬币当作随机回答、对全部回答做三选项最大似然拟合）在现实的观察者参数下都更差，只有噪声和「看不出」区间都很大时才好一点，所以没采用。起点方向随机，一轮停在「看不出」区间哪一侧的偏差，多轮平均后会抵消。
- 稳定性：单轮里题目都集中在结果附近，自相矛盾的回答太少，分不出稳和不稳（模拟里噪声很大的观察者也有 95% 以上被判为稳定）。所以改为跨轮比较：和之前平均差超过 8 mired 或 Duv 0.0025 就提示。模拟：稳定观察者 1% 被提示，噪声大或常按错键的 19–75%。
- 模拟结果（观察者单次判断噪声 σ，「看不出」区间 ±1σ）：σ 4 mired 时一轮误差 RMS 约 2.2 mired，3 轮平均 1.2；σ 8 时约 3.9 和 2.2。一轮约 18–23 题。
- 题间白块变黑（不是灰）：色调表把黑映射成黑，所以换颜色时看不到变化。颜色在变黑后 0.1 s 才换，避免白块上闪一帧新颜色。
- 保存位置：所有颜色校正都写进描述文件，NitSync 平时不写色调表，也不再定时检查。启动和重新连接显示器时，如果有校准但从没装过描述文件（例如从旧版本升级），会自动安装；装过又被换掉的，视为用户在系统设置里改的，不再装回。每次安装用新文件名（毫秒时间戳），旧文件删除，避免系统用缓存的旧内容。「原来的描述文件」记录（`originalDisplayProfiles`）只在安装成功后写；当时没在用 NitSync 描述文件的话，每次安装都重新记下用户当前的选择（用户在两次保存之间可能在系统设置里换过）。移除需要显示器在线：不在线时记录和文件都保留（否则显示器会指向已删除的文件，也没法再恢复），`--reset-color` 会等发现完成、重试到 15 s，仍有没连接的就弹窗列出。描述文件生成失败（设备信息还没就绪等）时保持原样，不当作「没有可校正的」去移除。
- 原色：描述文件声称的原色往一边移，色彩管理显示出来的颜色往另一边移，所以想让显示往哪边走，就把声称的原色往反方向移，再重新缩放三个原色让它们的和仍是原来的白。测试色是 sRGB 原色（在两块屏的色域内）。用出厂原色当作「真实」原色验算过：方向正确，实际移动量是要求的 55–87%（sRGB 原色在色域内部，移动打了折扣，由阶梯法自行补偿），方向间串扰不超过约 15%，白点不动。参数：起点 ±0.012，步长 0.008，最小 0.001（u'v'）。

## 跟随算法（SyncEngine）

- 内屏或任何外接屏还在变化时 120 Hz 采样（隐藏设置 `activeRate` 可改）。实测 60/120/240 Hz：每次渐变外接屏的台阶数 15/21/21，延迟都在 35–45 ms；240 Hz 没有收益，外接屏那一侧每次渐变只接受约 21 次更新。
- 唤醒：`DisplayServicesRegisterForBrightnessChangeNotifications`（私有，`BuiltinDisplay.observeBrightnessChanges`）在亮度请求后约 1 ms、`IOMFBBrightnessLevel` 开始动之前 10–20 ms 回调，带目标值。闲置时收到就开一条新的采样链（`tickGeneration` 让旧链停掉），已经在快速采样时只延长 0.6 s 的快速期（自动亮度渐变时大约每 10 ms 发一次，每次都重启会把采样推到 120 Hz 以上）。亮度键、控制中心（用户实测）和自动亮度（遮住环境光传感器实测：渐变前约 47 ms 开始通知，全程持续）都会发。分布式通知和 IOKit 兴趣通知在亮度变化时都没有动静。启动时内屏不在线（合盖接外屏登录）注册会失败，每次重新发现硬件时重试。所以闲置轮询降到 1 Hz，只剩慢速检查：HDR 开关、系统设置里拖外屏亮度后的拉回、描述文件是否被换掉、防黑屏（拿不到这个私有调用时仍是 20 Hz）。以前闲置时最晚 50 ms 才发现渐变，6 次里有 4 次开头追赶跳 15–28%；现在开头 0–5%，最大一步 12%（在渐变最陡的中段）。
- 闲置开销：0.0–0.1% CPU（6 次渐变共约 90 ms CPU）。描述文件是否在用（ColorSync 跨进程调用）每 5 s 查一次（NitSync 自己安装或移除后立刻更新），防黑屏检查每 1 s 一次，菜单内容只在菜单打开时刷新。之前这三项每 0.5–1 s 跑一次，闲置 0.5%。
- 外接屏的目标在对数亮度上缓动：时间常数 20 ms，速度上限 20/s。系统 250 ms 渐变基本原样通过（实测外接屏落后 30–40 ms），一步跳变变成约 0.2 s 渐变。
- 计算缓动的 `dt` 上限是 1/30 s：闲置后第一帧间隔较长，不加上限会一下走完大半。下限是 0，时钟用开机时长（单调），不用 `Date()`：墙上时钟往回调会让 `dt` 变负，缓动反而一下冲到最亮，跳得多时 `exp` 溢出成 inf 再也回不来。
- 没有内屏读数时（内屏关掉、合盖）外接屏保持原值，`correctHDR` 也不跑，这样合盖时用户在系统设置里调外屏亮度不会被拉回。
- HDR：渐变中按「表 + 偏差」开环逐帧设置；稳定 0.3 s 后用帧缓冲读数和当前实际级别重新求偏差（`correctHDR`），这样系统设置里手动拖动也会被拉回。
- SDR：DDC 值有 0.75 的滞回防抖动；缓动到位那一帧强制发送，避免最后一级被滞回吞掉。

## 验证方法

亮度对不对，看两边帧缓冲的 nit 最直接：

```bash
ioreg -r -n disp0    -l -w0 | grep -m1 '"IOMFBBrightnessLevel"' | awk '{printf "%.1f\n", $NF/65536}'
ioreg -r -n dispext0 -l -w0 | grep -m1 '"IOMFBBrightnessLevel"' | awk '{printf "%.1f\n", $NF/65536}'
```

检查渐变：写个小程序，用 `DisplayServicesSetBrightnessSmooth(1, -0.25)` 模拟亮度键，同时每 4 ms 记录上面两个值，对比曲线，结束后恢复原级别。改动用户的亮度前先告诉用户，测完恢复。

DDC 读写可以用 `DDC.swift` + `EDID.swift` 加一个小 `main.swift` 单独编译测试；测试前先 `pkill -x NitSync`，避免两边同时写 DDC。

## 已知限制

- 只处理能通过 DDC 发现的外接屏，HDR 路径也是（发现阶段依赖 DDC）。
- SDR 路径的渐变受 DDC 速度限制，只在 HDR 模式下实测过平滑效果。
- 多台外接屏的匹配、切换和校准没在实机上测过。
- 颜色校准的答题流程（题间熄灭、结果页、保存、多轮平均）没法自动化测试（发不了按键事件），只有算法做过模拟验证，界面靠截图检查。用户实际走过一轮白色。
- 原色预览是把候选描述文件换算出的设备值按屏幕当前色彩空间画出来，假设窗口合成时这一步不再转换；没有仪器，无法直接测量。
- 系统更新可能改动以上任何私有接口或注册表属性。

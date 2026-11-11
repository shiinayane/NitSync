# NitSync

菜单栏小工具：让外接显示器的亮度按 nit 跟随 MacBook 内屏。用户文档见 README.md，这里记录改代码时需要知道、但从代码里不容易看出来的事。

## 构建与运行

```bash
./build.sh                                   # swiftc 直接编译，产物 build/NitSync.app（ad-hoc 签名）
open build/NitSync.app
open build/NitSync.app --args --calibrate        # 启动后直接进入亮度校准
open build/NitSync.app --args --calibrate-color  # 启动后直接进入颜色校准
open build/NitSync.app --args --calibrate-grey   # 直接开始灰阶（没法发按键时用来截图检查）
```

版本号用 1.0.0 格式（语义化版本），写在 `Info.plist` 的 `CFBundleShortVersionString`，发布时打 `v1.0.0` 这样的 git 标签；`CFBundleVersion` 是构建号，每次发布加 1。

没有 Xcode 工程，也没有自动测试。改完至少要 `./build.sh` 无错误无警告，再在实机上验证（见下文「验证方法」）。重新运行前先 `pkill -x NitSync`。

## 结构

| 文件 | 作用 |
|---|---|
| `main.swift` | AppDelegate、菜单栏和菜单 |
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
| `ColorCorrector.swift` | 把整条色调表写进外接屏（`CGSetDisplayTransferByTable`），按各档结果缓存，每 2 s 检查是否被别人改掉 |
| `Icon/AppIcon.icon` | Icon Composer 文档：`fill` 为 `automatic`（背景由系统按外观提供），两组图层（笔记本在上，显示器在下），每组的 `layers` 里排在前面的在上层。SVG 图层画布 1024×1024，整体用 `translate(29 32)` 居中。太阳是自己画的：SF Symbols 的许可不允许用在应用图标里 |
| `Icon/build-icon.sh` | `actool` 编译出 `Resources/Assets.car` 和 `AppIcon.icns`（都已提交），再用 Icon Composer 自带的 `ictool` 导出浅色、深色预览图。`ictool` 在 `Icon Composer.app/Contents/Executables/`，`xcrun` 找不到；渲染外观可选 Default、Dark、TintedLight、TintedDark、ClearLight、ClearDark |

## 私有接口与实测事实

全部通过 `dlopen`/`dlsym` 运行时查找，找不到就降级，不要改成链接。

- **内屏亮度**：`disp0` 下 `IOMobileFramebufferShim` 的 `IOMFBBrightnessLevel`，16.16 定点，单位 nit。亮度键会让这个值在约 250 ms 内渐变（ease-out）；`DisplayServicesSetBrightness` 则是一步跳过去。
- **DDC**：`DCPAVServiceProxy`（`Location == "External"`）+ `IOAVServiceCreateWithService` / `WriteI2C` / `ReadI2C`，地址 0x37/0x51。DDC/CI 要求两次命令间隔 ≥ 50 ms，`DDCWriter` 用 60 ms。
- **EDID**：`IOAVServiceCopyEDID`，从 DDC 用的同一个服务取，不产生 DDC 通信。
- **屏幕对应**：`CGDisplayVendorNumber` / `ModelNumber` / `SerialNumber` 等于 EDID 里的原始厂商号、产品码、数字序列号。外接帧缓冲（`dispextN`）上的 `DisplayAttributes.ProductAttributes` 也有同样三个数（`LegacyManufacturerID`、`ProductID`、`SerialNumber`）。DDC 服务在 `dcpextN` 下，和 `dispextN` 不在一棵子树里，所以都靠 EDID 数字对应，不靠注册表路径。
- **HDR 判断**：`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1`。HDR 下显示器接收并保存 DDC 亮度值，但不改背光。
- **HDR 亮度**：信号是 PQ（绝对亮度），macOS 决定 SDR 白放在多少 nit，外接帧缓冲的 `IOMFBBrightnessLevel` 就是这个值。`DisplayServicesSetBrightness(id, 0…1)` 设置它，异步生效，调用约 0.02 ms，读回在 150 ms 内更新。AW2725Q 上实测：级别 0→1 对应 4→200 nit，表在 `HDRBrightness.table`。
- **`DisplayServicesSetBrightnessSmooth(id, delta)`**：第二个参数是增量，不是目标值（亮度键就是这么调的）。

- **色调表**：`CGSetDisplayTransferByTable` 在外接屏开着 HDR 时同样生效（用户目测确认过）。截图拿到的是色调表处理之前的画面，看不出效果。色调表归设置它的进程所有，进程退出后系统自动恢复 ColorSync 设置。
- **显示器配置文件**：两块屏的 ICC 都是系统生成的 v2 配置文件（内屏来自出厂数据，外接屏来自 EDID），白点都是 D65，`vcgt` 是恒等。`rXYZ` 等原色是相对 D50 的，要用 Bradford 变换回配置文件自己的白点（D65）再用。

## 颜色校准

- 参数：冷暖用 mired（感知上更均匀），绿紫用 CIE 1960 uv 里离普朗克轨迹的距离（Duv），零点就是 D65。
- 增益：用外接屏原色矩阵解出目标白点需要的线性 RGB，除以原生白点的，再归一到最大值 1（色调表只能往下调）。色调表作用在编码值上，所以系数取增益的 1/2.2 次方。指数只影响每步调多少，结果由人眼判断。
- 灰阶：档位是 sRGB 灰 1、0.5、0.25、0.12（0.12 是亮度校准界面的深灰背景，用户就是在这里看出色差的：白色对上后暗灰仍偏色，说明两块屏各通道暗部曲线不同，单一系数修不了）。每档的增益先归一到亮度不变，再统一乘一个让白色不超过 1 的系数，所以各档亮度比例不变、只改颜色，HDR 只需补这一个系数。档与档之间按灰度值的对数插值，最暗档以下、最亮档以上保持端点的值。生成的表强制单调、不超过 1。验证：各档实际色度和目标差 ≤ 0.0002，各档亮度比例差 < 0.5%；只有白色时和旧的单系数结果逐项相同。
- 颜色模式背景用纯黑：两块都是 OLED，黑在两边一样；深灰背景本身有色差，会影响对白色的判断。
- 灰阶明暗：`WhiteShift.lightness`（档位亮度的变化，单位是档/stop，白色恒为 0）。在两块屏之间直接比绝对亮度不可靠（用户在并排对比里连 39% 的差别都看不出），所以灰块外围一圈白框，问的是「灰对照白框」的比例。表里在颜色增益之后再乘 2^lightness，档间同样按对数插值。参数：起点 ±0.3 档，步长 0.2，最小 0.025（约 1.7%）。模拟：判断噪声 0.05/0.1/0.25 档时误差约 2%/4%/10%，一轮灰阶约 28 题。旧数据没有 lightness 字段，按 0 读入。
- 亮度补偿：只在 HDR 下做（目标 nit 除以亮度损失系数）。SDR 的亮度校准本身是目测的，补偿会和它重复计算。
- 阶梯法参数：冷暖起点偏移 ±30 mired，步长 16，最小 2；绿紫起点 ±0.008，步长 0.005，最小 0.0006；每轴 6 次反转或 18 题结束，取最后 4 次反转点的平均。
- 「看不出差别」：值不动，记一次反转。模拟过的替代方案（抛硬币当作随机回答、对全部回答做三选项最大似然拟合）在现实的观察者参数下都更差，只有噪声和「看不出」区间都很大时才好一点，所以没采用。起点方向随机，一轮停在「看不出」区间哪一侧的偏差，多轮平均后会抵消。
- 稳定性：单轮里题目都集中在结果附近，自相矛盾的回答太少，分不出稳和不稳（模拟里噪声很大的观察者也有 95% 以上被判为稳定）。所以改为跨轮比较：和之前平均差超过 8 mired 或 Duv 0.0025 就提示。模拟：稳定观察者 1% 被提示，噪声大或常按错键的 19–75%。
- 模拟结果（观察者单次判断噪声 σ，「看不出」区间 ±1σ）：σ 4 mired 时一轮误差 RMS 约 2.2 mired，3 轮平均 1.2；σ 8 时约 3.9 和 2.2。一轮约 18–23 题。
- 题间白块变黑（不是灰）：色调表把黑映射成黑，所以换颜色时看不到变化。颜色在变黑后 0.1 s 才换，避免白块上闪一帧新颜色。

## 跟随算法（SyncEngine）

- 内屏或任何外接屏还在变化时 60 Hz 采样，静止时 20 Hz（闲置 CPU 约 0.3%）。
- 外接屏的目标在对数亮度上缓动：时间常数 20 ms，速度上限 20/s。系统 250 ms 渐变基本原样通过（实测外接屏落后 30–40 ms），一步跳变变成约 0.2 s 渐变。
- 计算缓动的 `dt` 上限是 1/30 s：闲置后第一帧间隔较长，不加上限会一下走完大半。
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
- 颜色校准的答题流程（题间灰屏、结果页、保存、多轮平均）没法自动化测试（发不了按键事件），只有算法做过模拟验证，界面靠截图检查。
- 系统更新可能改动以上任何私有接口或注册表属性。

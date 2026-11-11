# NitSync

菜单栏小工具：让外接显示器的亮度按 nit 跟随 MacBook 内屏。用户文档见 README.md，这里记录改代码时需要知道、但从代码里不容易看出来的事。

## 构建与运行

```bash
./build.sh                                   # swiftc 直接编译，产物 build/NitSync.app（ad-hoc 签名）
open build/NitSync.app
open build/NitSync.app --args --calibrate    # 启动后直接进入全屏校准
```

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
| `CalibrationOverlay.swift` | 全屏校准：所有屏幕上显示同物理尺寸的白块，键盘操作 |

## 私有接口与实测事实

全部通过 `dlopen`/`dlsym` 运行时查找，找不到就降级，不要改成链接。

- **内屏亮度**：`disp0` 下 `IOMobileFramebufferShim` 的 `IOMFBBrightnessLevel`，16.16 定点，单位 nit。亮度键会让这个值在约 250 ms 内渐变（ease-out）；`DisplayServicesSetBrightness` 则是一步跳过去。
- **DDC**：`DCPAVServiceProxy`（`Location == "External"`）+ `IOAVServiceCreateWithService` / `WriteI2C` / `ReadI2C`，地址 0x37/0x51。DDC/CI 要求两次命令间隔 ≥ 50 ms，`DDCWriter` 用 60 ms。
- **EDID**：`IOAVServiceCopyEDID`，从 DDC 用的同一个服务取，不产生 DDC 通信。
- **屏幕对应**：`CGDisplayVendorNumber` / `ModelNumber` / `SerialNumber` 等于 EDID 里的原始厂商号、产品码、数字序列号。外接帧缓冲（`dispextN`）上的 `DisplayAttributes.ProductAttributes` 也有同样三个数（`LegacyManufacturerID`、`ProductID`、`SerialNumber`）。DDC 服务在 `dcpextN` 下，和 `dispextN` 不在一棵子树里，所以都靠 EDID 数字对应，不靠注册表路径。
- **HDR 判断**：`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1`。HDR 下显示器接收并保存 DDC 亮度值，但不改背光。
- **HDR 亮度**：信号是 PQ（绝对亮度），macOS 决定 SDR 白放在多少 nit，外接帧缓冲的 `IOMFBBrightnessLevel` 就是这个值。`DisplayServicesSetBrightness(id, 0…1)` 设置它，异步生效，调用约 0.02 ms，读回在 150 ms 内更新。AW2725Q 上实测：级别 0→1 对应 4→200 nit，表在 `HDRBrightness.table`。
- **`DisplayServicesSetBrightnessSmooth(id, delta)`**：第二个参数是增量，不是目标值（亮度键就是这么调的）。

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
- 系统更新可能改动以上任何私有接口或注册表属性。

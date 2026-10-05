# Fuck-MSI-Center

Fuck-MSI-Center 是適用於 MSI Sword 16 HX E15P2 平台的輕量 MSI Center 替代工具。已完成
完整實機驗證的機型是 B14VGKG；使用相同 E15P2IMS.110 BIOS 的 B14VEKG／B14VFKG
以「水平相容模式」開放 GPU MUX 與 GPU 調校。除此之外，工具也在完整驗證機型提供
系統快捷控制與電池充電上限：

- MSHybrid、Discrete 與 Integrated 三模式狀態與切換；
- 直接 UEFI authoritative status、legacy WMI cross-check 與 AP pending guard；
- 每次 firmware request 前只顯示一次完整計畫與副作用確認；
- 預設關閉的 post-acceptance 自動完整關機，警告併入同一次切換確認；
- Windows Per-Monitor DPI Awareness v2 與跨螢幕縮放；
- scrolling log 與正常 Windows UAC 提權。
- Extreme Performance 與 User 的 GPU core／VRAM profile 讀取及保存；
- Balanced、Silent、Super Battery 的 MSI `0/0` 規則預覽；
- Gaming Active（引用 Extreme）與 Gaming Inactive（`0/0`）模擬；
- `GInf.GetGInfo` 唯讀即時 offset／P-state／溫度顯示；
- `NvAPI_GPU_GetPstates20` 唯读取得实际 P0 delta min/max；
- 同步滑块与数字框，滑块下方显示 1/2/5 自动分段刻度；
- 經簽章、機型、GPU 名稱、範圍與逐次警告保護的暫時 offset 套用。
- 直接 `MSI_ACPI` 內建攝影機開關，以及 Windows 鍵、Fn／Windows 鍵交換；
- 每次系統設定修改前顯示精確直接 WMI／CentralServer 命令、frame 與已知副作用；
- 跨程序序列化 CentralServer 事务、单次 Set 与 Get 读回验证，失败不重试。
- Battery Master 60%、80%、100% 充電上限，使用直接 MSI_ACPI 後端；
- 目前硬體上限讀取、逐次確認、保留 D7 最高位元與单次寫入後讀回驗證。

此目錄是自包含的發布單位，可直接作為 GitHub repository 根目錄。GUI 不依賴上層
`Fuck-MSI-Center-RE` 的研究筆記、evidence 或其他 `tools` 目錄。

## 目錄結構

```text
Fuck-MSI-Center/
├─ fuck_msi_center.py               # Tkinter GUI
├─ README.md
├─ .gitignore
├─ backend/
│  ├─ Invoke-FuckMsiCenter.ps1          # Status / Plan / Request JSON bridge
│  ├─ MsiGpuModeApi.psd1             # PowerShell module manifest
│  ├─ MsiGpuModeApi.psm1             # Structured API
│  ├─ MsiGpuOcApi.psd1                # GPU offset API manifest
│  ├─ MsiGpuOcApi.psm1                # Profile/status/probe/guarded apply API
│  ├─ MsiSystemControlApi.psd1         # 系統快捷控制 manifest
│  ├─ MsiSystemControlApi.psm1         # Allowlist/status/plan/guarded Set API
│  ├─ MsiDirectHardwareApi.psd1         # 去服務化 WMI／UEFI manifest
│  ├─ MsiDirectHardwareApi.psm1         # 直接 MSI_ACPI、UEFI probe／plan／guarded request
│  ├─ NvapiDriverLimits.ps1            # Read-only GetPstates20 driver limits
│  ├─ Test-MsiGpuOcApi.ps1            # Non-destructive bundled API tests
│  ├─ Test-MsiSystemControlApi.ps1     # IsSupport/Get/Plan 非破壞測試
│  ├─ Test-MsiDirectHardwareApi.ps1     # 直接後端零寫入 contract test
│  ├─ Test-MsiBatteryApi.ps1            # 電池硬體 mock tests／可選唯讀實機檢查
│  ├─ Test-MsiGpuModeApi.ps1             # Production Status／Plan 唯讀整合測試
│  ├─ Read-MsiGpuMode.ps1            # Read-only applied-mode probe
│  ├─ Read-MsiGpuSwitchRequestState.ps1 # Read-only Get_AP(0) probe
│  └─ Request-MsiGpuModeViaCentralServer.ps1 # Guarded write harness
└─ tests/
   └─ test_fuck_msi_center.py
```

Production GPU MUX firmware write 邏輯位於 `MsiDirectHardwareApi.psm1`，透過 Windows
firmware-environment API 與直接 `MSI_ACPI` 執行；舊 CentralServer harness 只保留作研究
比較。GPU profile／offset 寫入只存在於 `MsiGpuOcApi.psm1`，General Settings Set 只存在於 `MsiSystemControlApi.psm1`。Python GUI 只呼叫 `backend\Invoke-FuckMsiCenter.ps1` 的 JSON API，
不直接寫 Registry、WMI、UEFI、EC 或 NVAPI。電池充電上限的讀取、計畫與受護寫入也位於
`MsiDirectHardwareApi.psm1`。

## 系統需求

- Windows 11；
- Windows PowerShell 5.1；
- Python 3.10+，安裝時包含 Tcl/Tk；
- MSI firmware 的 `MSI_ACPI` WMI provider；只有 WinKey 與 Fn／Win 仍需 MSI Center／NBFoundation 對應服務；
- 切換模式需要正常 Windows UAC 系統管理員權限。

### 機型與功能層級

| SMBIOS 機型 | GPU MUX | GPU OC | 系統快捷控制 | 電池上限 |
|---|---:|---:|---:|---:|
| Sword 16 HX B14VGKG | 完整驗證 | 開放 | 開放 | 開放 |
| Sword 16 HX B14VEKG | E15P2 水平相容 | 開放 | 鎖定 | 鎖定 |
| Sword 16 HX B14VFKG | E15P2 水平相容 | 開放 | 鎖定 | 鎖定 |
| 其他機型 | 拒絕 | GUI 鎖定 | 拒絕 | 拒絕 |

三個 Sword 16 HX GPU SKU 的原廠 E15P2IMS.110 映像已確認 SHA-256 與逐位元內容完全
相同。水平相容機型啟動後會顯示一次警告，且每次 MUX 寫入確認仍會標示尚未完成該
SKU 的實機寫入驗證。這只擴大 GPU capability 的精確 allowlist；WebCam、Battery 與
其他 EC 功能仍由後端鎖定在 B14VGKG。

不應移除硬體身分、WMI instance、UEFI layout、support bit、AP 或 read-back guards 後
強行使用，也不應把 `Sword 16*` 當成無條件萬用匹配。

## GPU MUX 直接後端

GPU Status／Plan／Request 已使用 `WindowsFirmwareApi+DirectWmiAcpi`：直接讀寫 UEFI
`MsiDCVarData` byte 5，並以 `MSI_ACPI` D1／AP／BE 完成 request。這條路徑不載入
Base Module、不連線 CentralServer 32683、不寫 `GPUswitchCH`，也不檢查兩者版本。

實機 Hybrid → Discrete 測試已完成 request、完整關機／開機與 post-boot 驗證：byte 5
由 `0x30` staging 成 `0x31`，開機後為 `0x35`；UEFI applied/staged 均為 Discrete、
`Get_Device(1).Data[0]=0x4B`、AP pending clear。production API／GUI 因而已切換至此後端。

## 系統快捷控制

主視窗按「系統快捷控制」開啟三個經 allowlist 的 MSI Base Module 功能：

| 功能 | 官方實作路徑 | `Enabled=1` 意義 |
|---|---|---|
| WebCam | 直接 `MSI_ACPI.Get_Device(1)`／`Set_Data(0x2E)` bit1 | 內建攝影機啟用 |
| WinKey | `GeneralSetting\WinKey` + OmApSvcBroker keyboard hook | Windows 鍵啟用 |
| SwitchFnWin | `WinFn` + keyboard MCU + broker EC/UEFI flag | Fn／Windows 鍵已交換 |

重新整理與 Plan 只做唯讀查詢。WebCam 在 elevated GUI 中直接讀 `MSI_ACPI`；按修改後
顯示 `Set_Data(0x2E)` read-modify-write 計畫，不建立 TCP frame，也不檢查 Base Module／
CentralServer 版本。確認後只寫一次，再以 `Get_Device(1)` 精確讀回；失敗絕不自動重試。

WinKey 與 SwitchFnWin 仍使用 `IsSupport/Get/Set` service path，因為前者真正生效需要
broker keyboard hook，後者還同時涉及 EC、UEFI 與 keyboard MCU HID 一致性。這兩項才
會驗證 Base Module ID/initialized、CentralServer PID/port 與 MSI Authenticode 簽章。

CentralServer 32683 在同时处理多个 client 时可发生 response crossover。API 因此以
`Local\MsiGpuModeGui-CentralServer-32683` 跨程序 mutex 包住完整 Status／Plan／Set+read-back
事务。不要绕过此 API 自行并发发送命令。
锁名称保留旧版标识，以便与旧版本共用并发保护；它不是产品名称。

General Settings API 仍精確鎖定已驗證的 Sword 16 HX B14VGKG，但不再因版本號不同而封鎖。
Base Module 1.0.2606.0801 與 CentralServer 3.2026.0427.01 是已驗證基準；不同版本在
MSI Authenticode、服務身分、component ID、port 與 `IsSupport/Get` 檢查通過後仍可使用，
Status、Plan、Set 與 GUI 都會顯示「尚未驗證版本」警告。
`OD`、`HSR_Panel`、`USB_LED` 在本機不支援；`Backlight` 的三值语义和 fan result 尚未完整证明，
因此即使 dispatcher 中存在对应字符串也不会开放。

## 電池充電上限

主視窗按「電池充電上限」，即可讀取目前硬體上限並選擇 MSI Battery Master 三種模式：

| 上限 | 模式 | 官方充電規則 |
|---|---|---|
| 60% | 最佳保養 / Best for Battery | 電量低於 50% 開始充電，60% 停止 |
| 80% | 平衡保養 / Balanced | 電量低於 70% 開始充電，80% 停止 |
| 100% | 最佳行動 / Best for Mobility | 充電至 100% |

規則來源：[MSI 官方使用手冊](https://tw.msi.com/support/technical_details/NB_%20SW_MSI_Center)。
降低上限不會主動將電池放電。工具只開放官方後端已證實的三個 preset，不提供任意百分比。

後端直接呼叫 `MSI_ACPI.Get_Data(0xD7)`，以 `raw & 0x7F` 讀取上限。按「套用充電上限」
會先重新建立唯讀 Plan，確認後重新讀取 D7、保留 bit7，再寫入 `(raw & 0x80) | limit`。
整個 Set／read-back 使用既有 MSI_ACPI 跨程序 mutex，最多寫一次；目前值已相同時零寫入。
失敗或未知 response／上限會鎖定套用按鈕，須重新整理，不自動重試。

此功能不需要 MSI Center UI／CentralServer，不載入 MSI DLL，也不改 MSI Registry 偏好。
重新開啟 MSI Center 或其 AI Charger 時可能重新套用官方保存的模式；若讀到
`BatteryMode=3`，視窗及套用確認會提示 AI Charger 可能覆蓋設定。缺少 MSI 偏好鍵不影響
直接後端。此功能仍鎖定 Sword 16 HX B14VGKG，套用需要管理員權限。

驗證範圍（2026-10-02）：本機官方服務唯讀命令讀到 raw `0xE4`、上限 100%；18 組後端
mock 模式轉換與 8 個電池 GUI 測試通過。此次 UAC 被取消，直接 production WMI 讀取與
實際 Set／充電停止行為尚未實機驗證，沒有修改本機充電上限。

## GPU 核心／VRAM 調校

主視窗按「GPU 核心／VRAM 調校」開啟獨立視窗。重新整理會進行兩個唯讀操作：

1. 讀取 MSI `Scenario`／`User Scenario` Registry。
2. 呼叫 `GInf.InitialAndGetCurrentG`、`GetGInfo`、`Unload` 讀取目前 driver offset。

場景對應遵循實際 `OmApSvcBroker`：

| GUI 目標 | 實際來源 |
|---|---|
| Extreme Performance | `High_GPU_Core`, `High_GPU_VRAM` |
| Balanced／Silent／Super Battery | 固定 `0/0` |
| User | `User_GPU_Core`, `User_GPU_VRAM` |
| Gaming Mode Active | 引用 Extreme Performance |
| Gaming Mode Inactive | `0/0` |

三個操作相互分離：

- **預覽計畫**：完全唯讀。
- **保存 Extreme／User profile**：只更新對應的 MSI DWORD Registry 值；不碰 GPU。
- **立即套用至 GPU**：呼叫 MSI 簽署的 `gpuControl.exe core memory` 並以 GInf 讀回驗證；不保存 profile、不切換完整場景。

保存與套用都有各自的逐次警告。後端還會確認系統管理員權限、`IsSupOC=1`、
精確機型、精確 NVIDIA adapter 名稱、动态 NVIDIA driver range，以及 `gpuControl.exe`／`GInf.dll`
Authenticode 簽章。GPU OC 後端只允許上述三個精確 E15P2 SMBIOS 機型名稱；任何失敗
都不會自動重試。

本机 NVIDIA driver 616.92 实读范围为 core `-1000..1000 MHz`、VRAM
`-1000..3000 MHz`。GUI 为确保 MSI/GInf 读回验证可靠，只开放非负 `0..1000` 与
`0..3000`；若 driver 查询失败则回退 MSI `0..200`。高于 MSI UI policy 的值会显示额外警告。

## 啟動

在此目錄執行：

```powershell
python .\fuck_msi_center.py
```

若 `python` 不在 PATH，可使用 Windows Python launcher：

```powershell
py -3 .\fuck_msi_center.py
```

正常啟動時，程式會在建立任何 Tk 視窗或執行 status probe 前檢查權限。若目前不是
系統管理員，會立即透過 Windows `runas` 顯示 UAC，啟動 elevated child 後退出原程序。
取消或無法完成 UAC 時，主 GUI 不會開啟，也不會執行 status、request 或 shutdown。
`--self-test` 是唯一不要求提權的執行模式。

## 切換與關機行為

1. GUI 重新讀取 Status、`Get_AP(0)` 與 side-effect-free Plan。
2. AP bit1 pending、UEFI staged/applied 不一致、未知硬體或 WMI cross-check 異常時停止，不送 request。
3. 只顯示一次切換確認，包含 UEFI byte 5 staging、直接 D1、2000 ms delay 與 BE02 acknowledgment 副作用；若勾選自動關機，同一視窗會提醒立即關機與先儲存工作。
4. 使用者確認後，JSON API 執行一次 guarded direct transaction；不寫 MSI Registry、不送 CentralServer frame。
5. `RequestAccepted=true` 只表示 request 被接受，不等於模式已 applied。
6. 完整關機／開機後仍須重新整理，以 UEFI applied/staged、AP clear 與 legacy WMI cross-check 驗證。

「切換 request accepted 後自動執行 shutdown /s -t 0」預設不勾選：

- 勾選後，立即關機警告會併入唯一的模式切換確認視窗，不再出現額外確認；
- 在確認視窗選擇「否」時，不送 request、也不執行關機；
- 只有同一次 JSON result 同時為 `Success=true`、`RequestAccepted=true` 才啟動
  `shutdown.exe /s /t 0`；
- failure、partial completion、AP pending、`AlreadyApplied=true` 或未勾選時都不會自動關機；
- request 失敗後永不自動 retry。

## High-DPI

程式在建立第一個 `Tk()` 視窗前啟用 Windows Per-Monitor DPI Awareness v2，依所在螢幕
實際 DPI 設定 Tk scaling、視窗尺寸、padding 與 wrap width；跨螢幕後會重新套用 scaling，
避免 Windows bitmap stretching 造成模糊。

## 測試

Parser／純函式 self-test（不建立 GPU request、不關機）：

```powershell
python .\fuck_msi_center.py --self-test
```

隱藏 Tk 視窗與 shutdown control-flow 回歸測試。`Request` 與 `shutdown` 均被 mock：

```powershell
python .\tests\test_fuck_msi_center.py
```

測試涵蓋預設不勾選、三種模式在勾選／未勾選自動關機時均只確認一次、拒絕確認時零 request、failure 不關機、未 opt-in 不關機、
accepted + opt-in 只呼叫 mocked shutdown、非管理員啟動／UAC 取消時不建立 Tk 視窗，
以及取消 GPU profile 保存／offset 套用時零 backend call、Gaming target 映射與確認旗標。

Bundled GPU OC API 的非破壞測試：

```powershell
.\backend\Test-MsiGpuOcApi.ps1
.\backend\Test-MsiGpuOcApi.ps1 -IncludeNativeProbe
```

此測試會 snapshot Registry，驗證六種 plan、save preview、未確認 save/apply 阻擋，
最後確認 Registry 完全未改變。`-IncludeNativeProbe` 只增加 `GetGInfo` 讀取。

Bundled 系統快捷控制 API 的非破壞測試：

```powershell
.\backend\Test-MsiSystemControlApi.ps1
```

此測試只送 `IsSupport`／`Get`，驗證三個 Plan、未確認 Set guard、相关 Registry 与三项
feature state 前后不变；测试输出中的 `SetCommandsSent` 必须为 `0`。

直接硬體後端的零寫入 contract test：

```powershell
.\backend\Test-MsiDirectHardwareApi.ps1
```

此測試驗證 GPU UEFI byte 5 mask、D1/BE plan 與 WebCam confirmation guard，輸出中的
`SetDataCalls` 與 `FirmwareWriteCalls` 必須都是 `0`。非 elevated shell 會跳過需要
`SeSystemEnvironmentPrivilege`／MSI_ACPI 權限的 live read-only probe。

Production GPU API 的 elevated 唯讀整合測試：

```powershell
.\backend\Test-MsiGpuModeApi.ps1 -Json
```

此測試驗證 Status、三種 target Plan、confirmation guard、Registry 前後一致，並要求
`CentralServerFramesSent=0`、`FirmwareWrites=0`、`SetDataCalls=0`。Hybrid → Discrete 的
完整 post-boot applied 驗證已通過，因此 GUI GPU 模式按鈕現已使用 direct backend。

電池 API 測試（預設完全 mock 硬體，不修改本機上限）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\backend\Test-MsiBatteryApi.ps1 -Json
```

正常管理員 PowerShell 可增加直接 WMI 唯讀整合測試：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\backend\Test-MsiBatteryApi.ps1 -IncludeLiveReadOnly -Json
```

`-IncludeLiveReadOnly` 只讀狀態與三個 Plan，禁止 live `Set_Data`，並檢查上限前後一致。
JSON bridge 提供 `BatteryStatus`、`BatteryPlan -ChargeLimitPercent 60|80|100`、
`BatterySet -ChargeLimitPercent 60|80|100 -ConfirmBatteryChange`。只查詢的範例：

```powershell
.\backend\Invoke-FuckMsiCenter.ps1 -Command BatteryStatus -Json
.\backend\Invoke-FuckMsiCenter.ps1 -Command BatteryPlan -ChargeLimitPercent 80 -Json
```


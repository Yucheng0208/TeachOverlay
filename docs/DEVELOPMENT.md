# 開發說明

給想自己編譯或修改 TeachOverlay 的人。一般使用者請看 [README](../README.md)。

## 環境

- Apple Silicon Mac、macOS 13 以上
- Xcode 或 Command Line Tools（Swift 5.9 以上）
- 純 Swift：AppKit、SwiftUI、Core Animation、ScreenCaptureKit，沒有第三方套件

> 只有 Command Line Tools 時沒有 SwiftUI 巨集外掛，請不要使用 `@State`，改用 `ObservableObject`。

## 編譯與執行

```bash
./build-app.sh
open build/TeachOverlay.app
```

第一次啟動請到「系統設定 → 隱私權與安全性」開啟「輔助使用」、「輸入監控」與「螢幕錄製」。
用 ad-hoc 簽章時，每次重新編譯後 macOS 會把它當成新 App，可能需要在設定中先移除再重新加入。

## 程式結構

```
Sources/TeachOverlay/
  main.swift                    進入點
  AppDelegate.swift             選單列、App 選單、主控台視窗
  MainView.swift                主控台各頁（SwiftUI）
  ClassroomPanes.swift          計時器、鐘聲、抽籤、放大鏡、黑屏設定頁
  OverlayController.swift       按鍵、滑鼠、聚光燈、畫圖等功能的狀態與邏輯
  OverlayController+Tools.swift 截圖標註、放大鏡、鐘聲橫幅
  OverlayWindow.swift           每個螢幕的透明疊加層、HUD、快捷鍵角落、滑鼠提示
  CanvasView.swift              畫布、白板頁面、尺、圓規、手繪圖形辨識
  DrawToolbar.swift             畫圖／白板浮動工具列
  KeystrokeMonitor.swift        按鍵監聽、注音、隱私與聊天 App 偵測
  ShortcutCombo.swift           組合鍵格式與常見快捷鍵說明
  TimerController.swift         倒數計時、番茄鐘、浮動計時器
  BellSchedule.swift            上下課鐘聲、課表、西敏寺鐘聲合成、通知
  RandomPicker.swift            抽籤、名冊匯入、學號樣式
  Magnifier.swift               放大鏡（ScreenCaptureKit）
  Blackout.swift                黑屏
  FullScreenClock.swift         全螢幕時鐘
  SpeakerTimer.swift            演講計時（燈號、多段提醒、講者名單）
  NotesStore.swift              筆記與浮動筆記
  HotKeys.swift                 全域快捷鍵
  Permissions.swift             權限
  FontAwesome.swift             Font Awesome 圖示、專案連結、作者資訊
  Localization.swift            語言切換（L() / LF()）
  Strings.swift                 翻譯表（鍵＝繁中；值＝簡中、英、日、韓）
Resources/
  Info.plist
  AppIcon.icns, AppIcon.png     由 tools/make-icon.swift 產生
  Fonts/                        Font Awesome Free 字型與授權
  Logo/                         原始 Logo
tools/make-icon.swift           Logo 轉 App 圖示
```

## 新增介面文字

1. 程式中用 `L("繁體中文")`，有變數時用 `LF("共 %d 人", n)`。
2. 在 `Strings.swift` 補上一行：`"繁體中文": ["简体中文", "English", "日本語", "한국어"]`。

## 更換 Logo

```bash
swift tools/make-icon.swift Resources/Logo/logo-source.png Resources
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset
```

背景會自動以四個角落的顏色判斷並去除；若裁切不準，可在最後加上門檻值（預設 60），例如 `... Resources 40`。

## 發佈新版本

```bash
./release.sh 1.1.0
```

會更新版本號、乾淨編譯，並在 `dist/v1.1.0/` 產生 DMG、ZIP 與 SHA256SUMS.txt。發佈說明放在 `docs/release-notes/`。
有 Apple Developer 帳號時，設定 `SIGN_IDENTITY` 與 `NOTARY_PROFILE` 即可自動簽章並公證。

## 已知限制

- 注音的中文字從輸入框讀取，終端機與部分網頁編輯器讀不到時只顯示注音；倚天鍵盤配置暫不支援。
- 瀏覽器中的聊天網站以視窗標題判斷，標題沒有關鍵字時無法辨識。
- 放大鏡會排除 TeachOverlay 自己的視窗，所以放大的畫面裡看不到螢幕上的標註。
- 鏡像輸出時無法只黑掉投影。
- 插拔外接螢幕時，標註與白板內容會重置。

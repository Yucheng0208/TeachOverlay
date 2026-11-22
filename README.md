# TeachOverlay — macOS 教學螢幕助手（Apple Silicon）

專案頁面：https://github.com/Yucheng0208/TeachOverlay

純 Swift（AppKit + SwiftUI + Core Animation），macOS 13 以上，編譯為 arm64 原生版本。
有主控台視窗（所有設定都可在介面調整、自動儲存）＋選單列圖示，圖示全部使用 Font Awesome Free 6.7.2。

## 功能

| 功能 | 快捷鍵 | 說明 |
|---|---|---|
| 放大顯示按鍵 | ⌃⌥K | 打字內容與組合鍵，位置（上/下）、大小、停留時間可調 |
| 注音顯示 | 自動 | 先顯示注音符號，選字後換成中文（內建注音標準鍵盤、小麥注音） |
| 組合鍵說明 | 自動 | 顯示成「Command + C  複製」（也可改成 ⌘C），常見快捷鍵附功能說明 |
| 快捷鍵懸停保留 | 自動 | 組合鍵堆疊在左上或右上角，保留時間可調或一直保留 |
| 隱私欄位隱藏 | 自動 | 密碼、帳號、學號等欄位只顯示「已隱藏」（關鍵字可在介面編輯） |
| 雙擊脈衝 | ⌃⌥C | 顏色（預設色票＋自訂）、大小、速度、圈數、粗細皆可調 |
| 滑鼠按鍵／長按 | 自動 | 游標旁顯示左鍵／右鍵／中鍵；長按顯示「長按」與持續圓圈 |
| 筆記 | — | 主控台內寫筆記（自動儲存、搜尋），可浮動顯示在畫面最上層 |
| 多語言 | — | 繁中、簡中、English、日本語、한국어，預設跟隨系統，App 內即時切換 |
| 使用說明 | — | App 內「使用說明」頁：快速開始、功能介紹、常見問題、GitHub 連結（選單「說明」也可開啟） |
| 明亮／暗黑模式 | — | App 外觀可選跟隨系統／淺色／深色；螢幕提示配色可跟隨外觀或固定深淺 |
| 聚光燈 | ⌃⌥S | 周圍變暗、游標處亮圈；⌃⌥↑/↓ 調整大小 |
| 畫圖標註 | ⌃⌥D | 直接在螢幕上畫，Esc 離開並清除 |
| 白板 | ⌃⌥W | 全螢幕白板，多頁、四種背景，⌘S 存 PNG 到桌面；離開後頁面保留 |
| 關閉全部效果 | ⌃⌥X | 關掉聚光燈、畫圖、白板，清除快捷鍵紀錄（聚光燈也可按 Esc 關閉） |

畫圖與白板模式下，螢幕上方有可點選的工具列。

### 畫圖 / 白板模式按鍵

`P` 畫筆 · `H` 螢光筆 · `L` 直線 · `A` 箭頭 · `R` 方框 · `O` 圓形（按住 Shift 拉正方/正圓/水平垂直）
`1–6` 紅藍綠黃黑白 · `-` / `=` 粗細 · `⌘Z` 復原 · `C` 清除 · `W` 切換白板 · `Esc` 離開
白板專用：`B` 換背景（白/方格/深色/黑板綠）· `N` 新頁 · `←/→` 換頁 · `⌘S` 存成 PNG

## 編譯與執行

```bash
./build-app.sh
open build/TeachOverlay.app
```

第一次啟動到「系統設定 → 隱私權與安全性」開啟：
- **輔助使用**（點擊監聽、密碼欄位偵測）
- **輸入監控**（讀取按鍵）

> 用 ad-hoc 簽章時，每次重新編譯後 macOS 會把它當成新 App，可能需要在上述設定中移除再重新加入。
> 正式發佈請設定 `SIGN_IDENTITY` 用 Developer ID 簽章並公證（notarize）。無法上 Mac App Store（輔助使用 API 不能在 Sandbox 中使用）。

## 已知限制

- 注音的中文字是從輸入框讀取（輔助使用 API）；終端機或部分網頁編輯器讀不到時只顯示注音。倚天鍵盤配置暫不支援。
- 聚光燈開啟期間 Esc 會被用來關閉聚光燈。
- 終端機 `sudo` 密碼無法自動偵測 → 預設在終端機中隱藏全部按鍵，可從選單關閉。
- 換螢幕配置（插拔外接螢幕）時，標註與白板內容會重置。

## 程式結構

```
Sources/TeachOverlay/
  main.swift              進入點（選單列 App）
  AppDelegate.swift       選單列選單
  OverlayController.swift 所有功能的狀態與邏輯、快捷鍵
  OverlayWindow.swift     每個螢幕的透明疊加層、聚光燈/脈衝、HUD 泡泡
  CanvasView.swift        畫布（標註 + 白板多頁）
  KeystrokeMonitor.swift  CGEventTap 按鍵監聽 + 密碼偵測
  HotKeys.swift           全域快捷鍵
  Permissions.swift       權限請求
  MainView.swift          主控台視窗（SwiftUI）
  DrawToolbar.swift       畫圖／白板浮動工具列
  FontAwesome.swift       Font Awesome 字型註冊與圖示
  NotesStore.swift        筆記資料與浮動筆記視窗
  Localization.swift      語言切換（L() / LF()）
  ShortcutCombo.swift     組合鍵格式（Command + C / ⌘C）與常見快捷鍵說明
  Strings.swift           翻譯表（鍵＝繁中；值＝簡中、英、日、韓）
Resources/Fonts/          Font Awesome Free 字型與授權（CC BY 4.0 / SIL OFL 1.1）
Resources/Logo/           原始 Logo；AppIcon.icns / AppIcon.png 由下列指令產生
tools/make-icon.swift     swift tools/make-icon.swift Resources/Logo/logo-source.webp Resources
                          然後 iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

## 授權

本專案以 GNU General Public License v3.0 授權，詳見 [LICENSE](LICENSE)。
圖示使用 Font Awesome Free 6.7.2（圖示 CC BY 4.0、字型 SIL OFL 1.1），授權全文見 `Resources/Fonts/FontAwesome-LICENSE.txt`。

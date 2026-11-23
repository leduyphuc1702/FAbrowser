<div align="center">

<img src="docs/icon.png" width="112" alt="FAbrowser icon">

# FAbrowser

**Trình duyệt iOS native, nhanh và riêng tư. Có video nổi, dịch trang ngoại tuyến, phụ đề trực tiếp cho mọi video và chặn quảng cáo mạnh tay.**

Viết bằng Swift + UIKit + WKWebView. Bố cục và luồng thao tác lấy cảm hứng từ Alook Browser.

[![Platform](https://img.shields.io/badge/platform-iOS%2016%2B-black?logo=apple)](#yêu-cầu)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://swift.org)
[![UIKit](https://img.shields.io/badge/UI-UIKit%20%2B%20WKWebView-1677ff)](#kiến-trúc)
[![Translation](https://img.shields.io/badge/dịch-offline%20(iOS%2018)-34c759)](#dịch-trang-ngoại-tuyến)
[![XcodeGen](https://img.shields.io/badge/project-XcodeGen-8e44ad)](https://github.com/yonaskolb/XcodeGen)
[![Languages](https://img.shields.io/badge/giao%20diện-Tiếng%20Việt%20%7C%20English-orange)](#bản-địa-hoá)

[Tính năng](#tính-năng-nổi-bật) · [Ảnh chụp](#ảnh-chụp-màn-hình) · [Bắt đầu](#bắt-đầu) · [Kiến trúc](#kiến-trúc) · [Lộ trình](#lộ-trình)

<br>

<img src="docs/screenshots/home.jpg" width="200" alt="Trang chủ">&nbsp;
<img src="docs/screenshots/player-top.jpg" width="200" alt="Video nổi">&nbsp;
<img src="docs/screenshots/subtitles.jpg" width="200" alt="Phụ đề trực tiếp">&nbsp;
<img src="docs/screenshots/translate.jpg" width="200" alt="Dịch trang">

</div>

---

## Tính năng nổi bật

<table>
<tr>
<td width="50%" valign="top">

### Video nổi
Bấm phát là video trên trang tách ra trình phát riêng. Bạn vẫn lướt web bình thường trong lúc xem.

- Ba chế độ: **ghim trên đầu** (đẩy trang xuống), **cửa sổ mini** kéo thả tự do, và **toàn màn hình ngang** có khoá thao tác, giờ và pin
- Cử chỉ: vuốt ngang để tua, vuốt dọc để chỉnh độ sáng hoặc âm lượng, chạm hai lần ở mép trái/phải để tua 5 giây, nhấn giữ để phát nhanh, chụm hai ngón để đổi tỉ lệ khung
- Hình trong hình (PiP), phát trong nền, nhớ vị trí đang xem, tự thay video khi trang phát video mới
- Chế độ tương thích cho những trang tự chặn trình phát

</td>
<td width="50%" valign="top">

### Phụ đề trực tiếp
Chuyển lời nói trong **bất kỳ video nào** thành phụ đề, rồi dịch ngay trên máy sang ngôn ngữ bạn chọn khi mở app lần đầu.

- Tự nhận diện **Anh, Nhật, Trung** (và Hàn, Thái, Pháp, Đức, Nga…) bằng Speech framework, ưu tiên chạy trên máy
- Hiển thị **chỉ bản dịch**, **song ngữ** hoặc **bản gốc**, chỉnh được cỡ chữ
- Chạy được với file video thường (gắn trực tiếp vào âm thanh của trình phát), với HLS và với video phát ngay trong trang

</td>
</tr>
<tr>
<td valign="top">

### Dịch trang ngoại tuyến
Dịch cả trang bằng **Apple Translation** (iOS 18+). Nội dung không rời khỏi máy, không cần Google.

- Tự phát hiện ngôn ngữ trang và dịch dần theo phần đang hiển thị
- Thanh dịch cho phép xem bản gốc hoặc đổi ngôn ngữ đích. Có tuỳ chọn tự dịch các trang mới
- Quản lý gói ngôn ngữ (Anh, Nhật, Trung giản thể/phồn thể, Hàn…) ngay trong Cài đặt

</td>
<td valign="top">

### Chặn quảng cáo
Chặn quảng cáo bằng `WKContentRuleList` của WebKit kết hợp script chạy trên trang.

- Có sẵn **EasyList + ABPVN** trong app nên chặn được ngay từ lần mở đầu, kể cả khi offline. Bộ lọc tự cập nhật sau mỗi 4 ngày
- Chặn quảng cáo nổi/dính màn hình, cửa sổ bật lên và pop-under, tự bấm **bỏ qua quảng cáo video**, chặn trang tự nhảy sang app khác
- Hỗ trợ đăng ký bộ lọc ABP bất kỳ, danh sách trắng theo trang, và tự đánh dấu phần tử để ẩn

</td>
</tr>
</table>

### Và mọi thứ một trình duyệt cần

| Khu vực | Có gì |
|---|---|
| **Thanh công cụ** | Thanh địa chỉ thu gọn khi cuộn, khiên bảo mật/chặn quảng cáo, chế độ đọc; thanh dưới có Quay lại, Tiến tới, Menu, Tab, Trang chủ, nút nào cũng có thao tác nhấn giữ |
| **Menu** | Lưới 2 trang: dấu trang/lịch sử, tệp, ban đêm, chặn quảng cáo, không tải ảnh, toàn màn hình, bản máy tính, hộp công cụ, riêng tư, dịch, video, tiện ích JS, quét QR… |
| **Hộp công cụ** | 24 công cụ: tìm trong trang, phụ đề trực tiếp, ẩn phần tử, xem mã nguồn, chụp toàn trang, tạo PDF, lưu webarchive, in, tạo QR, lấy toàn bộ văn bản, tự động làm mới, công cụ nhà phát triển (eruda), truyền qua Wi-Fi… |
| **Tab** | Lưới tab có ảnh xem trước, kéo để sắp xếp, tab riêng tư, thanh tab phía trên (iPad), khôi phục phiên |
| **Tìm kiếm** | Gợi ý tìm kiếm, khớp lịch sử và dấu trang, dán link vừa sao chép, phím tắt `https://` `www.` `.com`, đổi công cụ tìm kiếm nhanh |
| **Tệp** | Trình tải xuống (tạm dừng/tiếp tục), thư mục, xem trước QuickLook, nén zip, truyền tệp qua Wi-Fi |
| **Đọc** | Chế độ đọc có 6 chủ đề, chỉnh phông và cỡ chữ, tự nối trang kế tiếp |
| **Riêng tư** | Khoá app bằng Face ID hoặc mật mã, che nội dung trong trình chuyển app, xoá dữ liệu theo loại |
| **Tuỳ biến** | Ban đêm, dark mode cho trang, User Agent, tiện ích kiểu userscript, icon app thay thế, sao lưu và khôi phục, URL scheme `fabrowser://` |

---

## Ảnh chụp màn hình

<div align="center">

| Lần đầu mở | Lướt web | Menu | Hộp công cụ |
|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/onboarding.jpg" width="190"> | <img src="docs/screenshots/browse.jpg" width="190"> | <img src="docs/screenshots/menu.jpg" width="190"> | <img src="docs/screenshots/toolbox.jpg" width="190"> |
| **Video ghim trên đầu** | **Cửa sổ mini** | **Phụ đề song ngữ** | **Dịch trang** |
| <img src="docs/screenshots/player-top.jpg" width="190"> | <img src="docs/screenshots/player-mini.jpg" width="190"> | <img src="docs/screenshots/subtitles.jpg" width="190"> | <img src="docs/screenshots/translate.jpg" width="190"> |
| **Cài đặt** | **Cài đặt phụ đề** | **Tab** | **Giao diện tối** |
| <img src="docs/screenshots/settings.jpg" width="190"> | <img src="docs/screenshots/settings-subtitles.jpg" width="190"> | <img src="docs/screenshots/tabs.jpg" width="190"> | <img src="docs/screenshots/dark.jpg" width="190"> |

<img src="docs/screenshots/player-full.jpg" width="640" alt="Toàn màn hình">

<sub>Trình phát toàn màn hình ngang có khoá thao tác, tốc độ phát, giờ và pin</sub>

</div>

---

## Bắt đầu

### Yêu cầu

| | Phiên bản |
|---|---|
| Xcode | 16 trở lên (đã build với Xcode 27.2) |
| iOS | 16.0+ cho trình duyệt; **18.0+** cho dịch trang và dịch phụ đề |
| Công cụ | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), Python 3 + Pillow nếu cần tạo lại icon |

### Build

```bash
git clone https://github.com/leduyphuc1702/FAbrowser.git
cd FAbrowser
xcodegen generate                 # sinh FAbrowser.xcodeproj từ project.yml
open FAbrowser.xcodeproj
```

Hoặc build bằng dòng lệnh:

```bash
xcodebuild -project FAbrowser.xcodeproj -scheme FAbrowser \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Chạy trên iPhone

Chọn Team trong **Signing & Capabilities**, hoặc điền `DEVELOPMENT_TEAM` vào `project.yml`. Đổi `PRODUCT_BUNDLE_IDENTIFIER` cho khớp với App ID của bạn.

App không dùng capability đặc biệt nào (push, iCloud, App Group), nên ký được bằng mọi profile phát triển hoặc ad-hoc. iOS chỉ hỏi quyền khi cần: nhận dạng giọng nói (phụ đề), camera (quét QR), Face ID (khoá app), thư viện ảnh (lưu ảnh).

> [!NOTE]
> Nếu ký bằng một provisioning profile có **App ID cố định**, iOS xem mọi app dùng chung bundle id đó là cùng một app, nên bản cài sau sẽ **ghi đè** bản cài trước. Muốn nhiều app cùng tồn tại thì mỗi app cần một App ID riêng, hoặc dùng profile wildcard (`TEAMID.*`).

---

## Kiến trúc

```
FAbrowser/
├── App/            AppDelegate, SceneDelegate, DebugLaunch (chỉ bản DEBUG)
├── Browser/        BrowserViewController
│   │                 +Web     điều hướng, UI delegate, cầu nối JS
│   │                 +Actions menu, hộp công cụ, công cụ trang
│   │                 +Media   video nổi, dịch trang, phụ đề
│   └── Views/      URLBar, TabToolbar, TopTabs, FindInPage, ErrorPage…
├── Video/          VideoSniffer (JS dò video), FloatingPlayer, PlayerControlsView
├── Translate/      TranslationService (Apple Translation), PageTranslator (JS + thanh dịch)
├── Subtitles/      LiveSubtitles (Speech + audio tap + ReplayKit, overlay phụ đề)
├── Models/         TabManager, AdBlocker + ABPConverter, ScriptManager, Bookmark/History/Search stores
├── Settings/       Settings (khai báo bằng SettingRow), Onboarding, Extensions
├── Home/ Search/ Tabs/ Library/ Menu/ Files/ Tools/
├── Support/        Prefs (@Pref), Theme, L() localization, JSONStore, Toast
└── Resources/      en.lproj, vi.lproj, Filters/ (EasyList, ABPVN)
```

### Luồng phụ đề trực tiếp

```mermaid
flowchart LR
    A[Video file<br/>AVPlayerItem] -->|MTAudioProcessingTap| C
    B[HLS / video trong trang] -->|ReplayKit app audio| C
    C[Bộ đệm âm thanh] --> D{Speech<br/>en · ja · zh chạy song song}
    D -->|chọn kênh tin cậy nhất| E[Câu gốc]
    E --> F[Apple Translation<br/>on-device]
    F --> G[Overlay<br/>bản dịch / song ngữ]
    E --> G
```

### Luồng chặn quảng cáo

```mermaid
flowchart LR
    L[EasyList · ABPVN · bộ lọc đăng ký] --> P[ABPConverter]
    P --> R[(WKContentRuleList<br/>đã biên dịch, lưu cache)]
    R -->|chặn mạng + ẩn CSS| W[WKWebView]
    S[Script trên trang] -->|popup · quảng cáo nổi · bỏ qua quảng cáo video| W
    W -->|decidePolicyFor| J[Chặn tự nhảy app]
```

### Quy ước khi phát triển

- **Cài đặt**: thêm một `@Pref` vào `Prefs`. Mỗi lần ghi sẽ phát `.prefsChanged` (object là key), rồi `BrowserViewController.prefsChanged` phản ứng theo key. Thêm một dòng cài đặt chỉ cần một `SettingRow` trong `SettingsViewController`.
- **Script trên trang**: các tính năng chạy trong trang dùng chung `window.__fa.*` (`ScriptManager`). Trang gửi dữ liệu về app qua message handler `fa`.
- **Menu và hộp công cụ**: mỗi mục là một `GridItem(title:symbol:isOn:enabled:badge:action:longPress:)`.
- **Dữ liệu**: lưu JSON trong Application Support qua `JSONStore`.

### Bản địa hoá

Chuỗi giao diện viết bằng `L("English key")`. Sau khi thêm chuỗi mới:

```bash
python3 scripts/l10n.py     # sinh en/vi Localizable.strings, báo các key còn thiếu bản dịch tiếng Việt
python3 scripts/make_icons.py  # tạo lại AppIcon và icon thay thế (cần Pillow)
```

### Chụp màn hình tự động (bản DEBUG)

Không cần chạm vào Simulator. Truyền tham số khi khởi chạy:

```bash
xcrun simctl launch booted com.fabrowser.app -FASkipOnboarding YES -FAScreen menu
xcrun simctl launch booted com.fabrowser.app -FAOpenURL https://example.com -FAScreen toolbox
xcrun simctl launch booted com.fabrowser.app -FAPlayURL https://…/video.mp4 -FAScreen player.subtitles
xcrun simctl launch booted com.fabrowser.app -FAFakeTranslate YES -FAScreen translate   # giả lập dịch trên Simulator
```

`-FAScreen` nhận: `menu` `toolbox` `tabs` `search` `library` `files` `settings` `settings.<trang>` `reader` `onboarding` `player.mini` `player.full` `subtitles` `translate`…

---

## Lộ trình

- [x] Video nổi: ghim trên đầu, cửa sổ mini, toàn màn hình, PiP
- [x] Dịch trang ngoại tuyến bằng Apple Translation
- [x] Phụ đề trực tiếp + dịch phụ đề (Anh/Nhật/Trung → Việt)
- [x] Chặn quảng cáo: EasyList/ABPVN có sẵn, popup, quảng cáo video, chặn tự nhảy app
- [ ] Tải video HLS/m3u8
- [ ] Đồng bộ iCloud dấu trang và tab
- [ ] Trình quản lý mật khẩu và tự điền
- [ ] Giải nén zip/rar
- [ ] Cử chỉ vuốt tuỳ biến, nhiều cửa sổ trên iPad

### Giới hạn đã biết

- Dịch trang và dịch phụ đề cần iOS 18. Gói ngôn ngữ được tải khi dùng lần đầu. Trên Simulator, Apple Translation có thể báo cặp ngôn ngữ không hỗ trợ.
- Phụ đề cho HLS/video trong trang dùng ReplayKit, nên iOS sẽ hỏi quyền ghi màn hình.
- ABPConverter hỗ trợ quy tắc mạng (`||domain^`, `$third-party`, `$domain=`, `@@`), hosts file và quy tắc ẩn `##`. Quy tắc nâng cao (`#?#`, `#$#`, scriptlet) sẽ bị bỏ qua.

---

## Ghi công

- [EasyList](https://easylist.to) (GPLv3 / CC BY-SA 3.0) và [ABPVN](https://github.com/abpvn/abpvn) là các bộ lọc quảng cáo đi kèm app
- [eruda](https://github.com/liriliri/eruda) cho công cụ nhà phát triển, tải theo yêu cầu
- Biểu tượng giao diện dùng [SF Symbols](https://developer.apple.com/sf-symbols/)

FAbrowser là dự án độc lập, viết mới hoàn toàn: không dùng mã nguồn hay tài nguyên của Alook Browser, và không liên kết với nhà phát triển Alook.

<div align="center">
<sub>Làm bằng Swift tại Việt Nam</sub>
</div>

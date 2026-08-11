# QuickDict

**Công cụ tra từ trên macOS dành cho người học tiếng Hàn.** Lấy bất kỳ đoạn tiếng Hàn nào trên màn hình
— giáo trình scan, PDF, phụ đề video, trang web, ảnh chụp ai đó gửi — và có ngay mục từ điển.
Mọi việc nhận dạng đều chạy trên máy Mac của bạn — không gửi số liệu, không lưu lịch sử. Việc tra có cần
mạng hay không tuỳ vào từ điển bạn chọn: cơ sở dữ liệu ngoại tuyến kèm sẵn và ghi chú của bạn thì không,
từ điển web thì tất nhiên có.

Ngôn ngữ: [English](README.md) · [中文](README.zh-CN.md) · [Русский](README.ru.md) · **Tiếng Việt** ·
[日本語](README.ja.md) · [한국어](README.ko.md)

---

## Khác biệt ở đâu

Đọc chữ từ màn hình thì công cụ nào cũng làm được. Cái này **nối lại những từ tiếng Hàn bị ngắt dòng**.

Khi nhận dạng một đoạn có xuống dòng, từ ở cuối dòng bị cắt làm đôi. `이성적인` (*lý trí*) thành
`이` + `성적인`, nối một cách ngây thơ sẽ ra `이 성적인` — nghĩa khác hẳn. Khoảng trắng từng ngăn cách
chúng đã bị việc ngắt dòng nuốt mất; **trong các điểm ảnh nó không tồn tại.**

Ba hướng đi đều thất bại:

| Thử | Kết quả |
|---|---|
| Bộ kiểm tra chính tả tiếng Hàn của hệ thống | ✗ Chấp nhận mọi chuỗi âm tiết hangul hợp lệ |
| Bộ tách từ tiếng Hàn trong NaturalLanguage | ✗ Chỉ tách theo khoảng trắng, không phân tích hình vị |
| Chỉ dựa vào hình học (dòng có sát mép phải không?) | △ Phân biệt được ngắt dòng với hết đoạn, nhưng không phân biệt được ngắt giữa từ với ngắt ở khoảng trắng |

Giải pháp dùng được kết hợp ba tín hiệu:

1. **Từ điển tiếng Hàn của hệ thống** (`DCSCopyTextDefinition`) — nối hai nửa lại và xem tiền tố dài
   nhất có trong từ điển **có vượt qua chỗ nối hay không**. `이` + `성적인` → `이성적` có trong từ điển,
   dài 3 âm tiết, lớn hơn 1 âm tiết trước chỗ nối → từ đã bị cắt.
2. **Hình học của dòng** — khung bao từng dòng do Vision cung cấp cho biết dòng bị cắt hay tự kết thúc.
3. **Bảng tiểu từ và đuôi từ tiếng Hàn** — một `은` / `는` / `로서` / `하며` / `진다고` lơ lửng ở đầu dòng
   chỉ có thể là phần đuôi của từ ở dòng trước.

Chữ Latinh đi hướng khác: bộ kiểm tra chính tả tiếng Anh là từ điển thật, nên `jum` + `ps` = `jumps`
được quyết định bằng tra cứu chứ không phải phỏng đoán.

**28 bài kiểm thử tích hợp nằm trong kho mã**, tất cả đều đạt.

Bảng đuôi từ **có thể bổ sung ngay trong tệp cấu hình** — thấy thiếu gì thì tự sửa, không cần đụng vào
mã nguồn cũng không phải chờ bản mới:

```jsonc
"koreanExtraParticles":  ["로부터", "에서부터"],
"koreanExtraStandalone": ["뭐"]
```

Phần bạn thêm được *hợp nhất* với bảng dựng sẵn chứ không thay thế nó, nên các bản cập nhật vẫn có tác dụng.

### Khi không thể biết chắc, chương trình sẽ nói ra

`이성적인` (*lý trí*) và `이 성적인` (*cái ~ này*) **đều là tiếng Hàn hợp lệ**. Khi chỗ ngắt dòng rơi
đúng vào giữa, không tín hiệu cục bộ nào phân biệt được: chỉ ngữ cảnh mới quyết định được, mà điều đó
cần đến mô hình ngôn ngữ. Vì vậy QuickDict mặc định nối lại (trường hợp này phổ biến hơn nhiều) nhưng
**báo lại những chỗ nó phải tự quyết**:

```
Đã chép 87 ký tự
⚠️ Chỗ này đã nối lại, nhưng viết tách ra cũng hợp lý:
이성적인
```

Thường chỉ 0–1 chỗ mỗi đoạn, nên đây là gợi ý chứ không phải nhiễu.

---

## Cách dùng

| Phím tắt | Lấy chữ từ | Hành động |
|---|---|---|
| `⌃⌥9` | Ảnh chụp màn hình + nhận dạng | Tra từ, tự nhận dạng ngôn ngữ |
| `⌃⌥0` | Ảnh chụp màn hình + nhận dạng | **Nối dòng rồi chép vào bảng nháp**, không tra (chạy được khi không có mạng) |
| `⌃⌥8` | Ảnh chụp màn hình | **Đọc mã QR hoặc mã vạch**, nếu là liên kết thì mở bằng trình duyệt |
| `⌘⌥D` | Chữ đang chọn | Tra từ, tự nhận dạng ngôn ngữ |
| `⌘⌥N` | Chữ đang chọn | Vào thẳng Naver (theo ngôn ngữ của bạn) |
| `⌘⌥K` | Chữ đang chọn | Vào thẳng 국어사전 (Hàn – Hàn) |
| `⌘⌥P` | Chữ đang chọn | Vào thẳng Papago |
| `⌘⌥G` | Chữ đang chọn | Vào thẳng Google Translate |

**Chế độ ảnh chụp** dành cho chữ không chọn được: hình ảnh, PDF quét, phụ đề video.
**Chế độ chọn** dành cho chữ chọn được: không có lỗi nhận dạng và nhanh hơn.

Các phím dẫn thẳng tới từng từ điển được tạo ra **từ chính những từ điển mà ngôn ngữ của bạn có**,
nên không bao giờ có phím tắt vô tác dụng.

| Ngoài ra | |
|---|---|
| `⌘1`…`⌘9` | Đổi từ điển trong cửa sổ kết quả |
| `⌘L` | Sửa từ nhận dạng sai, Enter để tra lại |
| `esc` / `⌘W` | Đóng cửa sổ |
| Nút la bàn | Gửi truy vấn sang trình duyệt mặc định |
| Nút ghim | Giữ cửa sổ luôn ở trên |

**Không nhớ phím tắt thì nhấn `⌘?`**: hướng dẫn tích hợp được tạo ra từ cấu hình hiện tại của bạn,
nên nó không thể lạc hậu.

---

## Kèm từ điển ngoại tuyến

Ứng dụng mang theo từ điển Hàn–Trung của Viện Quốc ngữ Hàn Quốc (56.555 mục, CC BY-SA 2.0 KR).
Đây là **bản dự phòng**: khi có mạng vẫn dùng Naver, cơ sở dữ liệu cục bộ **chỉ thay thế khi mất mạng**.

Từ điển chỉ chứa dạng nguyên thể, còn thứ OCR nhận được luôn là dạng chia (갔어요, 몰랐어), nên trước
khi tra, dạng gốc được khôi phục từ cấu trúc âm tiết Hangul (bất quy tắc ㅂ/ㄷ/ㅅ/ㄹ/르/ㅎ và rút gọn
nguyên âm, 30 bài kiểm thử hồi quy).

> Giấy phép và các thay đổi: [KRDICT-NOTICE.md](Resources/KRDICT-NOTICE.md).

---

## Cài đặt

Cần **macOS 13 trở lên**. Bản nhị phân đa kiến trúc — chạy trên cả Apple Silicon và Intel.

```bash
git clone https://github.com/lpoterus-commits/quickdict.git && cd quickdict
./build.sh install
```

Chỉ cần Command Line Tools, không cần cài Xcode đầy đủ. Biên dịch mất khoảng một phút.

> Ứng dụng được cài với tên **QuickDict 3.app** để chạy song song với bản 2 cũ.
> Đổi `APP_NAME` trong `build.sh` nếu bạn muốn tên `QuickDict`.

### Nếu không mở được

Với tệp `.zip` đã tải về, macOS chặn những ứng dụng chưa được Apple công chứng. Bạn sẽ thấy
*«QuickDict 3 bị hỏng và không thể mở»*. **Ứng dụng không hỏng** — macOS đánh dấu mọi thứ đến từ internet.
Công chứng tốn 99 đô mỗi năm, và dự án này không chi khoản đó.

Ba cách xử lý:

**1. Tự biên dịch** (câu lệnh ở trên). Tệp bạn tự biên dịch không bao giờ bị đánh dấu. Cách sạch nhất.

**2. Tải về rồi chạy một câu lệnh.** Dán vào Terminal một lần, sau đó mở như bình thường:

```bash
xattr -dr com.apple.quarantine "/Applications/QuickDict 3.app"
```

Chỉ cần một lần — dấu đó không quay lại nữa. Việc gỡ nó không sửa đổi hay làm yếu ứng dụng:
chữ ký mã vẫn hợp lệ, mọi tính năng chạy y hệt như khi bạn tự biên dịch.

**3. Nhờ ai đó đưa trực tiếp cho bạn.** Dấu này do trình duyệt, email và AirDrop gắn vào. Bản sao từ USB
hay ổ cứng ngoài hoàn toàn không có dấu, nhấp đúp là mở — không cần Terminal.

### Quyền

Cả hai đều nằm trong **Cài đặt hệ thống → Quyền riêng tư và bảo mật**. **Cấp xong phải khởi động lại
ứng dụng** — macOS chỉ áp dụng quyền cho tiến trình mới. Trợ lý thiết lập sẽ dẫn bạn qua cả hai và
hiển thị trạng thái theo thời gian thực.

| Quyền | Để làm gì | Nếu không cấp |
|---|---|---|
| Ghi màn hình | Kéo khoanh vùng để chụp | Mọi thao tác chụp màn hình đều không chạy |
| Trợ năng | Đọc chữ bạn chọn trong ứng dụng khác | Mọi thao tác với phần đang chọn đều không chạy |

---

## Ngôn ngữ tra nghĩa

Được chọn theo ngôn ngữ hệ thống ở lần chạy đầu; đổi lúc nào cũng được qua thanh menu
(**Tra nghĩa sang**).

| | Từ điển Naver | Trình dịch |
|---|---|---|
| English | `en.dict.naver.com` | `en` |
| 中文 | `zh.dict.naver.com` | `zh-CN` |
| 日本語 | `ja.dict.naver.com` | `ja` |
| 한국어 | `ko.dict.naver.com` | `ko` |
| Русский | `dict.naver.com/rukodict` | `ru` |
| Tiếng Việt | `dict.naver.com/vikodict` | `vi` |
| Italiano | `dict.naver.com/itkodict` | `it` |

Từ điển Naver là **hai chiều**: `사랑` → `tình yêu` và `tình yêu` → `사랑` đều tra trong cùng một từ điển.
Đọc tiếng Hàn thì xem nghĩa; viết tiếng Hàn thì tra ngược xem nói thế nào.

### Tự thêm từ điển

Các bộ mặc định lo việc «tra tiếng Hàn sang ngôn ngữ của bạn». Muốn thêm thứ khác — từ điển chuyên ngành,
cặp ngôn ngữ khác, một trang bạn hay dùng — mở **Sửa tệp cấu hình** từ thanh menu rồi thêm một mục vào
`dictionaries`:

```jsonc
{
  "id": "yihan",                              // tên duy nhất, đặt tuỳ ý
  "name": "Ý - Trung",                        // chữ hiện trên nút
  "languages": ["it"],                        // tự mở khi gặp tiếng Ý
  "url": "https://www.yihan.it/{q}"           // {q} là chỗ đặt từ cần tra
}
```

Rồi bấm **Nạp lại cấu hình**. Các trường tuỳ chọn:

| Trường | Ý nghĩa |
|---|---|
| `languages` | Nhận ra ngôn ngữ nào thì tự mở. `"*"` là dự phòng, `[]` là chỉ mở thủ công |
| `suffix` | Nối vào sau từ khoá **trước khi** mã hoá URL — tiện cho công cụ tìm kiếm và câu hỏi cho AI |
| `external` | `true` thì mở bằng trình duyệt mặc định thay vì cửa sổ tích hợp (cho trang cần đăng nhập) |

**Mục bạn thêm được giữ lại trong mọi thao tác** — đổi tiếng mẹ đẻ, tích thêm ngôn ngữ nguồn, đều không
đụng tới thứ bạn đã thêm.

Có hai trục quyết định cái gì sẽ mở ra:

- **Tra nghĩa sang** — một ngôn ngữ, nơi nghĩa hiện ra. Thanh menu → *Tra nghĩa sang*.
- **Tra thêm** — bạn gặp những ngoại ngữ nào. Thanh menu → *Tra thêm*, tích bao nhiêu tuỳ ý.

Tiếng Hàn vào từ điển song ngữ Naver; mỗi ngôn ngữ khác bạn tích sẽ có một mục Glosbe
(`glosbe.com/<từ>/<sang>/<chữ>`), vốn có gần như mọi cặp. Chọn một từ tiếng Ý thì mở từ điển Ý,
chọn tiếng Hàn thì mở Naver. Không phải chuyển thủ công.

**Bất kỳ mục nào bạn thêm mà nhận một ngôn ngữ sẽ thay thế mục mặc định của ngôn ngữ đó.**

### Dùng phần mềm từ điển thay cho trang web

Nếu máy có phần mềm từ điển, việc tra có thể mở thẳng nó thay vì trang web. Thanh menu →
**Từ điển cài trên máy** liệt kê những phần mềm **thực sự đã cài**; chưa cài thì không hiện.

Được như vậy vì các phần mềm đó đăng ký URL scheme riêng, còn mục nào đánh dấu `external` sẽ được giao
cho hệ thống chứ không tải trong cửa sổ tích hợp:

```jsonc
{ "id": "local-eudic", "name": "Eudic", "languages": ["en"],
  "url": "eudic://dict/{q}", "external": true }
```

Tích vào thì mục đó **chỉ mở thủ công** — phần mềm từ điển thường biết nhiều ngôn ngữ, chọn ngôn ngữ nào
giao cho nó là quyết định của bạn. Ghi `languages` cho nó thì nó sẽ tự nhận ngôn ngữ đó.

Tệp cấu hình: `~/Library/Application Support/com.quickdict.app/config.json`

Cách thêm ngôn ngữ vào bộ mặc định và cấu trúc mã nguồn: xem [README tiếng Anh](README.md).

## Giấy phép

MIT

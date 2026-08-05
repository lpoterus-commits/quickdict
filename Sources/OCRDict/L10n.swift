import Foundation

/// 界面文案跟随系统语言。
///
/// 走标准的 `NSLocalizedString` + `.lproj`，macOS 会按系统语言偏好自动挑。
/// 想加一种语言只要在 `Resources/` 下新建 `<code>.lproj/Localizable.strings`，
/// 不用改任何代码 —— build.sh 会把所有 .lproj 目录拷进 App 包。
///
/// 基准语言是英语（`en.lproj`），找不到对应翻译时回落到它。
func t(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func t(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

/// 当前界面语言是不是中文 —— 只有需要整段切换的地方（比如内嵌说明书的 HTML）才用得上
var uiIsChinese: Bool {
    guard let code = Bundle.main.preferredLocalizations.first else { return false }
    return code.hasPrefix("zh")
}

/// 版本号，取自 Info.plist。用 swift run 直接跑（没有 bundle）时回落到 "dev"
var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

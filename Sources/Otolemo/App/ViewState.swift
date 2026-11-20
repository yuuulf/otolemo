import SwiftUI

/// SwiftUI の `@State` プロパティラッパー。
///
/// macOS 27 SDK では `@State` が SwiftUIMacros のマクロとしても宣言されており、
/// Command Line Tools にはそのマクロプラグインが含まれないため `@State` と書くとビルドできない。
/// 別名を通すとプロパティラッパーとして解決されるので、Xcode が無い環境でもビルドできるようにこれを使う。
typealias ViewState<Value> = SwiftUI.State<Value>

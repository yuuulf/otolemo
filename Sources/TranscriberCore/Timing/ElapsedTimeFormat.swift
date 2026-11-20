/// 会議経過時間を `HH:MM:SS` で表す。
public enum ElapsedTimeFormat {
    public static func string(milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return "\(pad(hours)):\(pad(minutes)):\(pad(seconds))"
    }

    public static func string(duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return string(milliseconds: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    private static func pad(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

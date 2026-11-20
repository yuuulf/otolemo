import AppKit
import CoreAudio
import Darwin
import TranscriberCore

/// 相手側の音声の取得対象にできるアプリの一覧を作る。
enum AudioProcessList {
    @MainActor
    static func targets() -> [AudioTargetApp] {
        let processes = ((try? AudioHardwareSystem.shared.processes) ?? []).compactMap { process -> AudioProcessInfo? in
            guard let pid = try? process.pid else { return nil }
            return AudioProcessInfo(
                objectID: process.id,
                pid: pid,
                bundleID: (try? process.bundleID).flatMap { $0.isEmpty ? nil : $0 },
                isRunningOutput: (try? process.isRunningOutput) ?? false,
                ancestorPIDs: ancestors(of: pid)
            )
        }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "PID \($0.processIdentifier)") }
        return AudioTargetGrouping.targets(processes: processes, runningApps: apps, excludingPID: getpid())
    }

    /// 親プロセスを launchd の手前までたどる。
    static func ancestors(of pid: pid_t) -> [Int32] {
        var result: [Int32] = []
        var current = pid
        for _ in 0..<8 {
            guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

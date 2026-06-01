import ScreenCaptureKit
import CoreGraphics
import AppKit
import Foundation

// Kết nối WindowServer cho tiến trình CLI (tránh CGS_REQUIRE_INIT).
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

func savePNG(_ cg: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    if let d = rep.representation(using: .png, properties: [:]) {
        try? d.write(to: URL(fileURLWithPath: path))
    }
}

func rgba(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: w*h*4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

func diffPixels(_ a: CGImage, _ b: CGImage) -> (diff: Int, total: Int) {
    let w = min(a.width, b.width), h = min(a.height, b.height)
    guard let ba = rgba(a, w, h), let bb = rgba(b, w, h) else { return (-1, 0) }
    var diff = 0, i = 0
    while i < ba.count {
        let d = abs(Int(ba[i])-Int(bb[i])) + abs(Int(ba[i+1])-Int(bb[i+1])) + abs(Int(ba[i+2])-Int(bb[i+2]))
        if d > 40 { diff += 1 }
        i += 4
    }
    return (diff, w*h)
}

func run() async {
    do {
        let content = try await SCShareableContent.current
        let myPid = ProcessInfo.processInfo.processIdentifier
        let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : nil
        let sysBundles: Set<String> = ["com.apple.WindowManager", "com.apple.dock",
            "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.wallpaper.agent"]
        var cands = content.windows.filter { w in
            guard w.isOnScreen, w.windowLayer == 0, w.frame.width > 200, w.frame.height > 200,
                  let app = w.owningApplication, app.processID != myPid,
                  !app.applicationName.isEmpty, !sysBundles.contains(app.bundleIdentifier)
            else { return false }
            return true
        }
        if let want = want {
            cands = cands.filter {
                ($0.title?.lowercased().contains(want) ?? false)
                || ($0.owningApplication?.applicationName.lowercased().contains(want) ?? false)
            }
        }
        print("Cửa sổ app on-screen tìm thấy:")
        for w in cands.prefix(8) { print("  - \"\(w.title ?? "")\" [\(w.owningApplication?.applicationName ?? "")] \(Int(w.frame.width))x\(Int(w.frame.height))") }
        guard let win = cands.max(by: { $0.frame.width*$0.frame.height < $1.frame.width*$1.frame.height }) else {
            print("Không tìm thấy cửa sổ app phù hợp. (Mở 1 app như TextEdit/Finder/Safari, hoặc truyền tên: /tmp/cursorstrip safari)"); exit(1)
        }
        print("Target: \"\(win.title ?? "")\" [\(win.owningApplication?.applicationName ?? "")] \(Int(win.frame.width))x\(Int(win.frame.height)) @\(Int(win.frame.minX)),\(Int(win.frame.minY))")
        let filter = SCContentFilter(desktopIndependentWindow: win)

        func cap(_ showsCursor: Bool) async throws -> CGImage {
            let cfg = SCStreamConfiguration()
            cfg.showsCursor = showsCursor
            cfg.width = Int(win.frame.width)
            cfg.height = Int(win.frame.height)
            CGWarpMouseCursorPosition(CGPoint(x: win.frame.midX, y: win.frame.midY)) // đặt con trỏ giữa cửa sổ
            try await Task.sleep(nanoseconds: 400_000_000)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }

        print("Chụp showsCursor=TRUE (con trỏ ở giữa cửa sổ)..."); let t = try await cap(true);  savePNG(t, "/tmp/cursor_true.png")
        print("Chụp showsCursor=FALSE..."); let f = try await cap(false); savePNG(f, "/tmp/cursor_false.png")

        let (d, total) = diffPixels(t, f)
        print(String(format: "\ndiff(true vs false) = %d pixels (%.4f%% của %d)", d, Double(d)/Double(max(total,1))*100, total))
        if d > 20 {
            print("=> PASS (auto): true có con trỏ, false KHÔNG → showsCursor=false strip sạch cursor khỏi per-window capture.")
        } else {
            print("=> AUTO INCONCLUSIVE (diff nhỏ — cửa sổ tĩnh & cả 2 giống nhau).")
        }
        print("\n** KIỂM TRA DỨT ĐIỂM: mở 2 ảnh, nhìn cursor_false.png — nếu KHÔNG thấy con trỏ chuột => strip OK **")
        print("   open /tmp/cursor_true.png /tmp/cursor_false.png")
    } catch {
        print("ERROR: \(error)")
        print(">> Nếu lỗi quyền: System Settings > Privacy & Security > Screen Recording > bật cho Terminal, rồi chạy lại.")
        exit(1)
    }
}

let sem = DispatchSemaphore(value: 0)
Task { await run(); sem.signal() }
sem.wait()

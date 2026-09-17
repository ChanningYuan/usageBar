// 发版截图核对用的点击小工具（2026-09-17）：往屏幕某个坐标发一次鼠标左键点击。
//
// 编译：swiftc -O app/Scripts/ui-click.swift -o <临时目录>/ui-click
// 用法：ui-click <x> <y>     坐标单位是「点」，屏幕左上角为原点（Retina 截图里 1 像素 = 0.5 点）
//      ui-click --bounds     打印主屏尺寸（点）
//
// 为什么不用 computer use 或 AppleScript：
// - computer use 工具按名字、按应用标识都匹配不到 usageBar（只在菜单栏显示、程序坞没有图标），授权弹窗弹不出，也截不到它的界面；
// - AppleScript 让「系统事件」代点，要单独的「自动化」权限，没开时报 -1743；
// - 这里直接发鼠标事件，只需要终端有「辅助功能」权限。截图用系统自带 `screencapture -x -R x,y,宽,高`（单位同样是点）。
import CoreGraphics
import Foundation

let args = CommandLine.arguments
if args.count > 1 && args[1] == "--bounds" {
    let b = CGDisplayBounds(CGMainDisplayID())
    print("主屏 \(Int(b.width))x\(Int(b.height)) 点")
    exit(0)
}
guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
    print("用法: ui-click <x> <y> | ui-click --bounds")
    exit(2)
}
guard CGPreflightPostEventAccess() else {
    print("没有发送模拟点击的权限：系统设置 → 隐私与安全性 → 辅助功能，给当前终端打开后重启终端")
    exit(1)
}
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(70_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
print("已点击 (\(Int(x)), \(Int(y)))")

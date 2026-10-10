import Foundation
import CoreGraphics

public enum LogPreviewPlacement {
    public enum Side { case left, right }
    public static func side(menu: CGRect, screen: CGRect, width: CGFloat) -> Side {
        let right = screen.maxX - menu.maxX
        let left = menu.minX - screen.minX
        return right >= width + 18 || right >= left ? .right : .left
    }

    public static func frame(row: CGRect, menu: CGRect, screen: CGRect, size: CGSize, side: Side) -> CGRect {
        let available = screen.insetBy(dx: 8, dy: 8)
        let space = side == .right ? available.maxX - menu.maxX - 10 : menu.minX - available.minX - 10
        let width = min(size.width, max(1, space))
        let height = min(size.height, available.height)
        let x = side == .right ? menu.maxX + 10 : menu.minX - 10 - width
        let y = min(max(row.midY - height / 2, available.minY), available.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

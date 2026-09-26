import SwiftUI

/// The app's identity: the two angular strokes the icon is built from.
///
/// **The geometry is the icon's own** — `app/assets/swiftTerm.icon/Assets/SVG Image.svg`, in that
/// file's own coordinate space: a 100×80 box, two open three-point paths, round caps and round joins.
/// The numbers below are that file's, in that file's order, and they are meant to be read against it.
/// Nothing here is traced by eye; if the icon changes, this changes with it.
///
/// **A `Shape` and not an asset**, for three reasons. The mark is drawn at two colours and two sizes and
/// a raster asset would have to be baked at each. It has to stay sharp on any display, which is what a
/// path does and a bitmap does not. And a `Shape` holds no state, which is what keeps this file inside
/// the whole-app typecheck — the same rule every other view in this folder follows.
///
/// The stroke weight is **not** the icon's, and the type's note in `Theme` says why: 3 units in a
/// 100-unit box is right on a 1024-point canvas and invisible on a row.
struct IdentityMark: Shape {
    /// The icon's own viewBox. A shape, not a size — the frame decides how big the mark is drawn.
    static let box = CGSize(width: 100, height: 80)

    func path(in rect: CGRect) -> Path {
        // One scale for both axes, so the mark cannot be stretched by a frame that disagrees with its
        // aspect. The caller is given `Theme.Size.identityMarkAspect` to get that right in the first
        // place; this is what stops a wrong frame from being a wrong *mark*.
        let scale = min(rect.width / Self.box.width, rect.height / Self.box.height)
        let origin = CGPoint(
            x: rect.midX - Self.box.width * scale / 2,
            y: rect.midY - Self.box.height * scale / 2)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        // Left stroke: down from the outer corner, up to the peak, across to the inner valley.
        path.move(to: point(25, 65))
        path.addLine(to: point(29, 34))
        path.addLine(to: point(54, 53))
        // Right stroke: the same gesture, raised and pushed out — the icon's whole idea.
        path.move(to: point(59, 49))
        path.addLine(to: point(62, 19))
        path.addLine(to: point(88, 38))
        return path
    }
}

/// The mark, drawn at a given width.
///
/// The height is derived rather than passed: two numbers that have to agree are two numbers that can
/// disagree, and the mark's aspect is the icon's to decide.
struct IdentityMarkView: View {
    let width: CGFloat
    let color: Color

    var body: some View {
        IdentityMark()
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: width * Theme.Size.identityMarkStrokeRatio,
                    lineCap: .round,
                    lineJoin: .round))
            .frame(width: width, height: width * Theme.Size.identityMarkAspect)
    }
}

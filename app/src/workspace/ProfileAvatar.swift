import AppKit
import SwiftUI

/// The user's picture, at whatever size it is needed.
///
/// **One view, two sizes** — the sidebar's row and the page it opens onto. Two implementations would be two answers to
/// "what does the user look like", and the one that drifts is the one that forgets the picture and draws a letter.
struct ProfileAvatar: View {
    let workspace: AppCore
    let diameter: CGFloat

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Theme.Colors.ramp(dark: 0.3, light: 0.25))
                    Text(initial)
                        .font(.system(size: diameter * 0.42, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    /// The picture the setting points at, or nil when it points at nothing — a path that has been deleted, a file that
    /// is not an image, or no path at all. All three are the same thing here: draw the letter.
    private var picture: NSImage? {
        guard let path = workspace.chrome.avatarPath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private var initial: String { workspace.chrome.userName.prefix(1).uppercased() }
}

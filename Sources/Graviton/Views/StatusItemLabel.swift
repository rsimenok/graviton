import SwiftUI
import AppKit

public struct StatusItemLabel: View {
    @ObservedObject var tracker: TrackerViewModel

    public init(tracker: TrackerViewModel) {
        self.tracker = tracker
    }

    private var statusIcon: NSImage {
        let loaded: NSImage? = {
            #if SWIFT_PACKAGE
            return Bundle.main.image(forResource: "MenuBarIcon") ?? Bundle.module.image(forResource: "MenuBarIcon")
            #else
            return Bundle.main.image(forResource: "MenuBarIcon")
            #endif
        }()
        if let image = loaded {
            let copy = image.copy() as? NSImage ?? image
            copy.isTemplate = true
            return copy
        }
        let fallback = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    public var body: some View {
        if tracker.displayMode == .compact || tracker.menuBarTitle.isEmpty {
            Image(nsImage: statusIcon)
                .renderingMode(.template)
                .foregroundColor(tracker.isPulsing ? .green : .primary)
                .opacity(tracker.isPulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: tracker.isPulsing)
        } else {
            Text(tracker.menuBarTitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(tracker.isPulsing ? .green : .primary)
                .opacity(tracker.isPulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: tracker.isPulsing)
        }
    }
}

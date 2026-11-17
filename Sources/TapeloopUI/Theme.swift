#if os(macOS)
    import AppKit
    import SwiftUI

    /// Tapeloop's visual system: flat colours, tight corners (2–4 points), one amber accent.
    ///
    /// Every window and the popover use these, so new UI matches existing UI. Controls are drawn in SwiftUI (not the
    /// AppKit-backed system controls) so they look the same everywhere and render in snapshot images.
    public enum Tape {
        /// Recording amber (macOS's microphone-indicator orange). The accent: primary buttons, selection, progress.
        public static let amber = Color(red: 1, green: 159 / 255, blue: 10 / 255)
        /// Text on amber.
        public static let onAmber = Color(red: 22 / 255, green: 22 / 255, blue: 22 / 255)
        /// Paused grey.
        public static let grey = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
        /// Attention red (a missing permission, a failure, delete).
        public static let red = Color(red: 1, green: 59 / 255, blue: 48 / 255)
        /// Meeting blue (detected meetings on the timeline, meeting tags).
        public static let meeting = Color(red: 10 / 255, green: 132 / 255, blue: 1)
        /// Success green ("Allowed").
        public static let green = Color(red: 40 / 255, green: 167 / 255, blue: 69 / 255)
        /// The app icon's graphite.
        public static let graphite = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

        /// The corner radius of controls and panels.
        public static let radius: CGFloat = 3
        /// A hairline separator / border colour that works in light and dark.
        public static let line = Color.primary.opacity(0.14)
        /// A subtle fill for fields and selected rows.
        public static let fill = Color.primary.opacity(0.06)
        /// A slightly stronger fill (selected list rows).
        public static let selectedFill = Color.primary.opacity(0.1)
    }

    // MARK: - Buttons

    /// Tapeloop's button: a flat rectangle with a 3-point corner.
    public struct TapeButtonStyle: ButtonStyle {
        /// The button's role.
        public enum Kind: Sendable {
            /// Amber fill, dark text: the one main action on a surface ("Save 12 min").
            case primary
            /// Bordered, no fill: everything else.
            case secondary
            /// Bordered, red text: destructive actions ("Delete", "Erase Buffer Now…").
            case destructive
        }

        var kind: Kind
        @Environment(\.isEnabled) private var isEnabled

        /// Creates the style.
        public init(_ kind: Kind = .secondary) {
            self.kind = kind
        }

        public func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: Tape.radius)
                        .fill(kind == .primary ? Tape.amber : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tape.radius)
                        .strokeBorder(kind == .primary ? Tape.amber : Tape.line, lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
        }

        private var foreground: Color {
            switch kind {
            case .primary: Tape.onAmber
            case .secondary: .primary
            case .destructive: Tape.red
            }
        }
    }

    extension ButtonStyle where Self == TapeButtonStyle {
        /// The amber main action.
        public static var tapePrimary: TapeButtonStyle { TapeButtonStyle(.primary) }
        /// A bordered secondary action.
        public static var tape: TapeButtonStyle { TapeButtonStyle(.secondary) }
        /// A destructive action.
        public static var tapeDestructive: TapeButtonStyle { TapeButtonStyle(.destructive) }
    }

    /// A small selectable chip ("5 min", "15 min").
    public struct ChipStyle: ButtonStyle {
        var selected: Bool
        @Environment(\.isEnabled) private var isEnabled

        /// Creates the style.
        public init(selected: Bool) {
            self.selected = selected
        }

        public func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: Tape.radius)
                        .strokeBorder(selected ? Tape.amber : Tape.line, lineWidth: selected ? 2 : 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Rectangle())
        }
    }

    /// A plain icon + label button for tool rows ("Pause", "Bookmark", "Library").
    public struct ToolButtonStyle: ButtonStyle {
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        /// Creates the style.
        public init() {}

        public func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Tape.radius).fill(
                        hovering || configuration.isPressed ? Tape.fill : .clear)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }

    // MARK: - Toggles

    /// An amber switch.
    public struct TapeSwitchStyle: ToggleStyle {
        /// Creates the style.
        public init() {}

        public func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Tape.amber : Color.primary.opacity(0.18))
                        .frame(width: 30, height: 17)
                    Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .frame(width: 13, height: 13).padding(.horizontal, 2)
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                configuration.label
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "on" : "off")
        }
    }

    /// An amber checkbox with a square corner.
    public struct TapeCheckboxStyle: ToggleStyle {
        /// Creates the style.
        public init() {}

        public func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tape.radius)
                        .fill(configuration.isOn ? Tape.amber : Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: Tape.radius)
                        .strokeBorder(configuration.isOn ? Tape.amber : Tape.line, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(
                            Tape.onAmber)
                    }
                }
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                configuration.label
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "checked" : "unchecked")
        }
    }

    extension ToggleStyle where Self == TapeSwitchStyle {
        /// The amber switch.
        public static var tapeSwitch: TapeSwitchStyle { TapeSwitchStyle() }
    }

    extension ToggleStyle where Self == TapeCheckboxStyle {
        /// The amber checkbox.
        public static var tapeCheckbox: TapeCheckboxStyle { TapeCheckboxStyle() }
    }

    // MARK: - Segmented picker

    /// A flat segmented control with an amber selected segment.
    public struct TapeSegmented<Value: Hashable>: View {
        let options: [(value: Value, label: String)]
        @Binding var selection: Value

        /// Creates the control.
        public init(_ options: [(value: Value, label: String)], selection: Binding<Value>) {
            self.options = options
            self._selection = selection
        }

        public var body: some View {
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let on = option.value == selection
                    Text(option.label)
                        .font(.system(size: 12, weight: on ? .bold : .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .foregroundStyle(on ? Tape.onAmber : .primary)
                        .background(on ? Tape.amber : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = option.value }
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    if index < options.count - 1 { Rectangle().fill(Tape.line).frame(width: 1) }
                }
            }
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .controlBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: Tape.radius))
            .overlay(RoundedRectangle(cornerRadius: Tape.radius).strokeBorder(Tape.line, lineWidth: 1))
        }
    }

    // MARK: - Panels and tags

    extension View {
        /// A bordered panel with Tapeloop's corner.
        public func tapePanel(padding: CGFloat = 10) -> some View {
            self.padding(padding)
                .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Tape.radius).strokeBorder(Tape.line, lineWidth: 1))
        }
    }

    /// A small tinted tag ("Meeting", "Zoom meeting").
    public struct TagView: View {
        let text: String
        let color: Color

        /// Creates a tag.
        public init(_ text: String, color: Color = Tape.meeting) {
            self.text = text
            self.color = color
        }

        public var body: some View {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.14)))
        }
    }

    // MARK: - The cassette

    /// The brand cassette (upside down: notch on top), as a SwiftUI shape, for empty states and headers.
    ///
    /// Same geometry as the menu bar icon and the app icon: body 20.8 × 13.2 units, corner 0.9, a 2.2-deep notch on
    /// top, reels of radius 3.25 with equal 2.6 gaps, centred in the space below the notch; hubs of radius 1.2. Fill it
    /// with `.fill(style: FillStyle(eoFill: true))` so the reels are cut out.
    public struct CassetteShape: Shape {
        /// Creates the shape.
        public init() {}

        public func path(in rect: CGRect) -> Path {
            CassetteGeometry.path(in: rect)
        }
    }

    /// The cassette's geometry, shared by the SwiftUI shape, the menu bar icon and the app icon generator.
    public enum CassetteGeometry {
        /// The body's width and height in design units.
        public static let bodySize = CGSize(width: 20.8, height: 13.2)
        /// Corner radius.
        public static let corner: CGFloat = 0.9
        /// Notch: where its slanted sides meet the top edge, its floor's ends (x from the body's left), its depth.
        public static let notchTop: (CGFloat, CGFloat) = (4.56875, 16.23125)
        /// The notch floor's two ends (x from the body's left).
        public static let notchFloor: (CGFloat, CGFloat) = (5.6, 15.2)
        /// The notch depth.
        public static let notchDepth: CGFloat = 2.2
        /// The reels' centres (x from the body's left) and their centre's y from the body's top.
        public static let reelX: (CGFloat, CGFloat) = (5.85, 14.95)
        /// The reels' centre, measured down from the body's top.
        public static let reelY: CGFloat = 7.7
        /// Reel and hub radius.
        public static let reelRadius: CGFloat = 3.25
        /// Hub radius.
        public static let hubRadius: CGFloat = 1.2

        /// The cassette fitted into `rect` (aspect kept, centred), as one even-odd path: the body with the notch in its
        /// outline, the reel holes, and the hubs.
        public static func path(in rect: CGRect) -> Path {
            let scale = min(rect.width / bodySize.width, rect.height / bodySize.height)
            let w = bodySize.width * scale
            let h = bodySize.height * scale
            let origin = CGPoint(x: rect.midX - w / 2, y: rect.midY - h / 2)
            return path(origin: origin, scale: scale)
        }

        /// The cassette with its body's top-left at `origin`, `scale` points per design unit (y down).
        public static func path(origin: CGPoint, scale s: CGFloat) -> Path {
            var p = Path()
            let x0 = origin.x
            let y0 = origin.y
            let w = bodySize.width * s
            let h = bodySize.height * s
            let c = corner * s
            // Body outline, clockwise from the top-left corner, with the notch traced into the top edge.
            p.move(to: CGPoint(x: x0 + c, y: y0))
            p.addLine(to: CGPoint(x: x0 + notchTop.0 * s, y: y0))
            p.addLine(to: CGPoint(x: x0 + notchFloor.0 * s, y: y0 + notchDepth * s))
            p.addLine(to: CGPoint(x: x0 + notchFloor.1 * s, y: y0 + notchDepth * s))
            p.addLine(to: CGPoint(x: x0 + notchTop.1 * s, y: y0))
            p.addLine(to: CGPoint(x: x0 + w - c, y: y0))
            p.addArc(tangent1End: CGPoint(x: x0 + w, y: y0), tangent2End: CGPoint(x: x0 + w, y: y0 + c), radius: c)
            p.addLine(to: CGPoint(x: x0 + w, y: y0 + h - c))
            p.addArc(
                tangent1End: CGPoint(x: x0 + w, y: y0 + h), tangent2End: CGPoint(x: x0 + w - c, y: y0 + h), radius: c)
            p.addLine(to: CGPoint(x: x0 + c, y: y0 + h))
            p.addArc(tangent1End: CGPoint(x: x0, y: y0 + h), tangent2End: CGPoint(x: x0, y: y0 + h - c), radius: c)
            p.addLine(to: CGPoint(x: x0, y: y0 + c))
            p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + c, y: y0), radius: c)
            p.closeSubpath()
            for rx in [reelX.0, reelX.1] {
                let centre = CGPoint(x: x0 + rx * s, y: y0 + reelY * s)
                p.addEllipse(
                    in: CGRect(
                        x: centre.x - reelRadius * s, y: centre.y - reelRadius * s, width: reelRadius * 2 * s,
                        height: reelRadius * 2 * s))
                p.addEllipse(
                    in: CGRect(
                        x: centre.x - hubRadius * s, y: centre.y - hubRadius * s, width: hubRadius * 2 * s,
                        height: hubRadius * 2 * s))
            }
            return p
        }
    }
#endif

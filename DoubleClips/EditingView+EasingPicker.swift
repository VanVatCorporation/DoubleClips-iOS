import SwiftUI

// MARK: - Easing curve graph + picker
//
// Replaces the plain dropdown of 32 easing names: every easing is a square tile that draws its own
// curve (time left -> right, value bottom -> top), linear being the straight diagonal. Tapping the
// small tile beside a keyframe opens the grid; a looping dot on the big preview shows the motion.
// Curves are sampled from EasingType.apply, so the graph is always the curve the renderer uses.

extension EditingView {
    
    /// The curve of one easing as a Shape. `.none` (hold) is drawn as a step, because apply() returns 0
    /// for it on purpose: the value holds until the next keyframe, then jumps.
    struct EasingCurveShape: Shape {
        let easing: EditingView.EasingType
        
        /// Value range shown, so overshooting curves (back, elastic) fit instead of being clipped.
        static func range(of easing: EditingView.EasingType) -> ClosedRange<CGFloat> {
            guard easing != .none else { return 0...1 }
            var lo: CGFloat = 0, hi: CGFloat = 1
            for i in 0...120 {
                let v = CGFloat(easing.apply(Float(i) / 120))
                lo = min(lo, v); hi = max(hi, v)
            }
            return lo...hi
        }
        
        func path(in rect: CGRect) -> Path {
            let r = Self.range(of: easing)
            let span = max(r.upperBound - r.lowerBound, 0.0001)
            func point(_ t: CGFloat, _ v: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + t * rect.width,
                        y: rect.maxY - ((v - r.lowerBound) / span) * rect.height)
            }
            var p = Path()
            if easing == .none {
                p.move(to: point(0, 0))
                p.addLine(to: point(1, 0))
                p.addLine(to: point(1, 1))
                return p
            }
            let steps = 120
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let pt = point(t, CGFloat(easing.apply(Float(t))))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
    }
    
    /// Square graph: faint 0 / 1 guide lines, the curve, end dots. `animated` adds a dot that rides the curve.
    struct EasingCurveGraph: View {
        let easing: EditingView.EasingType
        var lineWidth: CGFloat = 2
        var animated = false
        var tint: Color = .white
        
        var body: some View {
            GeometryReader { geo in
                let r = EasingCurveShape.range(of: easing)
                let span = max(r.upperBound - r.lowerBound, 0.0001)
                let size = geo.size
                // y of value 0 and value 1 inside the (possibly taller) range
                let y0 = size.height - ((0 - r.lowerBound) / span) * size.height
                let y1 = size.height - ((1 - r.lowerBound) / span) * size.height
                
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y0)); p.addLine(to: CGPoint(x: size.width, y: y0))
                        p.move(to: CGPoint(x: 0, y: y1)); p.addLine(to: CGPoint(x: size.width, y: y1))
                    }
                    .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    
                    EasingCurveShape(easing: easing)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    
                    Circle().fill(tint.opacity(0.55)).frame(width: lineWidth * 2.4, height: lineWidth * 2.4)
                        .position(x: 0, y: y0)
                    Circle().fill(tint.opacity(0.55)).frame(width: lineWidth * 2.4, height: lineWidth * 2.4)
                        .position(x: size.width, y: y1)
                    
                    if animated {
                        TimelineView(.animation) { context in
                            // 1.6 s ride, short rest at each end
                            let cycle = 2.2, ride = 1.6
                            let phase = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: cycle)
                            let t = CGFloat(min(phase / ride, 1))
                            let v = easing == .none ? (t >= 1 ? 1 : 0) : CGFloat(easing.apply(Float(t)))
                            Circle().fill(Color.mdPrimary)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .frame(width: 14, height: 14)
                                .position(x: t * size.width,
                                          y: size.height - ((v - r.lowerBound) / span) * size.height)
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
    
    /// "EASE_IN_OUT_SINE" -> "In Out Sine"; the two non-curves read "Hold" / "Linear".
    static func easingShortName(_ e: EditingView.EasingType) -> String {
        switch e {
        case .none: return "Hold"
        case .linear: return "Linear"
        default: return e.displayName.replacingOccurrences(of: "Ease ", with: "")
        }
    }
    
    /// Identifies which keyframe the picker sheet is editing.
    struct EasingSheetTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }
    
    /// Small tappable graph in the keyframe row.
    struct EasingChip: View {
        let easing: EditingView.EasingType
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    EasingCurveGraph(easing: easing, lineWidth: 1.6, tint: .mdPrimary)
                        .frame(width: 30, height: 30)
                        .padding(4)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    Text(L(EditingView.easingShortName(easing)))
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: 74, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
        }
    }
    
    /// The grid: big live preview of the current curve on top, then 4 columns of square graph tiles.
    struct EasingPickerSheet: View {
        let current: EditingView.EasingType
        let onPick: (EditingView.EasingType) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var selected: EditingView.EasingType
        
        init(current: EditingView.EasingType, onPick: @escaping (EditingView.EasingType) -> Void) {
            self.current = current
            self.onPick = onPick
            _selected = State(initialValue: current)
        }
        
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
        
        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Easing").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Button("Done") { dismiss() }.tint(Color.mdPrimary)
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
                
                ScrollView {
                    VStack(spacing: 14) {
                        VStack(spacing: 6) {
                            EasingCurveGraph(easing: selected, lineWidth: 3, animated: true, tint: .white)
                                .frame(height: 150)
                                .padding(12)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(L(EditingView.easingShortName(selected)))
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            if selected == .none {
                                Text("Holds the value until the next keyframe, then jumps.")
                                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                            }
                        }
                        
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(EditingView.EasingType.allCases, id: \.self) { e in tile(e) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
            }
            .background(Color(white: 0.11).ignoresSafeArea())
            .preferredColorScheme(.dark)
        }
        
        private func tile(_ e: EditingView.EasingType) -> some View {
            let isSelected = e == selected
            return Button {
                guard e != selected else { return }
                selected = e
                onPick(e)
            } label: {
                VStack(spacing: 4) {
                    EasingCurveGraph(easing: e, lineWidth: 2, tint: isSelected ? Color.mdPrimary : .white)
                        .padding(8)
                        .background(isSelected ? Color.mdPrimary.opacity(0.18) : Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.mdPrimary : Color.white.opacity(0.12),
                                        lineWidth: isSelected ? 2.5 : 1)
                        )
                    Text(L(EditingView.easingShortName(e)))
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.7))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

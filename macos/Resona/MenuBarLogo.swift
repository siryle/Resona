import AppKit

enum MenuBarLogo {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: 1, y: 2.4)
            context.scaleBy(x: 18 / 977, y: 18 / 977)
            context.translateBy(x: -136, y: -207)
            context.setFillColor(NSColor.black.cgColor)
            let mark = CGMutablePath()
            mark.move(to: CGPoint(x: 487, y: 1023))
            mark.addLine(to: CGPoint(x: 487, y: 977))
            mark.addQuadCurve(to: CGPoint(x: 479, y: 966), control: CGPoint(x: 487, y: 966))
            mark.addCurve(to: CGPoint(x: 162, y: 638), control1: CGPoint(x: 305, y: 966), control2: CGPoint(x: 162, y: 826))
            mark.addCurve(to: CGPoint(x: 493, y: 308), control1: CGPoint(x: 162, y: 456), control2: CGPoint(x: 309, y: 308))
            mark.addCurve(to: CGPoint(x: 740, y: 548), control1: CGPoint(x: 638, y: 308), control2: CGPoint(x: 740, y: 417))
            mark.addCurve(to: CGPoint(x: 495, y: 769), control1: CGPoint(x: 740, y: 667), control2: CGPoint(x: 694, y: 755))
            mark.addQuadCurve(to: CGPoint(x: 487, y: 779), control: CGPoint(x: 487, y: 771))
            mark.addLine(to: CGPoint(x: 487, y: 942))
            mark.addCurve(to: CGPoint(x: 185, y: 641), control1: CGPoint(x: 314, y: 928), control2: CGPoint(x: 185, y: 798))
            mark.addCurve(to: CGPoint(x: 469, y: 339), control1: CGPoint(x: 185, y: 482), control2: CGPoint(x: 288, y: 339))
            mark.addCurve(to: CGPoint(x: 689, y: 569), control1: CGPoint(x: 591, y: 339), control2: CGPoint(x: 689, y: 438))
            mark.addCurve(to: CGPoint(x: 520, y: 780), control1: CGPoint(x: 689, y: 680), control2: CGPoint(x: 623, y: 749))
            mark.addQuadCurve(to: CGPoint(x: 517, y: 792), control: CGPoint(x: 511, y: 783))
            mark.addLine(to: CGPoint(x: 685, y: 1001))
            mark.addQuadCurve(to: CGPoint(x: 744, y: 1032), control: CGPoint(x: 708, y: 1032))
            mark.addLine(to: CGPoint(x: 909, y: 1032))
            mark.addQuadCurve(to: CGPoint(x: 916, y: 1021), control: CGPoint(x: 921, y: 1032))
            mark.addLine(to: CGPoint(x: 804, y: 870))
            mark.addCurve(to: CGPoint(x: 704, y: 789), control1: CGPoint(x: 772, y: 830), control2: CGPoint(x: 745, y: 808))
            mark.addCurve(to: CGPoint(x: 885, y: 551), control1: CGPoint(x: 821, y: 770), control2: CGPoint(x: 885, y: 678))
            mark.addCurve(to: CGPoint(x: 538, y: 235), control1: CGPoint(x: 885, y: 374), control2: CGPoint(x: 734, y: 235))
            mark.addCurve(to: CGPoint(x: 136, y: 628), control1: CGPoint(x: 319, y: 235), control2: CGPoint(x: 136, y: 405))
            mark.addCurve(to: CGPoint(x: 480, y: 1030), control1: CGPoint(x: 136, y: 836), control2: CGPoint(x: 285, y: 1001))
            mark.addQuadCurve(to: CGPoint(x: 487, y: 1023), control: CGPoint(x: 487, y: 1031))
            mark.closeSubpath()
            mark.addEllipse(in: CGRect(x: 365, y: 537, width: 214, height: 214))
            mark.addEllipse(in: CGRect(x: 451, y: 623, width: 42, height: 42))
            // Keep the record grooves readable at menu-bar size.
            for (x, y) in [(224.0, 619.0), (272, 619), (320, 619)] {
                let groove = CGMutablePath()
                groove.move(to: CGPoint(x: x, y: y))
                groove.addQuadCurve(to: CGPoint(x: x + 168 - (x - 224) / 1.6, y: 407 + (x - 224)),
                                    control: CGPoint(x: x + 20, y: 470 + (x - 224)))
                mark.addPath(groove.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
            context.addPath(mark)
            context.drawPath(using: .eoFill)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(66)
            context.setLineCap(.round)
            for (start, end, control) in [
                (CGPoint(x: 826, y: 240), CGPoint(x: 850, y: 815), CGPoint(x: 1110, y: 496)),
                (CGPoint(x: 980, y: 270), CGPoint(x: 920, y: 874), CGPoint(x: 1230, y: 570))
            ] {
                context.move(to: start)
                context.addQuadCurve(to: end, control: control)
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

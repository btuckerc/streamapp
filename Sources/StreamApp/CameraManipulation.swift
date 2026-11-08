import AppKit
import SwiftUI

/// A hit region only over the camera, never over desktop/chat controls. Video remains
/// in the Metal preview; this overlay draws only event-driven guides.
struct CameraDragOverlay: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    var configuration: StudioConfiguration
    @State private var startRect: CGRect?
    @State private var dragged: CameraAnchor?
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            let canvas = CameraDisplayMapping.fitted(source: CGSize(width: 1920, height: 1080), in: CGRect(origin: .zero, size: proxy.size))
            let scale = canvas.width / 1920
            let g = SceneGeometry(configuration: configuration)
            let anchor = dragged ?? engine.cameraDragAnchor ?? engine.cameraDodgeAnchor ?? configuration.cameraAnchor
            let rect = CameraPlacement.rect(anchor: anchor, size: g.camera.size, desktop: g.desktop)
            let viewRect = CGRect(x: canvas.minX + rect.minX * scale, y: canvas.minY + (1080 - rect.maxY) * scale,
                                  width: rect.width * scale, height: rect.height * scale)
            ZStack(alignment: .topLeading) {
                if dragged != nil {
                    Path { path in
                        if anchor.x == 0 || anchor.x == 0.5 || anchor.x == 1 {
                            let x = (anchor.x == 0 ? rect.minX : anchor.x == 1 ? rect.maxX : rect.midX) * scale + canvas.minX
                            path.move(to: CGPoint(x: x, y: canvas.minY)); path.addLine(to: CGPoint(x: x, y: canvas.maxY))
                        }
                        if anchor.y == 0 || anchor.y == 0.5 || anchor.y == 1 {
                            let y = (1080 - (anchor.y == 0 ? rect.maxY : anchor.y == 1 ? rect.minY : rect.midY)) * scale + canvas.minY
                            path.move(to: CGPoint(x: canvas.minX, y: y)); path.addLine(to: CGPoint(x: canvas.maxX, y: y))
                        }
                    }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).allowsHitTesting(false)
                }
                let shape = configuration.cameraFrame == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8))
                shape.fill(Color.white.opacity(0.001))
                    .overlay(shape.stroke(Color.accentColor.opacity(hovering || dragged != nil ? 0.9 : 0), lineWidth: 1))
                    .contentShape(shape)
                    .frame(width: viewRect.width, height: viewRect.height)
                    .offset(x: viewRect.minX, y: viewRect.minY)
                    .onHover { over in
                        hovering = over
                        if dragged == nil { (over ? NSCursor.openHand : NSCursor.arrow).set() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cameraCanvas")).onChanged { value in
                        if startRect == nil { startRect = rect }
                        guard let startRect, scale > 0 else { return }
                        let origin = CGPoint(x: startRect.minX + value.translation.width / scale,
                                             y: startRect.minY - value.translation.height / scale)
                        let a = CameraPlacement.anchor(origin: origin, size: rect.size, desktop: g.desktop,
                                                       snapping: !NSEvent.modifierFlags.contains(.option))
                        dragged = a; engine.setCameraDrag(a); NSCursor.closedHand.set()
                    }.onEnded { value in
                        if let startRect, scale > 0 {
                            let origin = CGPoint(x: startRect.minX + value.translation.width / scale,
                                                 y: startRect.minY - value.translation.height / scale)
                            let final = CameraPlacement.anchor(origin: origin, size: rect.size, desktop: g.desktop,
                                snapping: !NSEvent.modifierFlags.contains(.option))
                            model.commitCameraDrag(final)
                        }
                        dragged = nil; startRect = nil; NSCursor.openHand.set()
                    })
                    .accessibilityLabel("Move webcam")
                    .help("Drag to move webcam · Hold Option for free placement")
            }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .coordinateSpace(name: "cameraCanvas")
        }.onDisappear {
            if let dragged { model.commitCameraDrag(dragged) }
            dragged = nil; startRect = nil; NSCursor.arrow.set()
        }
    }
}

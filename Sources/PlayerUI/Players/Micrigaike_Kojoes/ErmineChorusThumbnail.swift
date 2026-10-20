import SwiftUI

extension ErmineChorusRenderer {
    /// The still picture on the display tab's selection card.
    static func drawThumbnail(_ original: GraphicsContext, size: CGSize) {
        guard let member = ErmineCast.members.first(where: { $0.id == 1 }) else { return }
        var context = original
        // Head and chest of ermine 1, as on the stage.
        context.translateBy(x: size.width / 2, y: size.height * 1.85)
        context.scaleBy(x: size.height / 58, y: size.height / 58)
        drawErmine(context, drawing: ErmineDrawing(pose: ErmineKeyName.idleA.key, frame: ErmineFrame()), member: member)
    }
}

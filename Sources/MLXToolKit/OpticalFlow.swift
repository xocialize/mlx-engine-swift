import Foundation

/// A dense per-pixel motion field — the canonical artifact for `opticalFlow`. `uv` is
/// row-major `[H × W × 2]` with interleaved (u, v) pixel displacements: the pixel at
/// `(x, y)` in the first frame moved to `(x + u, y + v)` in the second.
public struct FlowField: Sendable, Codable, Equatable {
    public let width: Int
    public let height: Int
    /// Interleaved (u, v) per pixel; `count == width * height * 2`.
    public let uv: [Float]

    public init(width: Int, height: Int, uv: [Float]) {
        self.width = width
        self.height = height
        self.uv = uv
    }

    /// (u, v) at pixel (x, y).
    public subscript(x: Int, y: Int) -> (u: Float, v: Float) {
        let i = (y * width + x) * 2
        return (uv[i], uv[i + 1])
    }
}

/// Canonical optical-flow request: estimate dense motion between two frames. A building block
/// for temporal-consistent enhancement (warping) and the planner's motion features.
/// Canonical output is a `FlowField`.
public struct OpticalFlowRequest: CapabilityRequest {
    public static var capability: Capability { .opticalFlow }

    /// The first frame (canonical `Image` artifact).
    public let image0: Image
    /// The second frame (same dimensions as the first).
    public let image1: Image
    public let mode: Mode?
    public let metaData: MetaData

    public init(image0: Image, image1: Image, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image0 = image0
        self.image1 = image1
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical optical-flow response: the dense flow field at the input resolution.
public struct OpticalFlowResponse: CapabilityResponse {
    public let flow: FlowField
    public init(flow: FlowField) { self.flow = flow }
}

/// The canonical descriptor shape for an optical-flow tool.
public enum OpticalFlowContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .opticalFlow,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image0", kind: .image, required: true,
                                summary: "The first frame."),
                ParameterSchema(name: "image1", kind: .image, required: true,
                                summary: "The second frame (same dimensions)."),
            ],
            supportedModes: modes
        )
    }
}

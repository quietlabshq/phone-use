import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// A real loopback HTTP/WebSocket peer for the outbound URLSession connector.
final class RelayTestPeer: @unchecked Sendable {
    let generation = UUID().uuidString.lowercased()
    private let rejectConnect401: Bool
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var listener: (any Channel)?
    private var websocket: (any Channel)?
    private var received: [[String: Any]] = []
    private var recordedPairPath: String?
    private var recordedPairAuthorization: String?
    private var connects = 0
    var port: Int { lock.withLock { listener!.localAddress!.port! } }
    var pairPath: String? { lock.withLock { recordedPairPath } }
    var pairAuthorization: String? { lock.withLock { recordedPairAuthorization } }
    var connectionCount: Int { lock.withLock { connects } }
    var isConnected: Bool { lock.withLock { websocket?.isActive == true } }

    private init(rejectConnect401: Bool) { self.rejectConnect401 = rejectConnect401 }

    static func start(rejectConnect401: Bool = false) async throws -> RelayTestPeer {
        let peer = RelayTestPeer(rejectConnect401: rejectConnect401)
        let channel = try await ServerBootstrap(group: peer.group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { channel in
                let httpHandler = RelayPeerHTTPHandler(peer: peer)
                if peer.rejectConnect401 {
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
                }
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 384 * 1024,
                    shouldUpgrade: { channel, head in
                        guard head.uri == "/daemon/test-mac/connect", head.headers.first(name: "authorization") == "Bearer daemon-secret" else {
                            return channel.eventLoop.makeFailedFuture(RelayPeerError.invalidRequest)
                        }
                        peer.lock.withLock { peer.connects += 1 }
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        peer.lock.withLock { peer.websocket = channel }
                        return channel.pipeline.addHandler(RelayPeerWebSocketHandler(peer: peer)).map {
                            channel.eventLoop.scheduleTask(in: .milliseconds(10)) {
                                let text = "{\"v\":1,\"type\":\"connected\",\"generation\":\"\(peer.generation)\"}"
                                channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)), promise: nil)
                            }
                        }
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { (context: ChannelHandlerContext) in
                    context.pipeline.removeHandler(httpHandler, promise: nil)
                })).flatMap {
                    channel.pipeline.addHandler(httpHandler, name: "peer-http")
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        peer.lock.withLock { peer.listener = channel }
        return peer
    }

    func waitFor(type: String, timeout: Duration = .seconds(5)) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let frame = lock.withLock({ () -> [String: Any]? in
                guard let index = received.firstIndex(where: { $0["type"] as? String == type }) else { return nil }
                return received.remove(at: index)
            }) { return frame }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RelayPeerError.timedOut
    }
    func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RelayPeerError.timedOut
    }
    func drain(type: String) -> [[String: Any]] {
        lock.withLock {
            let matching = received.filter { $0["type"] as? String == type }
            received.removeAll { $0["type"] as? String == type }
            return matching
        }
    }
    func dispatch(body: Data, headers: [[String]], deadlineMilliseconds: Int64? = nil) async throws {
        let value: [String: Any] = [
            "v": 1, "type": "dispatch", "generation": generation,
            "dispatchID": UUID().uuidString.lowercased(), "requestID": UUID().uuidString.lowercased(),
            "deadline": deadlineMilliseconds ?? Int64(Date().timeIntervalSince1970 * 1_000) + 30_000,
            "method": "POST", "path": "/mcp", "headers": headers, "body": body.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: value)
        let channel = lock.withLock { websocket }
        guard let channel else { throw RelayPeerError.invalidRequest }
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(bytes: data))).get()
    }
    func disconnect() async throws {
        let channel = lock.withLock { websocket }
        if let channel { try await channel.close().get() }
    }
    func revokeConnection() async throws {
        guard let channel = lock.withLock({ websocket }) else { throw RelayPeerError.invalidRequest }
        var body = ByteBuffer()
        body.writeInteger(UInt16(4001))
        body.writeString("Revoked")
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: body)).get()
        try await channel.close().get()
    }
    func shutdown() async {
        let channels = lock.withLock { (listener, websocket) }
        if let ws = channels.1, ws.isActive { try? await ws.close().get() }
        if let listener = channels.0, listener.isActive { try? await listener.close().get() }
        try? await group.shutdownGracefully()
    }
    fileprivate func record(_ frame: [String: Any]) { lock.withLock { received.append(frame) } }
    fileprivate func recordPair(_ path: String, _ authorization: String?) {
        lock.withLock { recordedPairPath = path; recordedPairAuthorization = authorization }
    }
    fileprivate func recordConnect() { lock.withLock { connects += 1 } }
}

private enum RelayPeerError: Error { case invalidRequest, timedOut }

private final class RelayPeerWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    private let peer: RelayTestPeer
    init(peer: RelayTestPeer) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        var payload = frame.unmaskedData
        guard let text = payload.readString(length: payload.readableBytes),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        peer.record(object)
    }
}

private final class RelayPeerHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private let peer: RelayTestPeer
    private var head: HTTPRequestHead?
    init(peer: RelayTestPeer) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(value):
            head = value
            if value.uri == "/daemon/test-mac/connect" { peer.recordConnect() }
        case .body: break
        case .end:
            guard let head else { return }
            peer.recordPair(head.uri, head.headers.first(name: "authorization"))
            let body = Data(#"{"daemonSecret":"daemon-secret"}"#.utf8)
            let status: HTTPResponseStatus = head.uri == "/daemon/test-mac/connect" ? .unauthorized :
                head.uri == "/daemon/test-mac/pair" && head.method == .POST ? .ok : .notFound
            context.write(NIOAny(HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: ["content-type": "application/json", "content-length": String(body.count)]))), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            context.close(promise: nil)
        }
    }
}

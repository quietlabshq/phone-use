import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// HTTP/1 adapter with one request per connection, bounded parsing and no replay buffers.
public final class HTTPListener: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let connections: Connections
    private let service: HTTPService
    public var port: Int { channel.localAddress!.port! }
    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, connections: Connections, service: HTTPService) {
        self.group = group; self.channel = channel; self.connections = connections; self.service = service
    }
    public static func start(service: HTTPService, host: String = "127.0.0.1", port: Int = 8765, inputIdleTimeout: TimeInterval = 15) async throws -> HTTPListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = Connections()
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = 16384; limits.maxHeaderListSize = 16384; limits.maxHeaderFieldCount = 64
        let decoderLimits = limits
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 32768, high: 65536))
                .childChannelInitializer { channel in
                    guard connections.insert(channel) else { return channel.close() }
                    channel.closeFuture.whenComplete { _ in connections.remove(channel) }
                    return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withDecoderLimitConfiguration: decoderLimits).flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandlers(IdleStateHandler(readTimeout: .nanoseconds(Int64(inputIdleTimeout * 1_000_000_000)), writeTimeout: .seconds(30)), RequestHandler(service: service))
                    }
                }.bind(host: host, port: port).get()
            if port == 0, let boundPort = channel.localAddress?.port {
                await service.allowHost(host.contains(":") ? "[\(host)]:\(boundPort)" : "\(host):\(boundPort)")
            }
            return HTTPListener(group: group, channel: channel, connections: connections, service: service)
        } catch { try? await group.shutdownGracefully(); throw error }
    }
    public func shutdown() async {
        try? await channel.close().get()
        await service.shutdown()
        for channel in connections.all() { try? await channel.close().get() }
        try? await group.shutdownGracefully()
    }
}
private final class Connections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: any Channel] = [:]
    func insert(_ channel: any Channel) -> Bool {
        lock.withLock {
            guard channels.count < 64 else { return false }
            channels[ObjectIdentifier(channel)] = channel; return true
        }
    }
    func remove(_ channel: any Channel) { _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    func all() -> [any Channel] { lock.withLock { Array(channels.values) } }
}
private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let service: HTTPService
    var head: HTTPRequestHead?
    var body = Data()
    var complete = false
    init(service: HTTPService) { self.service = service }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !complete else { return }
        switch unwrapInboundIn(data) {
        case let .head(head):
            guard head.version == .http1_1, head.uri.utf8.count <= 2048 else { finish(context.channel, .init(status: 400)); return }
            self.head = head
            if let length = head.headers.first(name: "content-length"), (Int(length) ?? Int.max) > 262144 { finish(context.channel, .init(status: 413)) }
        case var .body(buffer):
            guard body.count + buffer.readableBytes <= 262144 else { finish(context.channel, .init(status: 413)); return }
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case let .end(trailers):
            guard let head, trailers == nil else { finish(context.channel, .init(status: 400)); return }
            complete = true
            let request = RemoteHTTPRequest(method: head.method.rawValue, path: head.uri, headers: head.headers.map { ($0.name, $0.value) }, body: body)
            self.body = Data()
            let channel = context.channel
            channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in channel.close(promise: nil) }
            Task {
                let response = await service.handle(request)
                channel.eventLoop.execute { self.write(channel, response) }
            }
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent, !complete { context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
    private func finish(_ channel: any Channel, _ response: RemoteHTTPResponse) { complete = true; write(channel, response) }
    private func write(_ channel: any Channel, _ response: RemoteHTTPResponse) {
        guard channel.isActive else { return }
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        headers.add(name: "content-length", value: String(response.body.count))
        headers.add(name: "connection", value: "close")
        headers.replaceOrAdd(name: "cache-control", value: "no-store")
        channel.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: .init(statusCode: response.status), headers: headers)), promise: nil)
        if !response.body.isEmpty { channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: response.body))), promise: nil) }
        let drainTimeout = channel.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise: nil) }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in drainTimeout.cancel(); channel.close(promise: nil) }
    }
}

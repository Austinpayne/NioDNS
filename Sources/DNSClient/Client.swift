import NIO

public final class DNSClient: Resolver {
    let dnsDecoder: DNSDecoder
    let channel: Channel
    let primaryAddress: SocketAddress
    var loop: EventLoop {
        return channel.eventLoop
    }
    // Each query has an ID to keep track of which response belongs to which query
    var messageID: UInt16 = 0
    
    internal init(channel: Channel, address: SocketAddress, decoder: DNSDecoder) {
        self.channel = channel
        self.primaryAddress = address
        self.dnsDecoder = decoder
    }
    
    public init(channel: Channel, dnsServerAddress: SocketAddress, context: DNSClientContext) {
        self.channel = channel
        self.primaryAddress = dnsServerAddress
        self.dnsDecoder = context.decoder
    }

    deinit {
        _ = channel.close(mode: .all)
    }
}

public struct DNSClientContext {
    internal let decoder: DNSDecoder
    
    public init(eventLoopGroup: EventLoopGroup) {
        self.decoder = DNSDecoder(group: eventLoopGroup)
    }
}

public enum CallbackSignal {
    case `continue`
    case done
}

public func defaultCallback(_ message: Message, _ loop: EventLoop) -> EventLoopFuture<CallbackSignal> {
    return loop.makeSucceededFuture(.done)
}

public typealias QueryCallback = (Message, EventLoop) -> EventLoopFuture<CallbackSignal>
struct SentQuery {
    let message: Message
    let promise: EventLoopPromise<Message>
    let callback: QueryCallback

    init(message: Message, promise: EventLoopPromise<Message>, callback: @escaping QueryCallback = defaultCallback) {
        self.message = message
        self.promise = promise
        self.callback = callback
    }
}

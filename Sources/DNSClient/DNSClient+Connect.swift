import NIO
import Foundation

extension DNSClient {
    /// Connect to the dns server
    ///
    /// - parameters:
    ///     - group: EventLoops to use
    /// - returns: Future with the NioDNS client
    public static func connect(on group: EventLoopGroup) -> EventLoopFuture<DNSClient> {
        do {
            let configString = try String(contentsOfFile: "/etc/resolv.conf")
            let config = try ResolvConf(from: configString)

            return connect(on: group, config: config.nameservers)
        } catch {
            return group.next().makeFailedFuture(UnableToParseConfig())
        }
    }

    /// Connect to the dns server
    ///
    /// - parameters:
    ///     - group: EventLoops to use
    ///     - host: DNS host to connect to
    /// - returns: Future with the NioDNS client
    public static func connect(on group: EventLoopGroup, host: String) -> EventLoopFuture<DNSClient> {
        do {
            let address = try SocketAddress(ipAddress: host, port: 53)
            return connect(on: group, config: [address])
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }
    
    public static func initializeChannel(_ channel: Channel, context: DNSClientContext, asEnvelopeTo remoteAddress: SocketAddress? = nil) -> EventLoopFuture<Void> {
        if let remoteAddress = remoteAddress {
            return channel.pipeline.addHandlers(
                DNSDecoder(),
                context.cache,
                DNSEncoder(),
                EnvelopeOutboundChannel(address: remoteAddress)
            )
        } else {
            return channel.pipeline.addHandlers(DNSDecoder(), context.cache, DNSEncoder())
        }
    }

    public static func connect(on group: EventLoopGroup, config: [SocketAddress]) -> EventLoopFuture<DNSClient> {
        guard let address = config.preferred else {
            return group.next().makeFailedFuture(MissingNameservers())
        }

        let dnsCache = DNSClientCache(group: group)

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandlers(
                    DNSDecoder(),
                    dnsCache,
                    DNSEncoder(),
                    EnvelopeOutboundChannel(address: address)
                )
        }

        let ipv4 = address.protocol == .inet
        return bootstrap.bind(host: ipv4 ? "0.0.0.0" : "::", port: 0).map { channel in
            let client = DNSClient(
                channel: channel,
                address: address,
                cache: dnsCache
            )

            dnsCache.mainClient = client
            return client
        }
    }

    public static func connectMulticast(on group: EventLoopGroup, using interface: NIONetworkDevice? = nil) -> EventLoopFuture<DNSClient> {
        do {
            var ipv4 = true
            if let interface = interface {
                ipv4 = interface.address?.protocol == .some(.inet)
            }
            let address = try SocketAddress(ipAddress: ipv4 ? "224.0.0.251" : "ff02::fb", port: 5353)
            return connectMulticast(on: group, address: address, using: interface)
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    private static func connectMulticast(on group: EventLoopGroup, address: SocketAddress, using interface: NIONetworkDevice? = nil) -> EventLoopFuture<DNSClient> {
        let dnsCache = DNSClientCache(group: group)

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandlers(
                    DNSDecoder(),
                    dnsCache,
                    DNSEncoder(),
                    EnvelopeOutboundChannel(address: address)
                )
        }

        let ipv4 = address.protocol == .inet
        return bootstrap.bind(host: ipv4 ? "0.0.0.0" : "::", port: 0)
            .flatMap { channel -> EventLoopFuture<Channel> in
                let channel = channel as! MulticastChannel
                return channel.joinGroup(address, device: interface).map { channel }
            }.flatMap { channel -> EventLoopFuture<Channel> in
                guard let index = interface?.interfaceIndex, let addr = interface?.address else {
                    return channel.eventLoop.makeSucceededFuture(channel)
                }
                let provider = channel as! SocketOptionProvider
                switch addr {
                case .v4(let addr):
                    return provider.setIPMulticastIF(addr.address.sin_addr).map { channel }
                case .v6:
                    return provider.setIPv6MulticastIF(CUnsignedInt(index)).map { channel }
                case .unixDomainSocket:
                    preconditionFailure("Should not be possible to create a multicast socket on a unix domain socket")
                }
            }.map { channel in
            let client = DNSClient(
                channel: channel,
                address: address,
                cache: dnsCache
            )

            dnsCache.mainClient = client
            return client
        }
    }
}

fileprivate extension Array where Element == SocketAddress {
    var preferred: SocketAddress? {
        return first(where: { $0.protocol == .inet }) ?? first
    }
}

#if canImport(NIOTransportServices) && os(iOS)
import NIOTransportServices

@available(iOS 12, *)
extension DNSClient {
    public static func connectTS(on group: NIOTSEventLoopGroup, config: [SocketAddress]) -> EventLoopFuture<DNSClient> {
        guard let address = config.preferred else {
            return group.next().makeFailedFuture(MissingNameservers())
        }

        let dnsDecoder = DNSDecoder(group: group)
        
        return NIOTSDatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandlers(dnsDecoder, DNSEncoder())
        }
        .connect(to: address)
        .map { channel -> DNSClient in
            let client = DNSClient(
                channel: channel,
                address: address,
                decoder: dnsDecoder
            )

            dnsDecoder.mainClient = client
            return client
        }
    }
    /// Connect to the dns server
    ///
    /// - parameters:
    ///     - group: EventLoops to use
    /// - returns: Future with the NioDNS client
    public static func connectTS(on group: NIOTSEventLoopGroup) -> EventLoopFuture<DNSClient> {
        do {
            let configString = try String(contentsOfFile: "/etc/resolv.conf")
            let config = try ResolvConf(from: configString)

            return connectTS(on: group, config: config.nameservers)
        } catch {
            return group.next().makeFailedFuture(UnableToParseConfig())
        }
    }
}
#endif

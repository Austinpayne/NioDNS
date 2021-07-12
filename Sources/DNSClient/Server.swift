// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation
import NIO

public final class DNSServer {
    var responders = [MDNSMultiplexer]()
    
    public init() {}
    public func listenMulticast(on group: EventLoopGroup, using interfaces: [NIONetworkDevice] = [], handler: @escaping DNSServerHanderFunction) {

        for interface in interfaces {
            let responder = MDNSMultiplexer()
            _ = responder.listenMulticast(on: group, using: interface, handler: handler)
            responders.append(responder)
        }
    }
}

final class MDNSMultiplexer {
    private var channel: Channel? = nil

    func listenMulticast(
        on group: EventLoopGroup,
        using interface: NIONetworkDevice,
        handler: @escaping DNSServerHanderFunction) -> EventLoopFuture<Void>
    {
        let ipv4 = interface.address?.protocol == .some(.inet6) ? false : true
        let multicastGroup = try! SocketAddress(ipAddress: ipv4 ? "224.0.0.251" : "ff02::fb", port: 5353)
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
            .channelOption(ChannelOptions.receivePacketInfo, value: true)
            .channelInitializer { channel in
                return channel.pipeline.addHandlers(
                    DNSServerFilter(interface: interface),
                    DNSDecoder(),
                    DNSServerHandler(on: multicastGroup, handler: handler),
                    DNSEncoder()
                )
        }

        return bootstrap.bind(host: ipv4 ? "0.0.0.0" : "::", port: 5353)
            .flatMap { channel -> EventLoopFuture<Channel> in
                let channel = channel as! MulticastChannel
                return channel.joinGroup(multicastGroup, device: interface).map { channel }
            }.flatMap { channel -> EventLoopFuture<Channel> in
                guard let address = interface.address else {
                    return channel.eventLoop.makeSucceededFuture(channel)
                }
                let provider = channel as! SocketOptionProvider
                switch address {
                case .v4(let addr):
                    return provider.setIPMulticastIF(addr.address.sin_addr).map { channel }
                case .v6:
                    return provider.setIPv6MulticastIF(CUnsignedInt(interface.interfaceIndex)).map { channel }
                case .unixDomainSocket:
                    preconditionFailure("Should not be possible to create a multicast socket on a unix domain socket")
                }
            }.map { [weak self] in
                self?.channel = $0
            }
    }

    deinit {
        _ = channel?.close()
    }
}

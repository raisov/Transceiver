//  Receiver.swift
//  Transceiver
//  Copyright (c) 2018 Vladimir Raisov. All rights reserved.
//  Licensed under MIT License

import Dispatch
import Sockets
import Interfaces

public class Receiver {

    private let sources: [DispatchSourceRead]

    /// Handler for incoming datagrams and related errors.
    public var delegate: DatagramHandler? {
        willSet {
            guard self.delegate != nil else {return}
            self.sources.forEach { source in
                source.suspend()
            }
        }
        didSet {
            guard let handler = self.delegate else {return}
            self.sources.forEach {source in
                source.setEventHandler {[handler, source] in
                    let handle = Int32(source.handle)
                    let length = Int(source.data)
                    do {
                        handler.dataDidRead(
                            try Datagram(
                                handle,
                                maxDataLength: length,
                                maxAncillaryLength: 72
                            )
                        )
                    } catch {
                        handler.errorDidOccur(error)
                    }
                }
                source.resume()
            }
        }
    }

    /// Creates receiver for unicast and broadcast datagrams.
    /// - Parameters:
    ///     - port: port on wich the receiver will listen.
    ///     - interface: interface used for receiving.
    ///
    /// If `interface` specified, only unicast datagrams addressed to this interface address (IPv4 or IPv6)
    /// will be received; otherwise all datagrams addressed to selected port will be received on all
    /// available interfaces.
    public convenience init(port: UInt16,  interface: Interface? = nil) throws {
        var addresses = [sockaddr_storage]()
        if let interface {
            addresses.append(
                contentsOf: interface.ip4.map { sockaddr_storage($0.with(port: port)) }
            )
            addresses.append(
                contentsOf: interface.ip6.map { sockaddr_storage($0.with(port: port)) }
            )
        } else {
//            addresses.append(contentsOf: Interfaces.list().flatMap{$0.ip4}.map{$0.with(port: port)})
            addresses.append(contentsOf: try getInternetAddresses(port: port))
        }
        try self.init(port: port, addresses)
    }

    /// Creates receiver for multicast datagrams.
    /// - Parameters:
    ///     - port: port on wich the receiver will listen.
    ///     - address: IPv4 or IPv6 multicast group address to join
    ///     - interface: interface used for receiving;
    ///       when omitted, operating system select default interface.
    public convenience init(
        port: UInt16,
        multicast address: String,
        interface: Interface? = nil
    ) throws {
        let addresses = try getInternetAddresses(for: address, port: port, numericHost: true)
        if addresses.isEmpty {
            try self.init(port: port, [])
        } else {
            let address = addresses[0]
            try self.init(port: port, [address])
            assert(addresses.count == 1)
            if let source = sources.first {
                assert(self.sources.count == 1)
                let interfaces: [Interface] = {
                    if let interface {
                        [interface]
                    } else {
                        Array(Interfaces.list())
                    }
                }().filter {
                    $0.options.contains(.multicast) && !$0.options.contains(.pointopoint)
                }
                
                let socket = try Socket(Int32(source.handle))
                
                if let group = address.in?.sin_addr {
                    try interfaces.filter { !$0.ip4.isEmpty }.forEach {interface in
                        try socket.joinToMulticast(group, interfaceIndex: interface.index)
                    }
                } else if let group = address.in6?.sin6_addr {
                    try interfaces.filter { !$0.ip6.isEmpty }.forEach {interface in
                        try socket.joinToMulticast(group, interfaceIndex: interface.index)
                    }
                }
            }
        }
    }

    /// You don't need to know about it, although it does all the work...
    private init(port: UInt16, _ addresses: [sockaddr_storage]) throws {
        self.sources = try addresses.compactMap {address -> Int32? in
            guard let family = Socket.AddressFamily(
                rawValue: numericCast(address.ss_family)
            ) else { return nil }
            guard family == .inet || family == .inet6 else { return nil }
            
            let socket = try Socket(family: family, type: .datagram)
            switch family {
            case .inet:
                try socket.enable(option: IP_RECVDSTADDR, level: IPPROTO_IP) // 16
                try socket.enable(option: IP_RECVPKTINFO, level: IPPROTO_IP) // 24
            case .inet6:
                try socket.enable(option: IPV6_2292PKTINFO, level: IPPROTO_IPV6)
                try socket.enable(option: IPV6_V6ONLY, level: IPPROTO_IPV6)
            default:
                fatalError()
            }
            try socket.enable(option: SO_REUSEADDR, level: SOL_SOCKET)
            try socket.enable(option: SO_REUSEPORT, level: SOL_SOCKET)
            socket.nonBlockingOperations = true
            try address.withSockaddrPointer {
                try socket.bind($0)
            }
            return try socket.duplicateDescriptor()
        }.map { handle in
            let source = DispatchSource.makeReadSource(fileDescriptor: handle)
            source.setCancelHandler{ 
                close(Int32(source.handle))
            }
            return source
        }
    }

    deinit {
        if self.delegate != nil {
            self.sources.forEach {source in
                source.cancel()
            }
        }
    }
}


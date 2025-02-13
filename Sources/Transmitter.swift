//  Transmitter.swift
//  Simplenet Datagram module
//  Copyright (c) 2018 Vladimir Raisov. All rights reserved.
//  Licensed under MIT License

import Darwin.POSIX
import Dispatch
import struct Foundation.Data
import Sockets
import Interfaces

public enum TransmitterError: Error {
	case notReady
	case interfaceNotFound
}

public class Transmitter {
    private let socket: Socket
    private var source: DispatchSourceRead?

	public var delegate: DatagramHandler? {
		willSet {
			source?.cancel()
			guard let newValue else { return }

			do {
				guard let localAddress = socket.localAddress else {
					throw TransmitterError.notReady
				}
				guard let remoteAddress = socket.remoteAddress else {
					throw TransmitterError.notReady
				}

				assert(remoteAddress.sin != nil && localAddress.sin != nil ||
					   remoteAddress.sin6 != nil && localAddress.sin6 != nil)

				var localSocket: Socket?

				if let local_sin = localAddress.sin, let sin = remoteAddress.sin {
					localSocket = try Socket(family: .inet, type: .datagram)
					guard let interface = Self.findInterface(for: local_sin) else {
						throw TransmitterError.interfaceNotFound
					}
					if sin.sin_addr == in_addr.broadcast || sin.sin_addr == interface.broadcast {
						try socket.enable(option: SO_BROADCAST, level: SOL_SOCKET)
						try localSocket!.enable(option: SO_REUSEADDR, level: SOL_SOCKET)
						try localSocket!.enable(option: SO_REUSEPORT, level: SOL_SOCKET)
						try localAddress.withSockaddrPointer(localSocket!.bind)
					} else if sin.isMulticast {
						try socket.enable(option: IP_MULTICAST_LOOP, level: IPPROTO_IP)
						try socket.set(option: IP_MULTICAST_IFINDEX, level: IPPROTO_IP, value: interface.index)
						try localSocket!.enable(option: SO_REUSEADDR, level: SOL_SOCKET)
						try localSocket!.enable(option: SO_REUSEPORT, level: SOL_SOCKET)
						try localAddress.withSockaddrPointer(localSocket!.bind)
					}
					try localSocket!.enable(option: IP_RECVIF, level: IPPROTO_IP) // 32
					try localSocket!.enable(option: IP_RECVDSTADDR, level: IPPROTO_IP) // 16
					try localSocket!.enable(option: IP_RECVPKTINFO, level: IPPROTO_IP) // 24
				} else if let local_sin6 = localAddress.sin6, let sin6 = remoteAddress.sin6 {
					localSocket = try Socket(family: .inet6, type: .datagram)
					guard let interface = Self.findInterface(for: local_sin6) else {
						throw TransmitterError.interfaceNotFound
					}
					if sin6.isMulticast {
						try socket.set(option: IPV6_MULTICAST_IF, level: IPPROTO_IPV6, value: interface.index)
						try socket.enable(option: IPV6_MULTICAST_LOOP, level: IPPROTO_IPV6)
						try localSocket!.enable(option: SO_REUSEADDR, level: SOL_SOCKET)
						try localSocket!.enable(option: SO_REUSEPORT, level: SOL_SOCKET)
						try localAddress.withSockaddrPointer(localSocket!.bind)
					}
					try localSocket!.enable(option: IPV6_2292PKTINFO, level: IPPROTO_IPV6)
				}

				guard let localSocket else {
					throw TransmitterError.notReady
				}

				let handle = try localSocket.duplicateDescriptor()
				source = DispatchSource.makeReadSource(fileDescriptor: handle)
				source!.setCancelHandler{
					close(Int32(handle))
				}
			} catch {
				delegate?.errorDidOccur(error)
			}

		}
		didSet {
			guard let source, let delegate else { return }

			source.setEventHandler {
				let handle = Int32(source.handle)
				let length = Int(source.data)
				do {
					delegate.dataDidRead(
						try Datagram(
							handle,
							maxDataLength: length,
							maxAncillaryLength: 72
						)
					)
				} catch {
					delegate.errorDidOccur(error)
				}
			}
			source.activate()
		}
	}

    /// Creates transmitter to send unicast, multicast and broadcast datagram
    /// - Parameters:
    ///     - host: host to which datagrams will be sent;
    ///       for multicast, IPv4 of IPv6 multicast groupaddress;
    ///       if omitted, broadcast datagrams will be sent.
    ///     - port: port to which datagrams will be sent.
    ///     - interface: network interface through wich datagrams will be sent;
    ///       if omitted, default interface, selected by operating system, will be used.
    /// - Throws: SocketError, InternetAddressError
    public init?(host: String? = nil, port: UInt16,  interface: Interface? = nil) throws {
        guard let address = if let host {
            try getInternetAddresses(for: host, port: port).first
        } else {
            sockaddr_storage((interface?.broadcast ?? in_addr.broadcast).with(port: port))
        } else { return nil }
        
        if address.sin != nil {
            socket = try Socket(family: .inet, type: .datagram)
            if let index = interface?.index {
                try socket.set(option: IP_BOUND_IF, level: IPPROTO_IP, value: index)
            }
        } else if let sin6 = address.sin6 {
            socket = try Socket(family: .inet6, type: .datagram)
            if let index = interface?.index ?? Self.getInterfaceFromIPv6LocalScope(sin6)?.index {
                try socket.set(option: IPV6_BOUND_IF, level: IPPROTO_IPV6, value: index)
            }
        } else {
            return nil
        }
        
        socket.nonBlockingOperations = true
        try address.withSockaddrPointer(socket.connectTo)
	}

	deinit {
		source?.cancel()
	}

    // MARK: - Public methods

    /// Sends datagram to destination specified when transmitter created.
    /// - parameter data: payload of a datagram.
    /// - Throws: SocketError
    public func send(data: Data) throws {
        try socket.send(data)
    }
    
    // MARK: - Private methods
    
    private static func getInterfaceFromIPv6LocalScope(_ sin6: sockaddr_in6) -> Interface? {
        guard sin6.isLinkLocal else { return nil }
        let index: Int32 = numericCast(sin6.sin6_scope_id)
        return Interfaces().first(where: {
            $0.index == index && !$0.ip6.isEmpty
        })
    }
    
    private static func findInterface(for sin: sockaddr_in) -> Interface? {
        Interfaces().first(where: {$0.ip4.contains(sin.sin_addr)})
    }
    
    private static func findInterface(for sin6: sockaddr_in6) -> Interface? {
        Interfaces().first(where: {$0.ip6.contains(sin6.sin6_addr)})
    }
}

//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import CNIOOpenSSL
import NIOTLS

/// The base class for all OpenSSL handlers. This class cannot actually be instantiated by
/// users directly: instead, users must select which mode they would like their handler to
/// operate in, client or server.
///
/// This class exists to deal with the reality that for almost the entirety of the lifetime
/// of a TLS connection there is no meaningful distinction between a server and a client.
/// For this reason almost the entirety of the implementation for the channel and server
/// handlers in OpenSSL is shared, in the form of this parent class.
public class OpenSSLHandler : ChannelInboundHandler, ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    private enum ConnectionState {
        case idle
        case handshaking
        case active
        case closing
        case closed
    }

    private var state: ConnectionState = .idle
    private var connection: SSLConnection
    private var plaintextReadBuffer: ByteBuffer?
    private var bufferedWrites: MarkedCircularBuffer<BufferedWrite>
    private var closePromise: EventLoopPromise<Void>?
    private var didDeliverData: Bool = false
    private let expectedHostname: String?
    
    internal init (connection: SSLConnection, expectedHostname: String? = nil) {
        self.connection = connection
        self.bufferedWrites = MarkedCircularBuffer(initialRingCapacity: 96)  // 96 brings the total size of the buffer to just shy of one page
        self.expectedHostname = expectedHostname
    }

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.connection.setAllocator(ctx.channel.allocator)
        self.plaintextReadBuffer = ctx.channel.allocator.buffer(capacity: SSL_MAX_RECORD_SIZE)
        // If this channel is already active, immediately begin handshaking.
        if ctx.channel.isActive {
            doHandshakeStep(ctx: ctx)
        }
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        // We fire this a bit early, entirely on purpose. This is because
        // in doHandshakeStep we may end up closing the channel again, and
        // if we do we want to make sure that the channelInactive message received
        // by later channel handlers makes sense.
        ctx.fireChannelActive()
        doHandshakeStep(ctx: ctx)
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) {
        // This fires when the TCP connection goes away. Whatever happens, we end up in the closed
        // state here. This function calls out to a lot of user code, so we need to make sure we're
        // keeping track of the state we're in properly before we do anything else.
        let oldState = state
        state = .closed

        switch oldState {
        case .closed, .idle:
            // Nothing to do, but discard any buffered writes we still have.
            discardBufferedWrites(reason: ChannelError.ioOnClosedChannel)
        default:
            // This is a ragged EOF: we weren't sent a CLOSE_NOTIFY. We want to send a user
            // event to notify about this before we propagate channelInactive. We also want to fail all
            // these writes.
            if let closePromise = self.closePromise {
                self.closePromise = nil
                closePromise.fail(error: OpenSSLError.uncleanShutdown)
            }
            ctx.fireErrorCaught(OpenSSLError.uncleanShutdown)
            discardBufferedWrites(reason: OpenSSLError.uncleanShutdown)
        }

        ctx.fireChannelInactive()
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let binaryData = unwrapInboundIn(data)
        
        // The logic: feed the buffers, then take an action based on state.
        connection.consumeDataFromNetwork(binaryData)
        
        switch state {
        case .handshaking:
            doHandshakeStep(ctx: ctx)
        case .active:
            doDecodeData(ctx: ctx)
            doUnbufferWrites(ctx: ctx)
        case .closing:
            doShutdownStep(ctx: ctx)
        default:
            ctx.fireErrorCaught(NIOOpenSSLError.readInInvalidTLSState)
            channelClose(ctx: ctx)
        }
    }
    
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        guard let receiveBuffer = self.plaintextReadBuffer else {
            preconditionFailure("channelReadComplete called before handlerAdded")
        }

        self.doFlushReadData(ctx: ctx, receiveBuffer: receiveBuffer, readOnEmptyBuffer: true)
    }
    
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        bufferWrite(data: unwrapOutboundIn(data), promise: promise)
    }

    public func flush(ctx: ChannelHandlerContext) {
        bufferFlush()
        doUnbufferWrites(ctx: ctx)
    }
    
    public func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard mode == .all else {
            // TODO: Support also other modes ?
            promise?.fail(error: ChannelError.operationUnsupported)
            return
        }
        
        switch state {
        case .closing:
            // We're in the process of TLS shutdown, so let's let that happen. However,
            // we want to cascade the result of the first request into this new one.
            if let promise = promise {
                closePromise!.futureResult.cascade(promise: promise)
            }
        case .idle:
            state = .closed
            fallthrough
        case .closed:
            // For idle and closed connections we immediately pass this on to the next
            // channel handler.
            ctx.close(promise: promise)
        default:
            // We need to begin processing shutdown now. We can't fire the promise for a
            // while though.
            closePromise = promise
            doShutdownStep(ctx: ctx)
        }
    }

    /// Attempt to perform another stage of the TLS handshake.
    ///
    /// A TLS connection has a multi-step handshake that requires at least two messages sent by each
    /// peer. As a result, a handshake will never complete in a single call to OpenSSL. This method
    /// will call `doHandshake`, and will then attempt to write whatever data this generated to the
    /// network. If we are waiting on data from the remote peer, this method will do nothing.
    ///
    /// This method must not be called once the connection is established.
    private func doHandshakeStep(ctx: ChannelHandlerContext) {
        let result = connection.doHandshake()
        
        switch result {
        case .incomplete:
            state = .handshaking
            writeDataToNetwork(ctx: ctx, promise: nil)
        case .complete:
            do {
                try validateHostname(ctx: ctx)
            } catch {
                // This counts as a failure.
                ctx.fireErrorCaught(error)
                channelClose(ctx: ctx)
                return
            }

            state = .active
            writeDataToNetwork(ctx: ctx, promise: nil)
            
            // TODO(cory): This event should probably fire out of the OpenSSL info callback.
            let negotiatedProtocol = connection.getAlpnProtocol()
            ctx.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiatedProtocol))
            
            // We need to unbuffer any pending writes and reads. We will have pending writes if the user attempted to
            // write before we completed the handshake. We may also have pending reads if the user sent data immediately
            // after their FINISHED record. We decode the reads first, as those reads may trigger writes.
            self.doDecodeData(ctx: ctx)
            self.doUnbufferWrites(ctx: ctx)
        case .failed(let err):
            writeDataToNetwork(ctx: ctx, promise: nil)
            
            // TODO(cory): This event should probably fire out of the OpenSSL info callback.
            ctx.fireErrorCaught(NIOOpenSSLError.handshakeFailed(err))
            channelClose(ctx: ctx)
        }
    }

    /// Attempt to perform a stage of orderly TLS shutdown.
    ///
    /// Orderly TLS shutdown requires each peer to send a TLS CloseNotify message.
    /// This message is a signal that the data being sent has been completely sent,
    /// without truncation. Where possible we attempt to perform an orderly shutdown,
    /// and so we will send a CloseNotify. We also try to wait for the remote peer to
    /// send a CloseNotify in response. This means we may call this multiple times,
    /// potentially writing our own CloseNotify each time.
    ///
    /// Once `state` has transitioned to `.closed`, further calls to this method will
    /// do nothing.
    private func doShutdownStep(ctx: ChannelHandlerContext) {
        let result = connection.doShutdown()
        
        switch result {
        case .incomplete:
            state = .closing
            writeDataToNetwork(ctx: ctx, promise: nil)
        case .complete:
            state = .closed
            writeDataToNetwork(ctx: ctx, promise: nil)

            // TODO(cory): This should probably fire out of the OpenSSL info callback.
            ctx.fireUserInboundEventTriggered(TLSUserEvent.shutdownCompleted)
            channelClose(ctx: ctx)
        case .failed(let err):
            // TODO(cory): This should probably fire out of the OpenSSL info callback.
            ctx.fireErrorCaught(NIOOpenSSLError.shutdownFailed(err))
            channelClose(ctx: ctx)
        }
    }

    /// Loops over the `SSL` object, decoding encrypted application data until there is
    /// no more available.
    private func doDecodeData(ctx: ChannelHandlerContext) {
        guard var receiveBuffer = self.plaintextReadBuffer else {
            preconditionFailure("didDecodeData called without handlerAdded firing.")
        }

        // We nil the read buffer here. This is done on purpose: we do it to ensure
        // that we don't have two references to the buffer, otherwise readDataFromNetwork
        // will trigger a CoW every time. We need to put this back on every exit from this
        // function, or before any call-out, to avoid re-entrancy issues. We validate the
        // requirement for this being non-nil on exit at the very least.
        self.plaintextReadBuffer = nil
        defer {
            assert(self.plaintextReadBuffer != nil)
        }

        readLoop: while true {
            let result = connection.readDataFromNetwork(outputBuffer: &receiveBuffer)
            
            switch result {
            case .complete:
                // Good read. We need to check how many bytes are still writable and, if it's
                // too few, move them along. As a general heuristic we want room to write 1kB
                // of data, though this number is utterly arbitrary. In practice this will
                // always double the storage if it has to.
                if receiveBuffer.writableBytes < 1024 {
                    receiveBuffer.changeCapacity(to: receiveBuffer.capacity + 1024)
                }
            case .incomplete:
                self.plaintextReadBuffer = receiveBuffer
                break readLoop
            case .failed(OpenSSLError.zeroReturn):
                // This is a clean EOF: we can just start doing our own clean shutdown.
                self.doFlushReadData(ctx: ctx, receiveBuffer: receiveBuffer, readOnEmptyBuffer: false)
                doShutdownStep(ctx: ctx)
                writeDataToNetwork(ctx: ctx, promise: nil)
                break readLoop
            case .failed(let err):
                self.plaintextReadBuffer = receiveBuffer
                ctx.fireErrorCaught(err)
                channelClose(ctx: ctx)
                break readLoop
            }
        }
    }

    /// Flushes any pending read plaintext. This is called whenever we hit a flush
    /// point for reads: either channelReadComplete, or we receive a CLOSE_NOTIFY.
    ///
    /// This function will always set the empty buffer back to be the plaintext read buffer.
    /// Do not do this in your own code.
    private func doFlushReadData(ctx: ChannelHandlerContext, receiveBuffer: ByteBuffer, readOnEmptyBuffer: Bool) {
        defer {
            // All exits from this function must restore the plaintext read buffer.
            assert(self.plaintextReadBuffer != nil)
        }

        // We only want to fire channelReadComplete in a situation where we have actually sent the user some data, otherwise
        // we'll be confusing the hell out of them.
        if receiveBuffer.writerIndex > receiveBuffer.readerIndex {
            // We need to be very careful here: we must not call out before we fix up our local view of this buffer. In this
            // case, we're going to set the indices back to where they were. In this case we are deliberately *not* calling
            // clear(), as we don't want to trigger a CoW for our own local refs.
            var ourNewBuffer = receiveBuffer
            ourNewBuffer.moveReaderIndex(to: 0)
            ourNewBuffer.moveWriterIndex(to: 0)
            self.plaintextReadBuffer = ourNewBuffer

            // Ok, we can now pass the receive buffer on and fire channelReadComplete.
            ctx.fireChannelRead(self.wrapInboundOut(receiveBuffer))
            ctx.fireChannelReadComplete()
        } else if readOnEmptyBuffer {
            // We didn't deliver data, but the channel is still active. If this channel has got
            // autoread turned off then we should call read again, because otherwise the user
            // will never see any result from their read call.
            self.plaintextReadBuffer = receiveBuffer
            ctx.channel.getOption(option: ChannelOptions.autoRead).whenSuccess { autoRead in
                if !autoRead {
                    ctx.read()
                }
            }
        } else {
            // Regardless of what happens here, we need to put the plaintext read buffer back. Very important.
            self.plaintextReadBuffer = receiveBuffer
        }
    }

    /// Encrypts application data and writes it to the channel.
    ///
    /// This method always flushes. For this reason, it should only ever be called when a flush
    /// is intended.
    private func writeDataToNetwork(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        // There may be no data to write, in which case we can just exit early.
        guard let dataToWrite = connection.getDataForNetwork(allocator: ctx.channel.allocator) else {
            if let promise = promise {
                // If we have a promise, we need to enforce ordering so we issue a zero-length write that
                // the event loop will have to handle.
                let buffer = ctx.channel.allocator.buffer(capacity: 0)
                ctx.writeAndFlush(wrapInboundOut(buffer), promise: promise)
            }
            return
        }

        ctx.writeAndFlush(self.wrapInboundOut(dataToWrite), promise: promise)
    }

    /// Close the underlying channel.
    ///
    /// This method does not perform any kind of I/O. Instead, it simply calls ChannelHandlerContext.close with
    /// any promise we may have already been given. It also transitions our state into closed. This should only be
    /// used to clean up after an error, or to perform the final call to close after a clean shutdown attempt.
    private func channelClose(ctx: ChannelHandlerContext) {
        state = .closed
        let closePromise = self.closePromise
        self.closePromise = nil
        ctx.close(promise: closePromise)
    }

    /// Validates the hostname from the certificate against the hostname provided by
    /// the user, assuming one has been provided at all.
    private func validateHostname(ctx: ChannelHandlerContext) throws {
        guard connection.validateHostnames else {
            return
        }

        // If there is no remote address, something weird is happening here. We can't
        // validate a certificate without it, so bail.
        guard let ipAddress = ctx.channel.remoteAddress else {
            throw NIOOpenSSLError.cannotFindPeerIP
        }

        // We want the leaf certificate.
        guard let peerCert = connection.getPeerCertificate() else {
            throw NIOOpenSSLError.noCertificateToValidate
        }

        guard try validIdentityForService(serverHostname: expectedHostname,
                                         socketAddress: ipAddress,
                                         leafCertificate: peerCert) else {
            throw NIOOpenSSLError.unableToValidateCertificate
        }
    }
}


// MARK: Code that handles buffering/unbuffering writes.
extension OpenSSLHandler {
    private typealias BufferedWrite = (data: ByteBuffer, promise: EventLoopPromise<Void>?)

    private func bufferWrite(data: ByteBuffer, promise: EventLoopPromise<Void>?) {
        bufferedWrites.append((data: data, promise: promise))
    }

    private func bufferFlush() {
        bufferedWrites.mark()
    }

    private func discardBufferedWrites(reason: Error) {
        self.bufferedWrites.forEachRemoving {
            $0.promise?.fail(error: reason)
        }
    }

    private func doUnbufferWrites(ctx: ChannelHandlerContext) {
        // Return early if the user hasn't called flush.
        guard bufferedWrites.hasMark() else {
            return
        }

        // These are some annoying variables we use to persist state across invocations of
        // our closures. A better version of this code might be able to simplify this somewhat.
        var promises: [EventLoopPromise<Void>] = []
        var didWrite = false

        /// Given a byte buffer to encode, passes it to OpenSSL and handles the result.
        func encodeWrite(buf: inout ByteBuffer, promise: EventLoopPromise<Void>?) throws -> Bool {
            let result = connection.writeDataToNetwork(&buf)

            switch result {
            case .complete:
                didWrite = true
                if let promise = promise { promises.append(promise) }
                return true
            case .incomplete:
                // Ok, we can't write. Let's stop.
                return false
            case .failed(let err):
                // Once a write fails, all writes must fail. This includes prior writes
                // that successfully made it through OpenSSL.
                throw err
            }
        }

        func flushWrites() {
            let ourPromise: EventLoopPromise<Void> = ctx.eventLoop.newPromise()
            promises.forEach { ourPromise.futureResult.cascade(promise: $0) }
            writeDataToNetwork(ctx: ctx, promise: ourPromise)
            promises = []
        }

        do {
            try bufferedWrites.forEachElementUntilMark { element in
                var data = element.data
                return try encodeWrite(buf: &data, promise: element.promise)
            }

            // If we got this far and did a write, we should shove the data out to the
            // network.
            if didWrite {
                flushWrites()
            }
        } catch {
            // We encountered an error, it's cleanup time. Close ourselves down.
            channelClose(ctx: ctx)
            // Fail any writes we've previously encoded but not flushed.
            promises.forEach { $0.fail(error: error) }
            // Fail everything else.
            self.discardBufferedWrites(reason: error)
        }
    }
}

fileprivate extension MarkedCircularBuffer {
    fileprivate mutating func forEachElementUntilMark(callback: (E) throws -> Bool) rethrows {
        while try self.hasMark() && callback(self.first!) {
            _ = self.removeFirst()
        }
    }

    fileprivate mutating func forEachRemoving(callback: (E) -> Void) {
        while self.count > 0 {
            callback(self.removeFirst())
        }
    }
}

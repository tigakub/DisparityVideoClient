//
//  Client.swift
//  DisparityVideoClient
//
//  Created by Edward Janne on 3/17/23.
//

/*
    USEFUL REFERENCE:
    https://stackoverflow.com/questions/29525000/how-to-use-videotoolbox-to-decompress-h-264-video-stream/
*/

import VideoToolbox
import Foundation
import Network
import CoreMedia
import SwiftUI

class Client: ObservableObject {
    enum Mode {
        case idle
        case header
        case body
    }
    
    var cnx: NWConnection? = nil
    @Published var connected: Bool = false
    
    let recvQueue = DispatchQueue(label: "Receive thread")
    var recvPacketPool: [DataPacket] = []
    var rcvdPacketPool: [DataPacket] = []
    
    var currentRecvPacket: DataPacket? = nil
    var currentRecvByteCount: UInt32 = 0
    var currentRcvdByteCount: UInt32 = 0
    var recvMode: Mode = .idle
    
    var tempBuffer = Data()
    
    var lastFPS: Float = 0.0
    @Published var fps: Float = 0.0
    var lastFrameTime: UInt64 = 0
    var frameCount: Float = 0.0
    
    var currentFormatDescription: CMFormatDescription? = nil
    var currentDecompressionSession: VTDecompressionSession? = nil
    
    var frameNumber: UInt = 0
    var frameAggregator: [Data] = []
    // var frameAggregator: [H264Slice] = []
    
    var _onSampleBufferClosure: ((CMSampleBuffer)->())? = nil
    @discardableResult func onSampleBuffer(_ closure: ((CMSampleBuffer)->())?)->Client {
        _onSampleBufferClosure = closure
        return self
    }
    
    func startConnection(hostName: String, port: Int = 8989) {
        if cnx != nil { return }
        let host = NWEndpoint.Host(hostName)
        let port = NWEndpoint.Port("\(port)")!
        let cnx = NWConnection(host: host, port: port, using: .tcp)
        self.cnx = cnx
        cnx.stateUpdateHandler = self.didChange(state:)
        cnx.start(queue: .main)
    }
    
    func stop() {
        if let cnx = self.cnx {
            cnx.cancel()
            NSLog("connection stopped")
            self.cnx = nil
        }
    }
    
    func didChange(state: NWConnection.State) {
        switch state {
            case .setup:
                break
            case .waiting(let error):
                NSLog("connection waiting: \(error)")
            case .preparing:
                break
            case .ready:
                connected = true
                NSLog("connection ready")
                self.recv(packetHandler: packetHandler)
            case .failed(let error):
                connected = false
                NSLog("connection failed: \(error)")
            case .cancelled:
                connected = false
                NSLog("connection cancelled")
            @unknown default:
                connected = false
                break
        }
    }
    
    func recv(packetHandler: @escaping (DataPacket)->()) {
        if let cnx = cnx {
            if currentRecvPacket == nil {
                recvMode = .header
                if recvPacketPool.count > 0 {
                    let recycledPacket = recvPacketPool.removeFirst()
                    currentRecvPacket = recycledPacket
                } else {
                    currentRecvPacket = DataPacket()
                }
                currentRecvByteCount = UInt32(MemoryLayout<DataPacket.DataHeader>.size)
                currentRcvdByteCount = 0
                tempBuffer.removeAll(keepingCapacity: true)
            }
            recvQueue.async {
                cnx.receive(minimumIncompleteLength: 1, maximumLength: Int(self.currentRecvByteCount)) {
                    content, contentContext, isComplete, error in
                    DispatchQueue.main.async {
                        if let content = content, content.count > 0 {
                            if let packet = self.currentRecvPacket {
                                self.currentRecvByteCount -= UInt32(content.count)
                                self.currentRcvdByteCount += UInt32(content.count)
                                if self.recvMode == .header {
                                    self.tempBuffer.append(contentsOf: content)
                                } else {
                                    packet.dataBuffer.append(content)
                                }
                                if self.currentRecvByteCount == 0 {
                                    switch self.recvMode {
                                        case .header:
                                            packet.dataHeader.data = self.tempBuffer
                                            packet.dataBuffer.removeAll(keepingCapacity: true)
                                            self.currentRecvByteCount = packet.dataHeader.packetLength
                                            self.currentRcvdByteCount = 0
                                            if self.currentRecvByteCount > 0 {
                                                self.recvMode = .body
                                                packet.reserve(Int(packet.dataHeader.packetLength))
                                            } else {
                                                self.recvMode = .idle
                                                packetHandler(packet)
                                                self.currentRecvPacket = nil
                                                self.currentRcvdByteCount = 0
                                            }
                                        case .body:
                                            self.recvMode = .idle
                                            packetHandler(packet)
                                            self.currentRecvPacket = nil
                                            self.currentRcvdByteCount = 0
                                        case .idle:
                                            break
                                    }
                                    self.tempBuffer.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                        self.recv(packetHandler: packetHandler)
                    }
                }
            }
        }
    }
    
    func send(packet: DataPacket, completion: ((DataPacket, NWError?)->())? = nil) {
        if let cnx = self.cnx {
            cnx.send(content: packet.dataHeader.data, completion: NWConnection.SendCompletion.contentProcessed {
                error in
                DispatchQueue.main.async {
                    if let error = error {
                        NSLog("connection failed to send: \(error)")
                        if let completion = completion {
                            completion(packet, error)
                        }
                    } else {
                        cnx.send(content: packet.dataBuffer, completion: NWConnection.SendCompletion.contentProcessed {
                            error in
                            if let error = error {
                                NSLog("connection failed to send: \(error)")
                            }
                            if let completion = completion {
                                completion(packet, error)
                            }
                        })
                    }
                }
            })
        }
    }
    
    func packetHandler(_ packet: DataPacket) {
        DispatchQueue.global(qos: .default).async {
            do {
                try self.processH264(&packet.dataBuffer)
            } catch(let e) {
                print("Exception thrown while processing H264 packet: \(e)")
            }
            self.frameCount += 1.0
            if self.frameCount > 30 {
                self.frameCount = 30
            }
            let currentFrameTime = DispatchTime.now().uptimeNanoseconds
            let newFPS = 1000000000.0 / Float(currentFrameTime - self.lastFrameTime)
            let factor = Float(2.0 / (1.0 + self.frameCount))
            DispatchQueue.main.async {
                self.fps = newFPS * factor + self.lastFPS * (1.0 - factor)
                self.recvPacketPool.append(packet)
                self.lastFrameTime = currentFrameTime
                self.lastFPS = self.fps
            }
        }
    }
        
    func processH264(_ data: inout Data) throws {
        // let threeByteStartCode = Data([0, 0, 1])
        let fourByteStartCode = Data([0, 0, 0, 1])
        var tail = data
        var countNALUs = 0
        // var naluStarts: [Range<Int>] = []
        var naluRanges: [Range<Int>] = []
        var lastRange: Range<Int>? = nil
        while tail.count > 0, let firstRange = tail.firstRange(of: fourByteStartCode) {
            if let lastRange = lastRange {
                naluRanges.append(lastRange.startIndex ..< firstRange.startIndex)
            }
            tail = tail.suffix(from: firstRange.endIndex)
            countNALUs += 1
            lastRange = firstRange
        }
        if let lastRange = lastRange {
            naluRanges.append(lastRange.startIndex ..< data.endIndex)
        }
        var nalus: [Data] = []
        for range in naluRanges {
            if range.startIndex < data.endIndex && range.endIndex <= data.endIndex {
                let subData = data.subdata(in: range)
                if subData.count > 0 {
                    nalus.append(subData)
                }
            }
        }
        
        var sps: Data? = nil
        var pps: Data? = nil
        // var decodedSPS: H264SPS? = nil
        // var decodedPPS: H264PPS? = nil
        for (_, nalu) in nalus.enumerated() {
            // let unit = H264Unit(nalu: nalu)
            // let zero = nalu[nalu.startIndex + 4] >> 7
            // let refIDC = (nalu[nalu.startIndex + 4] >> 5) & 3
            let type = nalu[nalu.startIndex + 4] & 31
            // var typeDescription = "unknown"
            switch(type) {
                case 1:
                    // print("Coded non-IDR slice")
                    if self.currentFormatDescription != nil {
                        if frameAggregator.count > 0 {
                            // print("Frame boundary")
                            processFrame(slices: frameAggregator)
                            frameAggregator = []
                        }
                        frameAggregator.append(nalu)
                    }
                    /*
                    if let sps = decodedSPS, let pps = decodedPPS {
                        let newSlice = try H264NonIDRSlice(unit: unit, sps: sps, pps: pps)
                        if frameAggregator.count > 0 {
                            // print("Frame boundary")
                            processFrame(slices: frameAggregator)
                            frameAggregator = []
                        }
                        frameAggregator.append(newSlice)
                    }
                    */
                case 2:
                    // print("Coded slice data partition A")
                    if self.currentFormatDescription != nil {
                        frameAggregator.append(nalu)
                    }
                    /*
                    if let sps = decodedSPS, let pps = decodedPPS {
                        let newSlice = try H264NonIDRSlice(unit: unit, sps: sps, pps: pps)
                        frameAggregator.append(newSlice)
                    }
                    */
                case 3:
                    // print("Coded slice data partition B")
                    if self.currentFormatDescription != nil {
                        frameAggregator.append(nalu)
                    }
                    /*
                    if let sps = decodedSPS, let pps = decodedPPS {
                        let newSlice = try H264NonIDRSlice(unit: unit, sps: sps, pps: pps)
                        frameAggregator.append(newSlice)
                    }
                    */
                case 4:
                    // print("Coded slice data partition C")
                    if self.currentFormatDescription != nil {
                        frameAggregator.append(nalu)
                    }
                    /*
                    if let sps = decodedSPS, let pps = decodedPPS {
                        let newSlice = try H264NonIDRSlice(unit: unit, sps: sps, pps: pps)
                        frameAggregator.append(newSlice)
                    }
                    */
                case 5:
                    // print("Coded IDR slice")
                    if self.currentFormatDescription != nil {
                        if frameAggregator.count > 0 {
                            // print("Frame boundary")
                            processFrame(slices: frameAggregator)
                            frameAggregator = []
                        }
                        frameAggregator.append(nalu)
                    }
                    /*
                    if let sps = decodedSPS, let pps = decodedPPS {
                        let newSlice = try H264IDRSlice(unit: unit, sps: sps, pps: pps)
                        if frameAggregator.count > 0 {
                            // print("Frame boundary")
                            processFrame(slices: frameAggregator)
                            frameAggregator = []
                        }
                        frameAggregator.append(newSlice)
                    }
                    */
                case 6:
                    // typeDescription = "Supplemental enhancement information"
                    break
                case 7:
                    // print("Sequence parameter set")
                    // decodedSPS = try H264SPS(unit: unit)
                    sps = nalu
                case 8:
                    // print("Picture parameter set")
                    // decodedPPS = try H264PPS(unit: unit)
                    pps = nalu
                case 9:
                    // typeDescription = "Access unit delimiter"
                    break
                case 10:
                    // typeDescription = "End of sequence"
                    break
                case 11:
                    // typeDescription = "End of stream"
                    break
                case 12:
                    // typeDescription = "Filler data"
                    break
                case 13:
                    // typeDescription = "Sequence parameter set extension"
                    break
                case 14:
                    // typeDescription = "Prefix NALU"
                    break
                case 15:
                    // typeDescription = "Subset sequence parameter set"
                    break
                case 19:
                    // print("Coded slice of an auxiliary coded picture without partitioning")
                    if self.currentFormatDescription != nil {
                        frameAggregator.append(nalu)
                    }
                    /*
                    if let sps = decodedSPS, let pps = decodedPPS {
                        let newSlice = try H264NonIDRSlice(unit: unit, sps: sps, pps: pps)
                        frameAggregator.append(newSlice)
                    }
                    */
                case 20:
                    // typeDescription = "Coded slice extension"
                    break
                case 21:
                    // typeDescription = "Coded slice extension for depth view components"
                    break
                default:
                    break
            }
        
            if let sps = sps, let pps = pps {
                self.currentFormatDescription = H264Unit.createVideoFormatDescription(spsNALU: sps, ppsNALU: pps)
                if let description = self.currentFormatDescription {
                     VTDecompressionSessionCreate(
                        allocator: kCFAllocatorDefault,
                        formatDescription: description,
                        decoderSpecification: nil,
                        imageBufferAttributes: nil,
                        outputCallback: nil,
                        decompressionSessionOut: &self.currentDecompressionSession)
                    }
            }
            
            // print("NALU \(i) (\(String(format: "%6d", nalu.count)) bytes), header zero: \(zero), refIDC: \(refIDC), type: \(String(format: "%2d", type)) (\(typeDescription))")
        }
        
        /*
        var blockBuffer: CMBlockBuffer? = nil
        if let idr = idrNALU {
            blockBuffer = H264Unit.createBlockBuffer(nalu: idr)
        } else if let nidr = nidrNALU {
            blockBuffer = H264Unit.createBlockBuffer(nalu: nidr)
        }
        
        var sampleBuffer: CMSampleBuffer? = nil
        if let format = self.currentFormatDescription, let blockBuffer = blockBuffer {
            sampleBuffer = H264Unit.createSampleBuffer(description: format, blockBuffer: blockBuffer)
        }
        
        if let sampleBuffer = sampleBuffer {
            if let session = self.currentDecompressionSession {
                var infoFlags: VTDecodeInfoFlags = []
                VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sampleBuffer,
                    flags: [],
                    infoFlagsOut: &infoFlags)
                {
                    osStatus, infoFlags, cvImageBuffer, timeStamp, duration in
                    if osStatus != noErr {
                        print("Decoding resulted in error: \(osStatus)")
                    } else {
                        if let cvImageBuffer = cvImageBuffer {
                            let ciImage = CIImage(cvImageBuffer: cvImageBuffer)
                            let context = CIContext(options: nil)
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self._onSampleBufferClosure?(sampleBuffer)
            }
        }
        
        blockBuffer = nil
        sampleBuffer = nil
        */
    }
    
    func processFrame(slices: [Data]) {
    // func processFrame(slices: [H264Slice]) {
        if let description = self.currentFormatDescription {
            var frameSize: Int = 0
            for slice in slices {
                frameSize += slice.count
            }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: frameSize)
            
            var offset: Int = 0
            for slice in slices {
                let sliceData = slice
                var naluLength = UInt32(sliceData.count - 4)
                naluLength = CFSwapInt32HostToBig(naluLength)
                let lengthHeader = Data(bytes: &naluLength, count: 4)
                lengthHeader.copyBytes(to: buffer + offset, count: lengthHeader.count)
                offset += lengthHeader.count
                sliceData.copyBytes(to: buffer + offset, from: sliceData.startIndex + 4 ..< sliceData.endIndex)
                offset += sliceData.endIndex - sliceData.startIndex - 4
            }
            
            var blockBuffer: CMBlockBuffer? = nil
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: buffer,
                blockLength: frameSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: frameSize,
                flags: .zero,
                blockBufferOut: &blockBuffer)
                
            var sampleBuffer: CMSampleBuffer? = nil
            var timingInfo = CMSampleTimingInfo()
            timingInfo.decodeTimeStamp = .invalid
            timingInfo.duration = CMTime.invalid
            timingInfo.presentationTimeStamp = .zero
            
            let error = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: description,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer)
                
            guard error == noErr, let sampleBuffer = sampleBuffer else {
                return
            }
        
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
                let mutableDict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(mutableDict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            
            DispatchQueue.main.async {
                self._onSampleBufferClosure?(sampleBuffer)
            }
        }
    }
}

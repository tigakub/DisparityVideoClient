//
//  H264Unit.swift
//  DisparityVideoClient
//
//  Created by Edward Janne on 3/31/23.
//

import CoreMedia
import Foundation

enum H264DataError: Error {
    case invalidStream
    case bufferOverrun
    case invalidSeqParamSetID
    case invalidChromaFormatIDC
    case invalidBitDepthLuma
    case invalidBitDepthChroma
    case invalidRangeWhileExtractingScalingList
    case invalidMaxFrameNum
    case invalidPicOrderCntType
    case invalidMaxPicOrderCntLSB
    case invalidNumRefFramesInPicOrderCntCycle
    case invalidSliceType
    case unsupportedStream
}

/*
class BitReader {
    var data: Data
    var index: UInt
    
    init(with data: Data, startIndex: UInt = 0) {
        self.data = data
        self.index = startIndex
    }
    
    var bit: UInt {
        get {
            var byteIndex = Int(index / 8)
            if byteIndex > 2 {
                let lastThree = (UInt(data[data.startIndex + byteIndex - 2]) << 16) | (UInt(data[data.startIndex + byteIndex - 1]) << 8) | UInt(data[data.startIndex + byteIndex])
                if lastThree == 0x000003 {
                    byteIndex += 1
                    index += 8
                }
            }
            let localBitIndex = UInt(index & 7)
            let byte = UInt(data[data.startIndex + byteIndex])
            index += 1
            return (byte >> localBitIndex) & 1
        }
    }
    
    @discardableResult func getBitField(count: UInt) throws -> UInt {
        guard index < (data.count << 3) else {
            throw H264DataError.bufferOverrun
        }
        
        var value: UInt = 0
        var count = count
        
        while count > 0 {
            value <<= 1
            value |= bit
            count -= 1
        }
        
        return value
    }
    
    func getBool() throws -> Bool {
        return (try getBitField(count: 1)) == 1
    }
    
    func getUInt() throws -> UInt {
        return try getBitField(count: 8)
    }
    
    func getInt() throws -> Int {
        var uVal = UInt8(try getBitField(count: 8))
        // 2's complement
        if (uVal & 0x80) != 0 {
            uVal = ~uVal
            uVal += 1
            return Int(-Int8(uVal))
        }
        return Int(uVal)
    }
    
    func getUE() throws -> UInt {
        var zeroCount: UInt = 0
        // Count contiguous zero bits
        while bit == 0 {
            zeroCount += 1
            guard zeroCount < 32 else {
                throw H264DataError.invalidStream
            }
        }
        
        var value = (UInt(1) << zeroCount) - UInt(1)
        var rest: UInt = 0
        
        if zeroCount > 0 {
            rest = try getBitField(count: zeroCount)
            if zeroCount == 31 {
                guard rest == 0 else {
                    throw H264DataError.invalidStream
                }
                return value
            }
            value += rest
        }
        
        return value
    }
    
    func getSE() throws -> Int {
        let ue = try getUE()
        
        if ue & 1 == 1 {
            return Int(ue >> 1) + 1
        }
        
        return -Int(ue >> 1)
    }
}
*/

class H264Unit {
    static let kDefault4x4Intra: [Int] = [
        6, 13, 13, 20, 20, 20, 28, 28, 28, 28, 32, 32, 32, 37, 37, 42 ]

    static let kDefault4x4Inter: [Int] = [
        10, 14, 14, 20, 20, 20, 24, 24, 24, 24, 27, 27, 27, 30, 30, 34 ]

    static let kDefault8x8Intra: [Int] = [
        6,  10, 10, 13, 11, 13, 16, 16, 16, 16, 18, 18, 18, 18, 18, 23,
        23, 23, 23, 23, 23, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27,
        27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31,
        31, 33, 33, 33, 33, 33, 36, 36, 36, 36, 38, 38, 38, 40, 40, 42 ]

    static let kDefault8x8Inter: [Int] = [
        9,  13, 13, 15, 13, 15, 17, 17, 17, 17, 19, 19, 19, 19, 19, 21,
        21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 24, 24, 24, 24,
        24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27,
        27, 28, 28, 28, 28, 28, 30, 30, 30, 30, 32, 32, 32, 33, 33, 35 ]

    enum NALUType {
        case unsupported
        case sps
        case pps
        case idr
        case nidr
    }
    
    let type: NALUType
    
    let nalu: Data
    let lengthHeader: Data
    var unsafeMutablePointer: UnsafeMutablePointer<UInt8>? = nil
    var dataPtr: UnsafeBufferPointer<UInt8>? = nil
    
    // static var currentSPS: H264SPS? = nil
    // static var currentPPS: H264PPS? = nil
    
    init(nalu: Data) {
        let type = nalu[nalu.startIndex + 4] & 0x1f
        switch type {
            case 1:
                self.type = .nidr
            case 5:
                self.type = .idr
            case 7:
                self.type = .sps
            case 8:
                self.type = .pps
            default:
                self.type = .unsupported
        }
        
        var naluLength = UInt32(nalu.count - 4)
        naluLength = CFSwapInt32HostToBig(naluLength)
        lengthHeader = Data(bytes: &naluLength, count: 4)
        self.nalu = nalu
        
        nalu.withUnsafeBytes { ptr in
            ptr.withMemoryRebound(to: UInt8.self) { buffer in
                self.dataPtr = buffer
            }
        }
        
        var optionalPtr: UnsafeMutablePointer<UInt8>? = nil
        let length = nalu.count
        var allocate = true
        switch self.type {
            case .idr: fallthrough
            case .nidr:
                break
            case .sps:
                /*
                do {
                    H264Unit.currentSPS = try H264SPS(unit: self)
                } catch(let e) {
                    print("Failed to extract SPS: \(e)")
                }
                */
                break
            case .pps:
                /*
                do {
                    H264Unit.currentPPS = try H264PPS(unit: self)
                } catch(let e) {
                    print("Failed to extract PPS: \(e)")
                }
                */
                break
            default:
                allocate = false
        }
        if allocate {
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
            switch self.type {
                case .idr: fallthrough
                case .nidr:
                    nalu.copyBytes(to: ptr, count: length)
                    lengthHeader.copyBytes(to: ptr, count: 4)
                case .sps: fallthrough
                case .pps:
                    nalu.copyBytes(to: ptr, count: length)
                    // nalu.dropFirst(4).copyBytes(to: ptr, count: length)
                default:
                    break // Should not happen if we get here
            }
            optionalPtr = ptr
        }
        self.unsafeMutablePointer = optionalPtr
    }
    
    /*
    deinit {
        if let ptr = self.unsafeMutablePointer {
            ptr.deallocate()
        }
    }
    */
    
    class func createVideoFormatDescription(spsNALU: Data, ppsNALU: Data)->CMVideoFormatDescription? {
        let spsUnit = H264Unit(nalu: spsNALU)
        let ppsUnit = H264Unit(nalu: ppsNALU)
        var description: CMVideoFormatDescription? = nil
        if spsUnit.type == .sps && ppsUnit.type == .pps {
            if let spsPtr = spsUnit.unsafeMutablePointer, let ppsPtr = ppsUnit.unsafeMutablePointer {
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: [UnsafePointer(spsPtr) + 4, UnsafePointer(ppsPtr) + 4],
                    parameterSetSizes: [spsNALU.count - 4, ppsNALU.count - 4],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        /*
        if let description = description {
            print(description.mediaSubType)
        }
        */
        return description
    }
    
    /*
    class func createBlockBuffer(nalu: Data)->CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer? = nil
        let slice = H264Unit(nalu: nalu)
        if slice.type == .idr || slice.type == .nidr {
            if let slicePtr = slice.unsafeMutablePointer {
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: slicePtr,
                    blockLength: nalu.count,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: nalu.count,
                    flags: .zero,
                    blockBufferOut: &blockBuffer)
            }
        }
        return blockBuffer
    }
    
    class func createSampleBuffer(description: CMVideoFormatDescription, blockBuffer: CMBlockBuffer)->CMSampleBuffer? {
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
            return nil
        }
        
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let mutableDict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(mutableDict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        return sampleBuffer
    }
    */
    
    /*
    func extractScalingList(from bitReader: BitReader, size: Int) throws ->[Int]? {
        var lastScale: Int = 8
        let nextScale: Int = 8
        var deltaScale: Int = 0
        
        var scalingList: [Int] = []
        
        for j in 0 ..< size {
            if nextScale != 0 {
                deltaScale = try bitReader.getSE()
                guard (-128 <= deltaScale) && (deltaScale <= 127) else {
                    throw H264DataError.invalidRangeWhileExtractingScalingList
                }
                
                if j == 0 && nextScale == 0 {
                    return nil
                }
            }
            
            let newScale = (nextScale == 0) ? lastScale : nextScale
            scalingList.append(newScale)
            lastScale = newScale
        }
        
        return scalingList
    }
    */
}

/*
class H264SPS {
    var profileIDC: UInt
    var constraintSet0Flag: Bool
    var constraintSet1Flag: Bool
    var constraintSet2Flag: Bool
    var constraintSet3Flag: Bool
    var constraintSet4Flag: Bool
    var constraintSet5Flag: Bool
    var levelIDC: UInt
    var seqParamSetID: UInt
    var chromaFormatIDC: UInt = 0
    var separateColorPlane: Bool = false
    var bitDepthLumaMinus8: UInt = 0
    var bitDepthChromaMinus8: UInt = 0
    var qpPrimeYZeroTransformBypass: Bool = false
    var seqScalingMatrixPresent: Bool = false
    var scalingList4x4: [[Int]] = []
    var chromaArrayType: UInt = 0
    var log2MaxFrameNumMinus4: UInt = 0
    var picOrderCntType: UInt = 0
    var expectedDeltaPerPicOrderCntCycle: Int = 0
    var log2MaxPicOrderCntLSBMinus4: UInt = 0
    var deltaPicOrderAlwaysZero: Bool = false
    var offsetForNonRefPic: Int = 0
    var offsetForTopToBottomField: Int = 0
    var numRefFramesInPicOrderCntCycle: UInt = 0
    var offsetForRefFrame: [Int] = []
    var maxNumRefFrames: UInt = 0
    var gapsInFrameNumValueAllowed: Bool = false
    var picWidthInMBSMinus1: UInt = 0
    var picHeightInMapUnitsMinus1: UInt = 0
    var frameMBSOnly: Bool = false
    var mbAdaptiveFrameField: Bool = false
    var direct8x8Inference: Bool = false
    var frameCropping: Bool = false
    var frameCropLeftOffset: UInt = 0
    var frameCropRightOffset: UInt = 0
    var frameCropTopOffset: UInt = 0
    var frameCropBottomOffset: UInt = 0
    var vuiParametersPresent: Bool = false
    
    init(unit: H264Unit) throws {
        let bitReader = BitReader(with: unit.nalu, startIndex: 40)
        profileIDC = try bitReader.getUInt()
        constraintSet0Flag = try bitReader.getBool()
        constraintSet1Flag = try bitReader.getBool()
        constraintSet2Flag = try bitReader.getBool()
        constraintSet3Flag = try bitReader.getBool()
        constraintSet4Flag = try bitReader.getBool()
        constraintSet5Flag = try bitReader.getBool()
        try bitReader.getBitField(count: 2)
        levelIDC = try bitReader.getUInt()
        seqParamSetID = try bitReader.getUE()
        guard seqParamSetID < 32 else {
            throw H264DataError.invalidSeqParamSetID
        }
        
        if [UInt(100), 110, 122, 244, 44, 83, 86, 118, 128].contains(where: { v in v == profileIDC }) {
            chromaFormatIDC = try bitReader.getUE()
            
            guard chromaFormatIDC < 4 else {
                throw H264DataError.invalidChromaFormatIDC
            }
            
            if chromaFormatIDC == 3 {
                separateColorPlane = try bitReader.getBool()
            }
            
            bitDepthLumaMinus8 = try bitReader.getUE()
            
            guard bitDepthLumaMinus8 < 7 else {
                throw H264DataError.invalidBitDepthLuma
            }
            
            bitDepthChromaMinus8 = try bitReader.getUE()
            
            guard bitDepthChromaMinus8 < 7 else {
                throw H264DataError.invalidBitDepthChroma
            }
            
            qpPrimeYZeroTransformBypass = try bitReader.getBool()
            seqScalingMatrixPresent = try bitReader.getBool()
            
            if seqScalingMatrixPresent {
                // Extract 4x4 scaling lists
                for i in 0 ..< 6 {
                    let scalingListPresent = try bitReader.getBool()
                    if scalingListPresent {
                        if let scalingList = try unit.extractScalingList(from: bitReader, size: 16) {
                            scalingList4x4.append(scalingList)
                        } else {
                            if i < 3 {
                                scalingList4x4.append(H264Unit.kDefault4x4Intra)
                            } else if i < 6 {
                                scalingList4x4.append(H264Unit.kDefault4x4Inter)
                            }
                        }
                    } else {
                        // TODO: Fallback scaling list
                    }
                }
                
                // Extract 8x8 scaling lists
                let count = (chromaFormatIDC == 3) ? 6 : 2
                for i in 0 ..< count {
                    let scalingListPresent = try bitReader.getBool()
                    if scalingListPresent {
                        if let scalingList = try unit.extractScalingList(from: bitReader, size: 64) {
                            scalingList4x4.append(scalingList)
                        } else {
                            if (i & 1) == 0 {
                                scalingList4x4.append(H264Unit.kDefault8x8Intra)
                            } else if i < 6 {
                                scalingList4x4.append(H264Unit.kDefault8x8Inter)
                            }
                        }
                    } else {
                        // TODO: Fallback scaling list
                    }
                }
            } else {
                // TODO: Fill default sequence scaling lists
            }
        } else {
            chromaFormatIDC = 1
            // TODO: Fill default sequence scaling lists
        }
        
        if !separateColorPlane {
            chromaArrayType = chromaFormatIDC
        }
        
        log2MaxFrameNumMinus4 = try bitReader.getUE()
        
        guard log2MaxFrameNumMinus4 < 13 else {
            throw H264DataError.invalidMaxFrameNum
        }
        
        picOrderCntType = try bitReader.getUE()
        
        guard picOrderCntType < 3 else {
            throw H264DataError.invalidPicOrderCntType
        }
        
        expectedDeltaPerPicOrderCntCycle = 0
        
        if picOrderCntType == 0 {
            log2MaxPicOrderCntLSBMinus4 = try bitReader.getUE()
            
            guard log2MaxPicOrderCntLSBMinus4 < 13 else {
                throw H264DataError.invalidMaxPicOrderCntLSB
            }
        } else if picOrderCntType == 1 {
            deltaPicOrderAlwaysZero = try bitReader.getBool()
            offsetForNonRefPic = try bitReader.getSE()
            offsetForTopToBottomField = try bitReader.getSE()
            numRefFramesInPicOrderCntCycle = try bitReader.getUE()
            
            guard numRefFramesInPicOrderCntCycle < 256 else {
                throw H264DataError.invalidNumRefFramesInPicOrderCntCycle
            }
            
            for _ in 0 ..< numRefFramesInPicOrderCntCycle {
                let offset = try bitReader.getSE()
                offsetForRefFrame.append(offset)
                expectedDeltaPerPicOrderCntCycle += offset
            }
        }
        
        maxNumRefFrames = try bitReader.getUE()
        gapsInFrameNumValueAllowed = try bitReader.getBool()
        picWidthInMBSMinus1 = try bitReader.getUE()
        picHeightInMapUnitsMinus1 = try bitReader.getUE()
        frameMBSOnly = try bitReader.getBool()
        if !frameMBSOnly {
            mbAdaptiveFrameField = try bitReader.getBool()
        }
        direct8x8Inference = try bitReader.getBool()
        frameCropping = try bitReader.getBool()
        if frameCropping {
            frameCropLeftOffset = try bitReader.getUE()
            frameCropRightOffset = try bitReader.getUE()
            frameCropTopOffset = try bitReader.getUE()
            frameCropBottomOffset = try bitReader.getUE()
        }
        vuiParametersPresent = try bitReader.getBool()
        if vuiParametersPresent {
        }
    }
}

class H264PPS {
    init(unit: H264Unit) throws {
    }
}

class H264Slice {
    enum SliceType: UInt {
        case p
        case b
        case i
        case sp
        case si
    }
    
    let unit: H264Unit
    var firstMBInSlice: UInt
    var sliceType: SliceType
    var picParameterSetID: UInt
    var frameNumber: UInt
    var fieldPic: Bool = false
    var idrPicID: UInt = 0
    
    init(unit: H264Unit, sps: H264SPS, pps: H264PPS) throws {
        self.unit = unit
        if sps.separateColorPlane {
            throw H264DataError.unsupportedStream
        }
        let bitReader = BitReader(with: unit.nalu, startIndex: 40)
        firstMBInSlice = try bitReader.getUE()
        let sliceTypeCode = try bitReader.getUE()
        guard sliceTypeCode < 10 else {
            throw H264DataError.invalidSliceType
        }
        sliceType = SliceType(rawValue: sliceTypeCode % 5)!
        picParameterSetID = try bitReader.getUE()
        frameNumber = try bitReader.getBitField(count: sps.log2MaxFrameNumMinus4 + 4)
        
        if !sps.frameMBSOnly {
            fieldPic = try bitReader.getBool()
            guard !fieldPic else {
                throw H264DataError.unsupportedStream
            }
        }
        
        if unit.type == .idr {
            idrPicID = try bitReader.getUE()
        }
    }
}

class H264IDRSlice: H264Slice {
}

class H264NonIDRSlice: H264Slice {
}

class H264Frame {
    var buffer: UnsafeMutablePointer<UInt8>? = nil
    var frameSize: Int
    
    init(slices: [H264Slice]) {
        var bufferSize: Int = 0
        for slice in slices {
            bufferSize += slice.unit.nalu.count
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        
        var offset: Int = 0
        for slice in slices {
            let sliceData = slice.unit.nalu
            var naluLength = UInt32(sliceData.count - 4)
            naluLength = CFSwapInt32HostToBig(naluLength)
            let lengthHeader = Data(bytes: &naluLength, count: 4)
            lengthHeader.copyBytes(to: buffer + offset, count: lengthHeader.count)
            offset += lengthHeader.count
            sliceData.copyBytes(to: buffer + offset, from: sliceData.startIndex + 4 ..< sliceData.endIndex)
            offset += sliceData.endIndex - sliceData.startIndex - 4
        }
        self.buffer = buffer
        self.frameSize = bufferSize
    }
    
    func createBlockBuffer()->CMBlockBuffer? {
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
        return blockBuffer
    }
    
    func createSampleBuffer(description: CMVideoFormatDescription, blockBuffer: CMBlockBuffer)->CMSampleBuffer? {
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
            return nil
        }
        
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let mutableDict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(mutableDict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        return sampleBuffer
    }
}
*/

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
                break
            case .pps:
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
                default:
                    break // Should not happen if we get here
            }
            optionalPtr = ptr
        }
        self.unsafeMutablePointer = optionalPtr
    }
    
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
        return description
    }
    
}

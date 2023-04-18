//
//  DataPacket.swift
//  DisparityVideoClient
//
//  Created by Edward Janne on 3/30/23.
//

import Foundation

class DataPacket {
    enum PacketType: UInt32 {
        case keepAlive
        case disparityFrame
    }
    
    struct DataHeader {
        var magic: UInt32
        var packetLength: UInt32
        var packetType: UInt32
        
        var data: Data {
            get {
                let networkDataHeader = DataHeader(
                    magic: self.magic.bigEndian,
                    packetLength: self.packetLength.bigEndian,
                    packetType: self.packetType.bigEndian)
                var newData = Data()
                withUnsafePointer(to: networkDataHeader) { ptr in
                    ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<DataHeader>.size) {
                        byteBufPtr in
                        newData.append(byteBufPtr, count: MemoryLayout<DataHeader>.size)
                    }
                }
                return newData
            }
            set {
                newValue.withUnsafeBytes { rawBufPtr in
                    let ptrToDataHeader = rawBufPtr.bindMemory(to: DataHeader.self)
                    if let networkDataHeader = ptrToDataHeader.baseAddress?.pointee {
                        self.magic = UInt32(NSSwapBigIntToHost(UInt32(networkDataHeader.magic)))
                        self.packetLength = UInt32(NSSwapBigIntToHost(UInt32(networkDataHeader.packetLength)))
                        self.packetType = UInt32(NSSwapBigIntToHost(UInt32(networkDataHeader.packetType)))
                    }
                }
            }
        }
        
        init(magic: UInt32 = 0x44565321, packetLength: UInt32 = 0, packetType: UInt32 = 0) {
            self.magic = magic
            self.packetLength = packetLength
            self.packetType = packetType
        }
        
        init(magic: UInt32 = 0x44565321, packetLength: UInt32 = 0, packetType: PacketType = .keepAlive) {
            self.magic = magic
            self.packetLength = packetLength
            self.packetType = packetType.rawValue
        }
    }
    
    var dataHeader: DataHeader
    var dataBuffer: Data
    
    init(packetType: PacketType = .keepAlive) {
        dataHeader = DataHeader(packetType: packetType)
        dataBuffer = Data()
    }
    
    func clear() {
        dataBuffer.removeAll(keepingCapacity: true)
    }
    
    var dataLength: Int {
        get {
            return dataBuffer.count
        }
    }
    
    func reserve(_ additionalLength: Int) {
        let newLength = dataLength + additionalLength
        dataBuffer.reserveCapacity(newLength)
    }
    
    func appendData(_ newData: Data) {
        dataBuffer.append(newData)
    }
}

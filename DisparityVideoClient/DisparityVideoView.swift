//
//  DisparityVideoView.swift
//  DisparityVideoClient
//
//  Created by Edward Janne on 3/31/23.
//

import Foundation
import AVFoundation
import SwiftUI

class SampleBufferDisplayLayer: ObservableObject {
    var layer = AVSampleBufferDisplayLayer()
    @Published var updateCount: Int = 0
}

struct DisparityVideoView: NSViewRepresentable {
    
    @ObservedObject var displayLayer: SampleBufferDisplayLayer
    
    func makeNSView(context: Context) -> some NSView {
        let imageView = NSView()
        imageView.wantsLayer = true
        let frame = imageView.frame
        let bounds = imageView.bounds
        
        displayLayer.layer.videoGravity = .resizeAspectFill
        displayLayer.layer.frame = frame
        displayLayer.layer.bounds = bounds
        displayLayer.layer.backgroundColor = CGColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        
        var ctrlTimebase: CMTimebase? = nil
        CMTimebaseCreateWithSourceClock(
            allocator: CFAllocatorGetDefault().takeUnretainedValue(),
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &ctrlTimebase)
        if let ctrlTimebase = ctrlTimebase {
            CMTimebaseSetTime(ctrlTimebase, time: .zero)
            CMTimebaseSetRate(ctrlTimebase, rate: 1.0)
        }
        displayLayer.layer.controlTimebase = ctrlTimebase
        if let layer = imageView.layer {
            layer.addSublayer(displayLayer.layer)
        }
        
        return imageView
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {
        displayLayer.layer.frame = nsView.frame
        displayLayer.layer.bounds = nsView.bounds
        displayLayer.layer.setNeedsLayout()
        displayLayer.layer.setNeedsDisplay()
    }
}


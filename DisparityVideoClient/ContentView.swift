//
//  ContentView.swift
//  DisparityVideoClient
//
//  Created by Edward Janne on 3/17/23.
//

import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var client: Client
    @StateObject var displayLayer = SampleBufferDisplayLayer()
    
    let testData = "This is a test".data(using: .utf8)!
    let formatter = NumberFormatter()
    
    var body: some View {
        ZStack {
            DisparityVideoView(displayLayer: displayLayer)
                .aspectRatio(CGSize(width: 640, height: 400), contentMode: .fit)
                .background(Color(red: 0.0, green: 0.0, blue: 1.0))
            VStack(spacing: 0.0) {
                Spacer()
                HStack(spacing: 0.0) {
                    Text("FPS: \(formatter.string(from: client.fps as NSNumber)!)")
                        .foregroundColor(Color(red: 1.0, green: 1.0, blue: 1.0))
                    Spacer()
                    Button {
                        if client.connected {
                            client.stop()
                        } else {
                            client.startConnection(hostName: "192.168.1.171", port: 8989)
                        }
                    } label: {
                        Text(client.connected ? "Disconnect" : "Connect")
                    }
                }
            }
                .padding(10)
        }
            .padding(0)
            .onAppear {
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 0
                client.onSampleBuffer {
                    sampleBuffer in
                    displayLayer.layer.enqueue(sampleBuffer)
                    DispatchQueue.main.async {
                        displayLayer.updateCount += 1
                    }
                }
            }
    }
}

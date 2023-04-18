//
//  DisparityVideoClientApp.swift
//  DisparityVideoClient
//
//  Created by Edward Janne on 3/17/23.
//

import SwiftUI

@main
struct DisparityVideoClientApp: App {
    
    var body: some Scene {
        WindowGroup {
            ContentView(client: Client())
        }
    }
}

//
//  RoostPortalApp.swift
//  RoostPortal
//
//  Created by Lê Văn Toản on 22/11/26.
//

import SwiftUI

@main
struct RoostPortalApp: App {
    init() { Portal.registerBackgroundSending() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

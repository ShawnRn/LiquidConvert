//
//  UpdaterController.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import Foundation
import Combine
import SwiftUI
import Sparkle

final class UpdaterController: NSObject, ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    
    override init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }
    
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

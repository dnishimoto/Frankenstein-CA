//
//  Frankenstein_CAApp.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/24/26.
//

import SwiftUI
import CoreData

@main
struct Frankenstein_CAApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

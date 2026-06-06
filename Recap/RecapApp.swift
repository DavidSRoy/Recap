import SwiftUI

@main
struct RecapApp: App {
    @State private var model = RecapModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}

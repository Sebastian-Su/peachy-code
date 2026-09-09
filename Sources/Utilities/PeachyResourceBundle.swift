import Foundation

enum PeachyResourceBundle {
    static var current: Bundle {
        #if PEACHY_APP_BUNDLE
        .main
        #else
        .module
        #endif
    }
}

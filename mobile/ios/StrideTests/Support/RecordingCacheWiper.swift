import StrideKit

/// Counts the wipes the app asks for.
actor RecordingCacheWiper: CacheWiping {
    private(set) var wipes = 0

    func wipe() throws(CacheError) {
        wipes += 1
    }
}

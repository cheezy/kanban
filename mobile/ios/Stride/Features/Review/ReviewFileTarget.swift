/// One file of a review to open on the file screen, with the review's file
/// list so the screen can page through the others, and the version of that
/// list, which the file's index points into.
struct ReviewFileTarget: Hashable, Sendable {
    let taskID: Int
    /// The file's index in the stored diffs.
    let index: Int
    let filesVersion: String
    /// The review's files, flagged first, as its Files section lists them.
    let files: [ReviewFileRow]
}

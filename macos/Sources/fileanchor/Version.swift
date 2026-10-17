// The version `fileanchor --version` prints. Consumers build this engine from
// a tag with plain `swift build`, so no build step can stamp it; it is bumped
// in the commit that gets the release tag. fileregister's release script
// compares it with the tag it builds and stops on a mismatch.
let fileanchorVersion = "1.4.0"

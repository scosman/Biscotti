/// Central registry of every manual test script known to the harness.
///
/// CI and the app both use this list as the canonical set; adding a new script here
/// automatically includes it in the CI gate and the app's tab bar.
public let allScripts: [TestScript] = [
    .audioCapture,
    .transcription
]

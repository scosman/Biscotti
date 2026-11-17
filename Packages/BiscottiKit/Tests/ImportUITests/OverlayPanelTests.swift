// OverlayPanel and DropTargetInstallerView placement tests are
// intentionally omitted from the automated suite.
//
// Both involve NSThemeFrame (a private Apple view class). Adding a
// subview to the theme frame produces "NSWindow warning: adding an
// unknown subview" and corrupts internal NSWindow state that persists
// across sequential --no-parallel test runs, causing SIGSEGV in
// unrelated tests that follow.
//
// Similarly, OverlayPanel hosts an NSHostingView whose deferred SwiftUI
// teardown on GCD queues outlives the test and causes SIGSEGV.
//
// The overlay panel sizing (syncFrame, attach) and the installer's
// theme-frame wiring are trivially correct and verified on hardware via
// the Phase 5 manual verification checklist.

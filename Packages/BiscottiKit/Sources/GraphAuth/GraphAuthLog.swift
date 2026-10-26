import os

/// Logger for the GraphAuth module. Keeps the upstream subsystem so the
/// `log` filters in `specs/research/audio/hardware_debugging_workflow.md`
/// still catch it. Tokens, codes and verifiers are never logged.
let graphAuthLog = Logger(subsystem: "net.scosman.biscotti", category: "GraphAuth")

import os

/// Logger for the GraphCalendar module. Keeps the upstream subsystem so the
/// `log` filters in `specs/research/audio/hardware_debugging_workflow.md`
/// still catch it.
let graphCalendarLog = Logger(subsystem: "net.scosman.biscotti", category: "GraphCalendar")

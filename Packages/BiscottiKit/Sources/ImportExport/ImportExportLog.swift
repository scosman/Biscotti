import os

/// Module-wide logger (architecture §8). Only counts and row numbers are
/// logged — never file contents, titles, notes, summaries, or transcripts.
let importExportLog = Logger(subsystem: "net.scosman.biscotti", category: "ImportExport")

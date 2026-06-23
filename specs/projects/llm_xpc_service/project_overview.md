---
status: complete
---

# LLM XPC Service Interface

Scope: the `experiments/llm` directory only — focused, self-contained.

Add a great XPC-style wrapper service interface for the `LocalLLM` library.

## Key goal

Completely reclaim all memory/resources when done with a set of LLM requests. Keeps
the app lightweight and the memory temporary. This lets long-running apps use LLMs
**briefly**, with near-zero long-term memory impact. Also: crashes in the LLM service
don't take down the app.

## Ergonomic API for the client

- Open a connection → the service starts and loads the model.
- Make several LLM requests against the same service (the library has an internal
  serial queue). The model is loaded once, held until close, and never reloaded.
- Close the connection → the process shuts down and all resources are reclaimed.

I love a `with connection { [run several requests, awaiting each response] }`-style
block where the connection auto-closes on scope exit. Not sure if there's a "Swift"
version of that (the example above is Python-ish), but I'd like something like it if it
exists. **Forgetting to close a connection is devastating for system resources** — the
API should be designed to make people use it properly (batching several requests is
fine, but it should always close when done).

## Other requirements

- Should be designed so we can use it from a macOS app and drive **live SwiftUI**,
  both from final results and from streamed results.
- API for both **streaming** and **non-streaming** generation.
- The **CLI** is updated to use the XPC interface.
- The **actual model tests** are updated to use it (but probably share a single
  connection across tests for speed).

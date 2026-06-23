---
status: draft
---

# LLM Model Selection

We want to add the option to select multiple LLMs. Gemma 4 12B QAT is great, but requires
8-9GB RAM, and is quite slow on M1/M2 Macs.

We should smart-suggest an appropriate model:
- If >=24GB RAM, and M3+ processor, default to Gemma 4 12B QAT (current).
- Otherwise use Gemma 4 E2B.

Notes:
- Fully disallow the 12B model on 8GB RAM machines. It won't run. Don't show it as an option.
- Both are Gemma 4, so should share the same tokens/structure for messages.

New model URL:
`https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf`

## UI

- In settings, our "Download Model" row which currently hides becomes a permanent row, always shown.
  - Title: "AI Language Model"
  - Subtitle: "The AI model used to summarize meetings"
  - If a model is downloaded and selected, show its name in grey text like we do for other
    approved permissions ("Gemma 4 12B" or "Gemma 4 E2B"), and a "Manage" button which opens the
    manage-model sheet.
  - If no model is downloaded, show a "Download…" button which opens the manage-model sheet.
- Manage models sheet
  - A sheet that lets you download models and pick the default.
  - Sheet UI lists models in rows.
    - Model name
    - Description
    - "Download" button if not downloaded, or "Delete" if downloaded.
    - "Default" label if selected, or "Choose model" button if downloaded and not selected.
    - "Recommended" badge on the recommended one (see logic above).
  - Example:
    - Gemma 4 12B
      - Intelligent, but slower and larger. Requires 7GB of disk and uses 8GB RAM.
    - Gemma 4 E2B
      - Small and fast, but not as intelligent. Requires 3GB of disk and uses 4GB of RAM.
  - Save their selected model to a setting.
  - Disable the 12B model on Intel Macs, or if they have <15GB RAM. Grey it out, with the warning
    "This Mac can't run this model".
  - Disable Download of either if free disk space is lower than how much it needs (with an
    "Insufficient free space on disk" warning message).
  - Design with the idea we may add more models over time (two for now, but that's temporary).
- LLM library
  - Might need to add an API to list downloaded models. Can be in-process, not XPC.

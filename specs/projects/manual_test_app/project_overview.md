### Manual Test Plans/Apps

Some things just can't be unit tested. Does settings show X after approving Y? Does the audio recording work when airpods are connected mid stream. Is the audio quality okay. Mostly things involving hardware, external factors, and system APIs.

To make our system work well, we want a test plan for these usually hard to test things.

 - Put the hard thing in a swift package under a really tight API, defining what the app needs
 - A manual test app with tabs: one for each libary. Each tab has the test-plan for the library actually coded in an interactive form. Example sintge test for Audio Capture:
   - click this button to requests permissions
   - Alert: did you see two permission dialogs for mic and system audio?
   - Instruction: Speak and play system audio for next 15 seconds
   - Automated check: checks 2 files created in right place on disk, size reasonable
   - Instruction: play these two files (opens finder or play buttons). Question: did the mic stream capture your voice? Did the system stream capture system audio? Was audio quality acceptable?
 - The app saves pass/fail/not-run into plist in the repo. 
 - Our CLAUDE.md is updated to say "make impacted tests as unrun when touching these libaries..." that way the coding agent can mark manual tests as needs review
 - CI checks all tests are marked as run in plist/json (it can't run the tests, it can checked we did)
---
status: complete
---

# Meetings: 3-Pane Layout

Move to a 3-pane app layout, within just a new "Meetings" screen of the app.

Currently the list of meetings lives in the sidebar. This isn't great. The sidebar is collapsible,
and the meetings list competes for space with other items (an infinite list inside a fixed list is
not great), and can't render search without duplicating the list.

We want to move to a more Apple-like solution, like the Notes or Mail apps: an additional bar,
dedicated to the list.

## The new "Meetings" screen (two bars)

When I open a specific meeting, search, or "All meetings", I get a new "Meetings" main content
screen with two bars. This is a new screen with 2 bars:

- **Left bar:** a list of all meetings. Like Mail has for email or the Notes app has for notes.
  - Date-based sticky headers using Apple-native controls: Today, Yesterday, Last Week, Month
    titles (this year), year titles for last year and before.
  - Doesn't collapse like the sidebar — always visible when on this screen.
  - Is only present when on the "Meetings" screen of the app. Not an app-wide extra column.
- **Right pane:** the meeting area. Renders the single-meeting details screen we currently show for
  meetings (or a "No Meeting Selected" placeholder like Mail when none is selected).
- **Resizeable:** can drag the divider between them.

## Current Sidebar (the far-left sidebar that exists app-wide) needs an update

This is *not* the new left bar in the Meetings layout — it's the existing far-left sidebar.

- Remove the list of past meetings there. Just a "Past Meetings" option under Home, which opens the
  new "Meetings" screen and reveals the full list.

## Search: now works inside the left bar; remove the dedicated search screen

- When I type in search: 1) jump to the "Meetings" screen, and 2) show filtered search results in
  the left bar.
- TBD if we auto-render the top result in the right pane (Notes) or "No Meeting Selected" (Mail).
  Start with auto-rendering the top search result.
- Clearing the search box restores the list to all.
- Note: we may want to use the existing search screen as the starting point of the left-bar list.
  It's got a lot of overlap. It's a mix of the search code and the sidebar list code (which has the
  date dividers).

## App layout

- Add a Home icon in the top bar, which takes you Home. The Home page is partly built, but lets you
  navigate anywhere, so this makes the full app functional with the sidebar collapsed.
  - Looking at other apps, this should be in the top bar (between the collapse-sidebar icon and
    search) on the main window section. Right where "Biscotti" (the app name) is — remove that.

## Homepage

- Add a "See all" button to the Recent Meetings section.

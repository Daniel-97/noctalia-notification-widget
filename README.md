# Missed Notifications

Noctalia v5 plugin (Luau). Desktop/lockscreen widget that lists **unread
notifications**: everything received since the list was last cleared.

## How it works

- `service.luau` (`[[service]]`, headless) eavesdrops every
  `org.freedesktop.Notifications.Notify` call with `dbus-monitor`: app name,
  summary and body are captured no matter the session state (locked or not).
- Consecutive notifications with the same app and summary update the last
  entry instead of piling up (chat apps resending).
- The list is **persisted** in the plugin data dir (`items.json`): it
  survives service restarts — plugin hot-reloads, settings changes (the
  service is restarted when a plugin setting is edited) — and shell
  restarts.
- The list is cleared when:
  - the **control center is opened** — in the "unread" list mode only; the
    closest externally observable event to Noctalia's own "notifications tab
    opened" read marker (poll via `noctalia msg status` every 2 s; the tab
    itself is not distinguishable over IPC). The "all" list mode never
    auto-clears.
  - the **widget is clicked** (control channel).
- `widget.luau` (`[[desktop_widget]]`) renders the list: a bell header with
  the count, then one line per notification with its **relative age**
  ("3 minuti fa", "2 ore fa"...) next to the summary, refreshed on every
  render (~5 s). Hidden when the list is empty.

## Settings

| Setting                | Type   | Default  | Description                                        |
| ---------------------- | ------ | -------- | -------------------------------------------------- |
| `max_items`            | int    | 6        | Max notifications listed (stored cap is 30)        |
| `text_scale`           | select | "1.3"    | Content size (100%–200%)                           |
| `show_body`            | bool   | false    | Show the body under each summary line              |
| `list_mode`            | select | "unread" | Unread only (clears when the control center opens) or All (rolling recap, click to empty) |
| `language`             | select | "auto"   | Widget texts language: auto (system locale), English, Italiano |

## Requirements

`dbus-monitor` (dbus tools) on `PATH`.

## Install (local dev source)

```
noctalia msg plugins source add missed-dev path ~/Projects/daniel-97/noctalia-plugins-dev
noctalia msg plugins enable dan/missed-notifications
```

Then add the widget from the lockscreen (or desktop) widget editor.

## Known limitations (v0.2)

- Noctalia v5 keeps its notification history encrypted with no public
  unread API, so this is an eavesdrop-based approximation: "received since
  the list was last cleared", not the shell's exact unread model.
- The read marker is the control center opening, not the notifications tab
  specifically (the tab is not distinguishable over IPC).
- No replaces-id correlation: notifications withdrawn by the sending app
  (read in the app itself) are not removed from the list.
- If `dbus-monitor` dies silently the stream is not restarted automatically.

## Layout note: keep the box auto-fit

Leave the widget's `box_width` and `box_height` at `0.0` (auto-fit). A fixed
box set from the editor makes Noctalia **rescale the content to fill it**, so
the text size changes with the amount of content (few notifications = bigger
text, many = smaller). With auto-fit the box follows the content and text
stays at the configured size; only the footprint changes.

## Test

```
notify-send "Test" "unread entry"   # appears in the widget
noctalia msg panel-open control-center   # clears the list within ~2 s
```

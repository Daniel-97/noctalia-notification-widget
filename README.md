# Lockscreen Notification Widget

A Noctalia v5 plugin that lists unread notifications on the lock screen
(and optionally the desktop): everything received since the list was last
cleared, with app icons and relative ages. Each notification renders as a
rounded card over the lock backdrop.

## Plugin

| Field | Value |
| --- | --- |
| ID | `daniel-97/missed-notifications` |
| Entries | Service: `watcher`; desktop widget: `widget` |

## Requirements

Install `dbus-monitor` (dbus tools) and `pgrep` (procps) on `PATH`.

## Usage

Run as a local source while developing:

```sh
noctalia msg plugins source add missed-dev path <this repo's parent>
noctalia msg plugins enable daniel-97/missed-notifications
```

Then add the widget from the lockscreen widget editor
(`noctalia msg lockscreen-widgets-edit`) — or the desktop editor
(`noctalia msg desktop-widgets-edit`) — by picking **Lockscreen
Notification Widget** in the add-widget list and placing it like any other
widget.

- While locked, the list shows notifications received and not yet
  acknowledged.
- In unread mode the list empties when the control center is opened (the
  closest observable event to Noctalia's own read marker) or when the
  widget is clicked.
- In all mode the list is a rolling recap of the last 30 notifications and
  only empties on click.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `max_items` | int | 6 | Max notifications listed (in-memory cap is 30) |
| `text_scale` | select | "1.3" | Content size: 100%–200% |
| `show_body` | bool | false | Show the body under each summary line |
| `list_mode` | select | "unread" | Unread only (clears when the control center opens) or all (rolling recap, click to empty) |
| `language` | select | "auto" | Widget texts language: auto (system locale), English, Italiano |
| `order` | select | "newest" | Newest notifications at the top, or arrival order |
| `age_format` | select | "relative" | Age as relative ("2 hours ago"), absolute ("18:42"), or both joined by a middle dot |
| `max_age_hours` | int | 24 | Entries older than this many hours leave the list on their own; 0 keeps them forever |
| `hide_when_empty` | bool | false | Hide the widget entirely instead of showing the empty state |

## Notes

- Notifications are captured by eavesdropping
  `org.freedesktop.Notifications.Notify` calls with a spawned
  `dbus-monitor` process, respawned automatically if it dies (checked
  with `pgrep` every 30 s). Noctalia v5 keeps its own history encrypted
  with no public unread API, so this is an approximation: "received since
  the list was last cleared", not the shell's exact unread model.
- The list is memory-only by design: notification content (bodies,
  contact names) never touches the disk, so service restarts (plugin
  reloads, settings changes) start from an empty list. Privacy over
  continuity.
- App icons are resolved through `noctalia.appIconPath` (desktop-entry
  hint, then the notification's `app_icon`, then the app name); unknown
  senders get a generic glyph.
- Consecutive notifications with the same app and summary are grouped
  into one entry with an occurrence count (`(2)`, `(3)`...) and the
  latest body, wherever the older entry sits in the list; a grouped
  entry is renewed at the newest position.
- Leave the widget box auto-fit (`box_width`/`box_height` `0.0`): a fixed
  box set from the editor makes the host rescale the content, so text size
  varies with the amount of content.
- Notifications withdrawn by their sending app (read in the app itself,
  like chat apps marking as read) leave the list: the daemon-assigned ids
  are correlated through captured method returns, and `NotificationClosed`
  signals with reason 3 remove the matching entry — every occurrence of
  the id at once, since replaced notifications (`replaces_id`) carry
  several messages under one id. Expired or user-dismissed toasts stay,
  matching Noctalia's own unread model.
- A withdrawal can only be seen while its toast is still alive: once the
  toast expires, the daemon drops the id (a later `CloseNotification`
  returns `NotFound` and no signal follows), so a message read in the app
  after its toast expired keeps its entry until the list is cleared. This
  is a property of the D-Bus notification lifecycle, not of the plugin.
- Transient notifications (marked so by their own app — media-player
  track changes, OSDs) are not captured: the app itself declared them
  ephemeral, so they never enter the list.
# Lockscreen Notification Widget

A Noctalia v5 plugin that lists unread notifications on the lock screen
(and optionally the desktop): everything received since the list was last
cleared, with app icons and relative ages. Each notification renders as a
rounded card over the lock backdrop.

## Plugin

| Field | Value |
| --- | --- |
| ID | `daniel-97/lockscreen-notifications` |
| Entries | Service: `watcher`; desktop widget: `widget` |

## Requirements

Install `dbus-monitor` (dbus tools) and `pgrep` (procps) on `PATH`.

## Usage

Install **Lockscreen Notification Widget** from the Noctalia plugin store
(Settings → Plugins) and enable it. The `watcher` service starts with the
plugin and begins collecting notifications.

Then add the widget from the lockscreen editor:

```sh
noctalia msg lockscreen-widgets-edit
```

or from the desktop editor (`noctalia msg desktop-widgets-edit`), by picking
**Lockscreen Notification Widget** in the add-widget list and placing it like
any other widget.

- While locked, the list shows notifications received and not yet
  acknowledged.
- The list empties when the control center is opened (the closest
  observable event to Noctalia's own read marker).

## Settings

The plugin settings UI has no section primitive, so the manifest order is what groups the controls; the less common options sit behind **Show advanced**.

### Display

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `max_items` | int | 6 | Max notifications listed (in-memory cap is 30) |
| `show_body` | bool | false | Show the body under each summary line |
| `show_icons` | bool | true | Show the sender icon or the app-provided image |
| `show_age` | bool | true | Show the age on the right of each card |
| `summary_length` | select | "normal" | Title truncation (40/60/90 chars) and fixed widget width (≈364/442/520 px at 130%) |
| `card_background` | select | "subtle" | Card look: subtle tint, solid surface, liquid glass (translucent frosted fill with a bright rim), or no background |

### Behaviour

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `group_notifications` | bool | true | Merge same app + title into one card with a count badge; off gives each notification its own card |
| `order` | select | "newest" | Newest notifications at the top, or arrival order |
| `language` | select | "auto" | Widget texts language: auto (system locale), English, Italiano |

### Advanced

These are hidden behind **Show advanced** in the plugin settings.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `age_format` | select | "relative" | Age as relative ("2 hours ago"), absolute ("18:42"), or both. Only visible when `show_age` is on |
| `preview_when_empty` | bool | false | Show invented example cards equal to `max_items` when the list is empty; the first card explains the setting. Stays until disabled |

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
  senders get a generic glyph. Apps that send an `image-path` hint get
  their own image as the leading image of the card. Inline `image-data`
  images (Signal sends the chat avatar that way) cannot be decoded in
  the plugin sandbox — no image encoder is available to plugins.
- Consecutive notifications with the same app and summary are grouped
  into one entry with an occurrence count (`(2)`, `(3)`...) and the
  latest body, wherever the older entry sits in the list; a grouped
  entry is renewed at the newest position.
- The card width follows the title-length setting (short/normal/long),
  which keeps long titles from widening the widget. The height stays
  dynamic so the lockscreen repaints fully; keep `box_height` auto-fit
  (`0.0`) for that, since a fixed height can bring back partial repaints.
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

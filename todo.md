1. If the user has 'live' only mode without a buffer, still allow use of the pause button/hotkey by auto-enabling a buffer so they can resume from that spot when they return. The user might not have a buffer session enabled but then might find the need to pause for whatever reason, this will allow that.
2. Change the "Settings" button to Icon only, remove the text from that button otherwise leave as-is. One improvement would be to make it more obvious when the settings panel is open/active, we need to have a stronger indicator that clicking the settings button again will collapse the section and return to the main player screen
3. Explore the possibility of setting up recordings - this would probably require its own sub-screen to both setup recording times and to review existing recorded sessions. For example, I might want to record 'wbz-fm' from 14:00 to 14:20 on Fridays when they air a specific segment. Bonus if we can set multiple records and perform them in the background if we are playing a completely different station in the foreground. This is a pretty big feature so scope it out and then let's discuss before implementing. 
4. In the settings section we also probably want to allow the ability to add a new channel if we have not previously included it in our stock list. This should save on the user side and persist so they can use their own channels if they have them.
5. Add the ability to heart/pin favorite stations to the top of the station search list. This will be useful for navigation as our available stations list grows

## Delivery status

- [x] Icon-only Settings control with an active indicator — `70c0724`.
- [x] Pause from Live only using a temporary 15-minute session buffer — `20497b0`. The saved preference stays unchanged; mpv prepares a bounded RAM cache at startup to preserve the connection when pausing.
- [x] Persistent custom stations with add, edit, delete and default CLI support — `688fc38`.
- [x] Favorite stations with persistent hearts and favorites-first search results — `55a6b84`.
- [x] Scheduled recordings — discussed and implemented: 24 kbit/s mono Opus, default `~/Music/Yakker`, editable folder/cap, independent overlapping captures, native schedule/library controls and retained-file playback. [Design](docs/recordings-plan.md) · [Validation](docs/recordings-validation.md).

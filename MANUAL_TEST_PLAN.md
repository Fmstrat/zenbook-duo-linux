# Manual test plan — `fix/startup-state-detection`

Run these by hand on the laptop after installing this branch. Not committed
as part of the PR — delete this file (or leave it out of `git add`) once
you're done, unless you decide you want it in the tree.

## Setup

1. Check out the branch and install:
   ```bash
   git checkout fix/startup-state-detection
   ./setup.sh
   ```
2. Keep a log open in a second terminal for the whole session:
   ```bash
   tail -f /tmp/duo/duo.log
   ```
3. To inspect persisted state at any point:
   ```bash
   cat /tmp/duo/status
   ```
4. To force a re-check without waiting on a real event (useful between
   physical steps below), run as your normal user:
   ```bash
   /usr/local/bin/duo post
   ```
   This re-runs the same `duo-check-monitor` path that boot/resume/keyboard
   events trigger — it does **not** fake a keyboard or monitor change, it
   just re-evaluates current physical state against `/tmp/duo/status`.

Do the tests roughly in this order — 1–3 are what this branch actually
changes and matter most; 4+ are regression checks on everything the README
already lists as working, to make sure nothing else broke.

---

## 1. Wifi/Bluetooth "before" state persists across the session (core fix)

This is the main bug: previously the script re-read live wifi/bluetooth
state on *every single invocation* (every rotate event, every keyboard
event) and overwrote the saved "before" value with it — so the "restore to
what it was before you removed the keyboard" feature only ever worked by
accident.

**Steps:**
1. With the keyboard attached, turn Bluetooth **off** manually (via GNOME
   settings or `rfkill block bluetooth`).
2. Detach the keyboard. Bluetooth should turn back **on** (per the
   documented "always on with keyboard removed" behavior) — check
   `duo.log` for `NETWORK - Bluetooth: blocked` logged around the
   detach.
3. While the keyboard is still detached, trigger a few unrelated
   invocations — rotate the screen a couple of times, or run
   `/usr/local/bin/duo post` two or three times.
4. Check `cat /tmp/duo/status` after each — `BLUETOOTH_BEFORE` should
   stay `blocked` the whole time.
5. Reattach the keyboard.

**Expected now:** Bluetooth turns back **off** on reattach (matches what
you set it to in step 1), because `BLUETOOTH_BEFORE=blocked` survived
steps 3–4 untouched.

**Previous (buggy) behavior:** any of the intermediate invocations in
step 3 could have silently re-polled live Bluetooth state and overwritten
`BLUETOOTH_BEFORE` — so Bluetooth on reattach was unpredictable, not
necessarily what you'd turned it off to before detaching.

Repeat the same sequence for Wifi (`nmcli radio wifi off` before detach,
check `WIFI_BEFORE` stays `disabled` through intermediate events).

---

## 2. External monitor is no longer wiped out (fixes upstream issue #4)

**Steps:**
1. With the keyboard attached (bottom panel should be off) and no
   external monitor, plug in an external monitor via DP/HDMI.
2. Watch `duo.log`.

**Expected now:** log line `MONITOR - External monitor detected
(DP-1)` (or `HDMI-1`, etc. — whatever `gdctl show` reports) followed by
`skipping display auto-toggle`. No `gdctl set` call happens; your external
monitor's layout/position is left exactly as GNOME had it. Detach/reattach
the keyboard a few times while the external monitor stays connected —
same skip behavior every time.

**Previous (buggy) behavior:** the script counted *all* logical monitors,
saw the count go above 1, and ran `gdctl set --logical-monitor --primary
... --monitor eDP-1`, which is a full atomic replace — it would tear down
your external monitor's configuration entirely, not just fold the internal
bottom screen.

3. Unplug the external monitor and confirm normal fold/unfold behavior
   (test 4 below) still works exactly as before — the fix should be a
   no-op when no external monitor is present.

4. **Regression check on the fix itself:** the internal panels are named
   `eDP-1`/`eDP-2`. Confirm that with *only* the internal panels active
   (no external monitor), the log never prints the "External monitor
   detected" line — i.e. `eDP-1`/`eDP-2` aren't being misdetected as an
   external `DP-1` connector. (This was a bug I caught and fixed before
   committing — worth confirming on real `gdctl show` output since I
   couldn't test it without hardware.) You can sanity-check what your
   hardware's connector names look like with:
   ```bash
   gdctl show
   ```

---

## 3. Dead code removal (`duo-watch-lock`)

Nothing to test directly — this function was never called anywhere in the
script. There's no behavior change to observe here; it's covered
implicitly by everything else in this plan still working (screen lock/
unlock during your testing session shouldn't affect Bluetooth state at
all, before or after this change).

---

## 4. Regression checks — existing functionality (README table)

For each, note **expected now** vs **previous expected** — for these,
"previous" is just "same as now," since this branch didn't touch this
logic. Flag anything that behaves differently as a possible new
regression from the state-persistence or monitor changes above.

| # | Test | Steps | Expected (now = previous) |
|---|------|-------|----------------------------|
| 4.1 | Bottom screen off on keyboard attach | Attach keyboard, no external monitor | Bottom panel (`eDP-2`) turns off; log shows `Disabling bottom monitor` / `Disabled bottom display` notification |
| 4.2 | Bottom screen on on keyboard detach | Detach keyboard, no external monitor | Bottom panel turns on; log shows `Enabling bottom monitor` / `Enabled bottom display` notification |
| 4.3 | Bluetooth on keyboard detach | Detach keyboard | Bluetooth unblocks regardless of prior state |
| 4.4 | Bluetooth restore on reattach | Reattach keyboard | Bluetooth returns to whatever `BLUETOOTH_BEFORE` was (see test 1) |
| 4.5 | Wifi reset (airplane-mode bug workaround) | Detach/reattach with wifi radio toggled | Wifi ends up matching `WIFI_BEFORE` on reattach |
| 4.6 | Screen brightness sync | Adjust internal panel brightness (keyboard detached) | Bottom panel brightness follows within ~1s |
| 4.7 | Keyboard backlight on boot | Reboot | Backlight sets to `DEFAULT_BACKLIGHT` from `duo.sh` |
| 4.8 | Keyboard backlight on keyboard placed | Reattach keyboard | Backlight resets to `DEFAULT_BACKLIGHT` |
| 4.9 | Correct state on boot | Full reboot | `/tmp/duo/status` is freshly bootstrapped from live wifi/BT state (should NOT carry over stale values from before shutdown, since `/tmp` is tmpfs and clears on reboot) |
| 4.10 | Correct state on resume | Suspend, then resume (also: attach/detach the keyboard while suspended) | Monitor/keyboard/wifi/BT state re-evaluated correctly post-resume; log shows `SESSION - Resumed, rechecking monitor state` (now done by `duo-watch-resume` in the user service, not the root sleep hook) |
| 4.10a | No suspend/resume delay | Close lid, wait ~10s, open lid | Desktop returns within a few seconds. `journalctl -b` shows `Starting systemd-suspend` → `PM: suspend entry` within ~2s, and `PM: suspend exit` → `user.slice: Unit now thawed` within ~2s (previously 90s each, caused by the sleep hook hanging on xrandr) |
| 4.11 | Auto rotation | Rotate the physical chassis | Screen orientation follows. **Not touched by this branch** — if this was already broken before, it'll still be broken; that's a separate, pre-existing issue (likely `iio-sensor-proxy`/`monitor-sensor`, not `duo.sh` logic) and out of scope here unless you want to dig into it separately. |
| 4.12 | Login screen: works, without permission errors | Log out. At the login screen, detach and reattach the keyboard and rotate the laptop, then log in and run `journalctl -b --since '-10min' _SYSTEMD_USER_UNIT=zenbook-duo-user.service \| grep -E "sorry\|Not authorized\|Failed to show"` | Bottom panel and rotation follow the keyboard/chassis at the login screen. The greeter instance logs `SESSION - Login screen instance: ... skipped`. The grep finds nothing (previously: `sudo: I'm sorry gdm-greeter`, `Failed to show notification`, and `Wi-Fi radio: Not authorized` when the keyboard changed just after login) |

---

## If everything above passes

Commit is already done (`564f620`). Next step is pushing the branch to
your fork and opening the PR — say the word when you're ready and I'll
walk through that (you'll want to review/run `git push` yourself per your
root/remote-action preference, or I can do it if you'd rather hand that
off — your call).

# Manual test plan — MATE desktop support (`fix/accelerometer-rotation`)

Run these by hand on the laptop after installing this branch. Not committed
as part of the PR — delete this file (or leave it out of `git add`) once
you're done, unless you decide you want it in the tree.

This is a separate document from `MANUAL_TEST_PLAN.md` (which covers an
unrelated, older piece of work) — don't confuse the two.

## What changed

`duo.sh` used to drive the displays exclusively through `gdctl`
(GNOME/Mutter's CLI), which doesn't exist under MATE. It now picks a
backend at runtime — `gdctl` if available, otherwise `xrandr` — by probing
capability rather than trusting `$XDG_CURRENT_DESKTOP`, and re-detects on
every invocation so switching desktop environments at the login screen
needs no reconfiguration. `setup.sh` no longer hardcodes
`Environment=XDG_CURRENT_DESKTOP=GNOME` into the systemd user unit, and now
also installs `x11-xserver-utils` (for `xrandr`).

The rotation-direction mapping and the assumption that xrandr enumerates
the panels as `eDP-1`/`eDP-2` (same as gdctl) are both **derived from
protocol docs, not measured on this hardware** — sections 2 and 4 below are
the load-bearing tests that confirm or correct those assumptions.

## Setup

1. Check out the branch and (re)install — this needs to be run once,
   regardless of which desktop session you run it from, since it only
   writes files and packages:
   ```bash
   git checkout fix/accelerometer-rotation
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
4. To force a re-check without waiting on a real event, run as your normal
   user:
   ```bash
   /usr/local/bin/duo post
   ```
5. To switch desktop environments: log out, and at the login screen use the
   gear/session-picker icon to choose **MATE** (or back to **Ubuntu**/GNOME
   for the regression pass in section 6).

Do the tests roughly in this order — 1–2 validate the assumptions
everything else rests on; 3–5 exercise the actual feature under MATE; 6 is
the regression check making sure the still-stable GNOME path wasn't broken.

---

## 1. Backend auto-detection under MATE (core test)

**Steps:**
1. Log into MATE (see Setup step 5).
2. Optionally, sanity-check the probe by hand first:
   ```bash
   time gdctl show; echo $?
   ```
   **Expected:** fails quickly (well under a second) with a non-zero exit
   code — confirms the probe won't stall the watcher loop.
3. Restart the user service so it re-detects fresh, and watch the log:
   ```bash
   systemctl --user restart zenbook-duo-user.service
   ```

**Expected:** `duo.log` shows a line like:
```
BACKEND - Selected: xrandr (primary=eDP-1 secondary=eDP-2)
```
(the exact output names may differ — that's what test 2 confirms). If it
instead says `Selected: gdctl`, the probe misdetected MATE as having a
working GNOME/Mutter session — stop and investigate before continuing.

---

## 2. Output name discovery

**Steps:**
1. Compare what xrandr reports against what the backend log line picked:
   ```bash
   xrandr --query | grep -i edp
   xrandr --listactivemonitors
   ```

**Expected:** the `eDP*` connector names here match `primary=`/`secondary=`
in the backend log line from test 1. If the names *don't* match `eDP-1`/
`eDP-2` (e.g. `eDP1` without a dash, or a different order), that's fine —
discovery is dynamic — but note the actual names here for reference, since
they'll show up in every subsequent log line.

---

## 3. Panel toggle under MATE (keyboard attach/detach)

**Steps:**
1. With the keyboard **attached**, confirm only one panel is active
   (`xrandr --listactivemonitors` should show 1).
2. Detach the keyboard.

**Expected:** log shows `MONITOR - Enabling bottom monitor` /
`Enabled bottom display` notification, and the bottom panel lights up,
positioned below the primary — same physical result as under GNOME, just
driven by `xrandr` this time.

3. Reattach the keyboard.

**Expected:** log shows `Disabling bottom monitor` / `Disabled bottom
display`, bottom panel turns off.

---

## 4. Rotation mapping under MATE (load-bearing — unmeasured until now)

The mapping between `duo.sh`'s rotate commands and xrandr's `--rotate`
values was derived from protocol semantics (xrandr's `right` = clockwise),
not measured. This is the test that confirms it's actually right:

| Command | Expected physical result |
|---|---|
| `/usr/local/bin/duo left-up` | Chassis's left edge becomes the top |
| `/usr/local/bin/duo right-up` | Chassis's right edge becomes the top |
| `/usr/local/bin/duo bottom-up` | Upside-down |
| `/usr/local/bin/duo normal` | Back to normal orientation |

**Steps:**
1. With the keyboard **attached** (single panel), run each of the four
   commands above in order and confirm the primary panel's orientation
   visually matches the table.
2. Detach the keyboard (dual panel) and repeat all four — confirm both
   panels rotate together and the secondary stays correctly positioned
   (left-of/right-of/above/below) relative to the primary at each
   orientation.
3. If any orientation is wrong (e.g. `left-up` actually rotates right),
   note which ones — the fix is a small change to the transform word passed
   to `duo-set-monitors-single`/`duo-set-monitors-dual` at the relevant
   `duo-cli` rotate case in `duo.sh`. Report back which cases were wrong
   and I'll correct the mapping.

---

## 5. End-to-end accelerometer rotation under MATE

**Steps:**
1. Physically fold/rotate the device through a couple of orientations.

**Expected:** `monitor-sensor --accel` → `duo-watch-rotate` → `duo-cli`
drives the correct orientation automatically, matching whatever you
confirmed by hand in test 4. This exercises `iio-sensor-proxy`, which is
desktop-agnostic and shouldn't be affected by this branch, but confirms the
whole chain works under MATE.

---

## 6. Scale setting is ignored under MATE (expected, not a bug)

**Steps:**
1. Check `DEFAULT_SCALE` in `/usr/local/bin/duo` (set during `setup.sh`).
   If it's `1`, this test won't show anything different — that's fine,
   just confirm no error appears.
2. If you want to exercise the ignore-path directly, temporarily edit
   `DEFAULT_SCALE=2` in the installed script and re-trigger a monitor
   toggle (test 3) — confirm no error, and the panel comes up at native
   resolution (scale simply isn't applied under xrandr).
3. Separately, confirm MATE's own scaling knob works independently of
   `duo.sh`:
   ```bash
   gsettings set org.mate.interface window-scaling-factor 2
   ```

---

## 7. `DISPLAY` propagation into the systemd `--user` session

**Steps:**
1. ```bash
   systemctl --user show-environment | grep -E 'DISPLAY|XAUTHORITY'
   ```

**Expected:** `DISPLAY` is present (likely `:0` or `:1`). If it's missing,
`duo.sh`'s `[ -z "${DISPLAY}" ] && export DISPLAY=:0` fallback should still
have made `xrandr` work in tests 1–5 above — if those tests passed, this
one is just confirming *why* it worked, not a separate pass/fail gate.

---

## 8. Regression check — back on GNOME

**Steps:**
1. Log out of MATE, log back into GNOME/Ubuntu — no config changes, no
   re-running `setup.sh`.
2. Tail `duo.log` after login.

**Expected:** `BACKEND - Selected: gdctl (primary=eDP-1 secondary=eDP-2)`,
and everything in the README's functionality table (panel toggle,
rotation, backlight, wifi/BT restore) behaves exactly as it did before this
branch — this is the check that the abstraction didn't quietly change
anything on the path that was already stable.

3. Also sanity-check the boot/shutdown and suspend/resume paths: power
   events (`pre`/`post`/`hibernate`/`thaw`/`boot`/`shutdown`) run as root
   outside the graphical session and now skip all gdctl/xrandr calls.
   (They used to probe the display, which didn't fail gracefully during
   suspend: the session is frozen, so xrandr on `:0` hung until systemd
   killed the hook after 90s, on both lid close and lid open.) Close the
   lid, wait ~10s, open it, and confirm:
   - `journalctl -b | grep -E 'Starting systemd-suspend|PM: suspend entry'`
     shows the two lines within a couple of seconds of each other, not 90s;
   - `duo.log` has an `ACPI - pre suspend` and `ACPI - post suspend` pair
     with no `BACKEND - Selected` line between them;
   - `duo.log` then shows `SESSION - Resumed, rechecking monitor state`
     (from `duo-watch-resume`), under both MATE and GNOME. On MATE this is
     the only post-resume re-check, because mate-screensaver doesn't set
     logind's `LockedHint`, so `duo-watch-lock` never fires there.

---

## If everything above passes

Let me know which (if any) of the rotation mappings in test 4 needed
correcting, and whether the output names in test 2 matched `eDP-1`/
`eDP-2`. Once confirmed, this is ready to commit — say the word.

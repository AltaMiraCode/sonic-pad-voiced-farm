#!/usr/bin/env python3
"""
sonicpad-chimes - print-event sounds + voice for all four printers, plus a
System PA voice (Omega's) for farm-wide alerts.

Audio model:
  - CHIMES are fire-and-forget: they overlap voices and each other freely.
  - VOICES go through an ordered queue (default): no overlap. Voices arriving
    close together are grouped by event type; each group plays in fleet order
    Omega->Unicorn->Dimeter->Trident, and groups play in the order they began.
    An identical voice already queued or just played is dropped. The
    VOICE_STACKING toggle (~/.voice_stacking) switches voices to overlapping.
  - THERMAL warnings jump the whole queue: they cut the gather window short
    and sort ahead of everything pending, no matter what is queued.
  - MILESTONES: 50% keeps the classic "{name} print halfway" voice; 75, 90
    and 95 percent announce progress + estimated time remaining (espeak,
    since the time is computed live). Suppressed by the narration toggle.
  - ACTIVE SET is automatic: a printer is silent until it first connects
    ("checks in"). Printers you're not using - powered off, not connected -
    never check in and so never make a sound. When one connects it roll-calls
    itself online; only printers that have checked in can later announce.
  - OFFLINE/ONLINE: when a checked-in printer disconnects it announces
    "offline" right away, and "back online" whenever it returns. A restart
    naturally plays both a few seconds apart; a real drop plays "offline"
    now and "back online" when it actually comes back. No guessing which.
    POWER-OFF: klippy's shutdown from lost MCU contact while idle announces
    "{name} powering off" then "{name} offline". While it's down the daemon
    nudges klippy with a firmware_restart (RECOVER_NUDGE), so powering the
    printer back on yields "back online" automatically (and lets klipper
    reconfigure the board, which is also what turns the LED back on).
  - ROLL-CALL is honest: at first contact the daemon checks klippy's real
    state. A printer sitting in shutdown/error checks in silently rather
    than claiming "online", and speaks "back online" only when truly up.
  - Thermal/heating faults are urgent: announced immediately, and they
    force through the master mute. Lost MCU contact MID-PRINT is also
    treated as an error - a board dying during a print is worth hearing.
All audio is local to the pad, so network alerts can be spoken while offline.

Requires: python3-websockets, espeak-ng, ~/voicebank, play_chime.sh, say.sh.
"""
import asyncio, glob, json, os, random, subprocess, time, urllib.request

PRINTERS = {7125: "Unicorn", 7126: "Dimeter", 7127: "Trident", 7128: "Omega"}
# prewired expansion - uncomment when the instances exist (see ADD-A-PRINTER.md):
# PRINTERS[7129] = "Tesseract"
# PRINTERS[7130] = "Pentagram"
# PRINTERS[7131] = "Sestina"
# PRINTERS[7132] = "Hydra"
CHIME_DIR = os.path.expanduser("~/chimes")
PLAYER = os.path.expanduser("~/play_chime.sh")
SPEAKER = os.path.expanduser("~/say.sh")
VOICE_LOCK = "/tmp/.voice_lock"     # same lock say.sh flocks - serializes the
                                    # print-start chime against voices

VOICE = True
DEDUP_WINDOW = 1.5
COLLECT_WINDOW = 3.0       # seconds to gather voices into one batch before the drain
                           # starts; wider = better chance a whole fleet wave lands
                           # together. Ordering inside the drain is handled by the
                           # group-aware sort, so this only affects wave capture.
_last_played = {}          # chime dedup: event -> last time
FIRST_LAYER_Z = 0.6        # "first layer complete" fires when Z rises past this...
FIRST_LAYER_LOW = 0.45     # ...but only after Z has stayed at/below this...
FIRST_LAYER_DWELL = 30.0   # ...continuously for this many seconds (actually laying
                           # the layer). Probe dips during leveling last seconds and
                           # the purge line ~15s, so neither satisfies the dwell -
                           # travel moves during homing/mesh can no longer false-fire.
RECOVER_NUDGE = 3.0        # while a printer is powered off, try a firmware_restart
                           # this often so power-on is picked up fast. each try is
                           # skipped if klippy is already mid-connect, so short
                           # intervals can't step on a reconnect in progress.

MILESTONES = (0.75, 0.90, 0.95)   # progress announcements w/ time remaining (50% is
                                  # the classic pre-rendered "print halfway" voice)

THERMAL_KEYS = ("heat", "thermal", "temperature", "mintemp",
                "maxtemp", "adc out of range")   # adc = thermistor fault

FAMILY = {
    "start": "start", "done": "done", "pause": "pause", "resume": "resume",
    "cancel": "pause", "error": "error", "offline": "offline", "online": "online",
    "halfway": "_none", "cool": "_none", "thermal": "error", "first_layer": "_none",
    "powering_off": "_none", "milestone": "_none", "received": "_none",
}
SPEAK = {
    "start": "{name} preheating", "done": "{name} print complete",
    "pause": "{name} paused", "resume": "{name} resuming",
    "cancel": "{name} print canceled", "error": "{name} error",
    "offline": "{name} offline", "online": "{name} back online",
    "powering_off": "{name} powering off",
    "halfway": "{name} print halfway", "cool": "{name} cooled temperature safe",
    "thermal": "warning warning {name} heating failed warning warning",
    "first_layer": "{name} first layer complete",
    "received": "{name} print file received",   # fallback; real line adds the filename
}

# voice queue plays in this order when several land near-simultaneously
FLEET_ORDER = {"Omega": 0, "Unicorn": 1, "Dimeter": 2, "Trident": 3,
               "Tesseract": 4, "Pentagram": 5, "Sestina": 6, "Hydra": 7,
               "System": 8}
NARRATION_VOICE = {"start", "halfway", "first_layer", "milestone", "received"}

def clean_filename(fn):
    # basename, drop the extension, and make separators speakable
    if not fn:
        return ""
    base = os.path.splitext(os.path.basename(fn))[0]
    return base.replace("_", " ").replace("-", " ").strip()

def fmt_remaining(secs):
    m = int(secs // 60)
    if m >= 60:
        h, mm = divmod(m, 60)
        hh = f"{h} hour" + ("s" if h != 1 else "")
        mmw = f"{mm} minute" + ("s" if mm != 1 else "")
        return f"{hh} {mmw} remaining" if mm else f"{hh} remaining"
    if m >= 1:
        return f"{m} minute" + ("s" if m != 1 else "") + " remaining"
    return "under a minute remaining"

def narration_muted():
    return os.path.exists(os.path.expanduser("~/.mute_narration"))
def stacking_on():
    # default OFF -> voices queue in fleet order, no overlap. ON -> voices overlap.
    return os.path.exists(os.path.expanduser("~/.voice_stacking"))
def serial_missing(name):
    # True if this printer's [mcu] serial device is GONE from /dev. On these
    # boards the CH340 usb chip is powered by the CABLE, so a switched-off
    # printer keeps its /dev entry - a MISSING device means the usb cable was
    # UNPLUGGED. Lets comm-loss announce "error" (unplug) vs "powering off".
    try:
        cfg = os.path.expanduser(f"~/printer_{name.upper()}_data/config/printer.cfg")
        with open(cfg) as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("serial:") and "/dev/" in s:
                    return not os.path.exists(s.split(":", 1)[1].strip())
    except Exception:
        pass
    return False

def fleet_restart():
    # True shortly after restart-all.sh ran: its ~/.fleet_restart flag marks the
    # coming "back online" wave as a FLEET event, so simultaneous arrivals sort
    # Omega->Unicorn->Dimeter->Trident instead of by reconnect timing. Expires
    # fast (2 min) so a later solo drop goes back to honest chronological order.
    f = os.path.expanduser("~/.fleet_restart")
    try:
        return time.time() - os.path.getmtime(f) < 120
    except Exception:
        return False

def shaping(name):
    # True while an input-shaping run owns this printer (set by shape.sh in ~/.shaping).
    # Its restart's offline/online are suppressed so the shaping narration isn't
    # doubled. Auto-expires after 10 min so a crashed run can't mute a printer forever.
    f = os.path.expanduser("~/.shaping")
    try:
        if time.time() - os.path.getmtime(f) > 600:
            return False
        return open(f).read().strip() == name
    except Exception:
        return False

_voice_queue = []          # pending voices: {event, rank, seq, phrase, fa}
_voice_seq = 0
_last_voice = {}           # phrase -> last time (dedup)
_voice_wake = None         # asyncio.Event, created in main
_urgent = None             # asyncio.Event, created in main; set by thermal voices
_checked_in = set()        # printers that have rolled call this run (for boot summary)

# legacy serialized mode (VOICE_STACKING ON): chime+voice share one lock and a
# fleet stagger; near-simultaneous events collide and drop (the pre-queue feel).
play_lock = asyncio.Lock()
RANK_SLEEP = {"Omega": 0.0, "Unicorn": 0.15, "Dimeter": 0.30, "Trident": 0.45,
              "Tesseract": 0.60, "Pentagram": 0.75, "Sestina": 0.90, "Hydra": 1.05}

def pick(base):
    c = sorted(glob.glob(os.path.join(CHIME_DIR, f"{base}.wav")) +
               glob.glob(os.path.join(CHIME_DIR, f"{base}_*.wav")))
    return random.choice(c) if c else None

async def _run(*argv):
    try:
        p = await asyncio.create_subprocess_exec(
            *argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rc = await p.wait()
        if rc:
            # a sound that failed to play is otherwise invisible - log it
            print(f"audio failed rc={rc}: {os.path.basename(str(argv[-1]))}",
                  flush=True)
    except Exception as e:
        print(f"audio failed: {e}", flush=True)

def enqueue_voice(who, phrase, force, event="", fleet=False):
    global _voice_seq
    if not phrase or not os.path.exists(SPEAKER):
        return
    now = time.monotonic()
    if now - _last_voice.get(phrase, -1e9) < DEDUP_WINDOW:
        return                                   # identical voice just handled
    _last_voice[phrase] = now
    if len(_last_voice) > 300:                   # bound the dedup map: milestone and
        cutoff = now - 60                        # filename phrases are unique per
        for k in [k for k, t in _last_voice.items() if t < cutoff]:
            del _last_voice[k]                   # print and would grow forever
    _voice_seq += 1
    _voice_queue.append({"event": event, "rank": FLEET_ORDER.get(who, 8),
                         "seq": _voice_seq, "phrase": phrase, "fleet": fleet,
                         "fa": ["--force"] if force else []})
    print(f"[{who}] queue: {phrase}", flush=True)
    if _voice_wake:
        _voice_wake.set()
    if event == "thermal" and _urgent:
        _urgent.set()                            # cut the gather window short

async def voice_player():
    while True:
        if not _voice_queue:
            await _voice_wake.wait()
            _voice_wake.clear()
            continue
        try:    # gather a batch; a thermal alert breaks the wait immediately
            await asyncio.wait_for(_urgent.wait(), COLLECT_WINDOW)
        except asyncio.TimeoutError:
            pass
        # group keys live for the WHOLE drain: once a group's earliest seq is
        # recorded it never changes, even after members are popped - otherwise a
        # half-played group's key would drift later and let another group cut in.
        firsts = {}
        while _voice_queue:                      # drain grouped by event type
            _urgent.clear()
            # thermal first always; then keep each event type together (a group's
            # key is the earliest arrival among its members). WITHIN a group:
            # roll-call events (fleet=True, a printer checking in at boot) play in
            # fleet order Omega->Unicorn->Dimeter->Trident; everything else plays
            # in arrival order (seq) so manual actions come out in the order you
            # did them. seq ordering is stable, so a straggler never reshuffles.
            for it in _voice_queue:
                e = it["event"]
                if e not in firsts:
                    firsts[e] = it["seq"]
            _voice_queue.sort(key=lambda x: (
                0 if x["event"] == "thermal" else 1,
                firsts[x["event"]], x["rank"] if x["fleet"] else 0, x["seq"]))
            item = _voice_queue.pop(0)
            # a group's key dies with its last member: a NEW wave of the same
            # event type minutes later must form a NEW group (with its own,
            # later key) instead of inheriting this one and cutting the line
            if not any(x["event"] == item["event"] for x in _voice_queue):
                firsts.pop(item["event"], None)
            print(f"say: {item['phrase']}", flush=True)
            await _run(SPEAKER, *item["fa"], item["phrase"])

_bg_tasks = set()          # strong refs so fire-and-forget chime tasks can't be GC'd

async def chime_blocking(event):
    # play an event's chime and WAIT for it to finish - used for print start,
    # where the start sound should land BEFORE the voices, not under them
    fam = FAMILY.get(event, "_none")
    wav = pick(fam)
    if not wav:
        return
    now = time.monotonic()
    if now - _last_played.get(fam, -1e9) < DEDUP_WINDOW:
        return
    _last_played[fam] = now
    print(f"[chime-first] {event} -> {os.path.basename(wav)}", flush=True)
    # take the SAME voice lock say.sh uses: the start chime waits for any voice
    # still playing, sounds ALONE, and the following voice waits for it - so it's
    # a clean prelude ("notification, then the printer talks"), never a mix.
    await _run("flock", VOICE_LOCK, PLAYER, wav)

async def play(event, who, phrase_override=None, fleet=False, chime=True):
    force = event == "thermal"
    fa = ["--force"] if force else []
    fam = FAMILY.get(event, "_none")
    wav = pick(fam) if chime else None
    phrase = (phrase_override or SPEAK.get(event, "").format(name=who)) if VOICE else ""
    if event in NARRATION_VOICE and narration_muted():
        phrase = ""                              # keep chime, drop narration voice

    if stacking_on():
        # ON = legacy serialized: chime+voice one lock, fleet stagger, collisions drop
        if not wav and not phrase:
            return
        await asyncio.sleep(RANK_SLEEP.get(who, 0.6))
        async with play_lock:
            now = time.monotonic()
            # dedup by wav FAMILY, not event name: "thermal" and "error" share the
            # error wav - keying by event let the same alarm fire twice back-to-back
            if wav and now - _last_played.get(fam, -1e9) >= DEDUP_WINDOW:
                _last_played[fam] = now
                await _run(PLAYER, *fa, wav)
            if phrase and os.path.exists(SPEAKER):
                await _run(SPEAKER, *fa, phrase)
        return

    # OFF (default): chime fires immediately (overlaps), voice goes to ordered queue
    if wav:
        now = time.monotonic()
        # during a fleet restart the whole farm cycles within ~30s: play ONE
        # offline beep and ONE online beep for the wave, not one per printer
        # (the voices still name every printer - the chime is just the signal)
        window = 45.0 if (event in ("offline", "online")
                          and fleet_restart()) else DEDUP_WINDOW
        if now - _last_played.get(fam, -1e9) >= window:
            _last_played[fam] = now
            print(f"[{who}] {event} -> {os.path.basename(wav)}", flush=True)
            t = asyncio.create_task(_run(PLAYER, *fa, wav))
            _bg_tasks.add(t); t.add_done_callback(_bg_tasks.discard)
    enqueue_voice(who, phrase, force, event, fleet)

async def say_system(text):
    full = f"System {text}"
    if stacking_on():
        async with play_lock:
            if os.path.exists(SPEAKER):
                await _run(SPEAKER, full)
    else:
        enqueue_voice("System", full, False, "system")

def classify(prev, new):
    if new == "printing":
        return "resume" if prev == "paused" else "start"
    return {"complete": "done", "paused": "pause",
            "cancelled": "cancel", "error": "error"}.get(new)

async def watch(port, name):
    import websockets
    uri = f"ws://127.0.0.1:{port}/websocket"
    sub = json.dumps({"jsonrpc": "2.0",
        "method": "printer.objects.subscribe",
        "params": {"objects": {"print_stats": ["state", "print_duration", "filename"],
            "virtual_sdcard": ["progress"],
            "heater_bed": ["temperature"],
            "gcode_move": ["gcode_position"],
            "webhooks": ["state", "state_message"]}}, "id": 1})
    state = None; half = False; awaiting_cool = False; last_err = ""
    last_err_t = -1e9      # when last_err was captured; stale lines are ignored
    thermal_at = -1e9      # when a thermal alarm played; suppresses the follow-on
                           # print_stats "error" state-change announcement
    fl_fired = False; low_since = None
    pfilename = ""        # latest print_stats.filename, for the "file received" line
    pdur = 0.0             # latest print_duration, for time-remaining estimates
    milestones = set()     # which of MILESTONES have been announced this print
    established = False     # True once this printer has ever connected. One that never
                           # connects (powered off / not in use) is never established,
                           # so it stays fully silent: the "active set" is simply
                           # whoever has checked in.
    down = False           # True while considered dropped ("offline"/fault announced)
    recover_task = None    # firmware_restart nudger, runs while powered off

    COMM_LOSS = ("lost communication", "serial", "unable to connect", "disconnect")

    async def auto_recover():
        # after a power-off, klippy sits in shutdown and will NOT reconnect on
        # its own - it needs a firmware_restart. nudge it every RECOVER_NUDGE
        # seconds; while the board is still dark the attempt just fails
        # quietly, and the first one after power returns brings klippy ready
        # -> "back online" (and lets it reconfigure the board: LED etc).
        url = f"http://127.0.0.1:{port}/printer/firmware_restart"
        info = f"http://127.0.0.1:{port}/printer/info"
        loop = asyncio.get_running_loop()
        try:
            while True:
                await asyncio.sleep(RECOVER_NUDGE)
                try:
                    st = await loop.run_in_executor(
                        None, lambda: http_json(info, timeout=4))
                    if st.get("result", {}).get("state") in ("startup", "ready"):
                        continue     # mid-connect or already up: don't step on it
                except Exception:
                    continue         # moonraker unreachable: skip this round
                try:
                    req = urllib.request.Request(url, data=b"", method="POST")
                    await loop.run_in_executor(
                        None, lambda: urllib.request.urlopen(req, timeout=5))
                except Exception:
                    pass
        except asyncio.CancelledError:
            pass

    def come_up():
        # first check-in OR return-from-drop: baseline it as up.
        nonlocal established, down, recover_task
        if recover_task and not recover_task.done():
            recover_task.cancel()
        recover_task = None
        established = True; down = False

    while True:
        try:
            async with websockets.connect(uri, ping_interval=30) as ws:
                await ws.send(sub)
                async for raw in ws:
                    msg = json.loads(raw)
                    if msg.get("id") == 1 and "result" in msg:
                        st = msg["result"].get("status", {})
                        state = st.get("print_stats", {}).get("state", state)
                        # daemon (re)started mid-print: mark already-passed
                        # progress marks as done so they don't replay late
                        p0 = st.get("virtual_sdcard", {}).get("progress")
                        if state == "printing" and p0:
                            half = half or p0 >= 0.5
                            milestones |= {m for m in MILESTONES if p0 >= m}
                        wh = st.get("webhooks", {})
                        kstate = wh.get("state", "ready")
                        kmsg = (wh.get("state_message") or "").lower()
                        if not established:
                            if kstate == "ready":    # truly up -> roll-call
                                come_up()
                                _checked_in.add(name)
                                await play("online", name, fleet=True)  # boot: fleet order
                            elif kstate == "startup":
                                # cold boot: klippy is mid-handshake. NOT an error
                                # state - stay unestablished and let the coming
                                # notify_klippy_ready do the real (fleet-ordered)
                                # roll-call. Treating startup as down here lost
                                # the fleet ordering AND the boot-summary count.
                                pass
                            else:
                                # klippy answers but the printer is shutdown/error:
                                # check in silently - no fake "online". if it's a
                                # comm loss (powered off), start nudging so power-on
                                # alone brings it back.
                                established = True; down = True
                                if any(k in kmsg for k in COMM_LOSS):
                                    recover_task = asyncio.create_task(auto_recover())
                        elif down and kstate == "ready":
                            come_up()                # recovered while ws was down
                            if not shaping(name):
                                await play("online", name, fleet=fleet_restart())
                        elif not down and kstate not in ("ready", "startup"):
                            # klippy went down while our websocket was away (e.g.
                            # moonraker restarted and the printer was powered off
                            # in that window). without this branch the printer
                            # would be silently stuck "up" forever - and never
                            # nudged back, since only this daemon restarts a
                            # shutdown klippy. ("startup" excluded: that's just a
                            # restart in progress - announcing it made phantom
                            # offline/online pairs.)
                            down = True
                            if any(k in kmsg for k in COMM_LOSS):
                                if not shaping(name):
                                    if state == "printing" or serial_missing(name):
                                        await play("error", name)   # unplug / mid-print loss
                                    else:
                                        await play("powering_off", name)
                                    await play("offline", name)
                                recover_task = asyncio.create_task(auto_recover())
                            elif not shaping(name):
                                await play("offline", name)
                        continue
                    m = msg.get("method", "")
                    if m == "notify_status_update":
                        d = msg["params"][0]
                        ps = d.get("print_stats", {})
                        if ps.get("print_duration") is not None:
                            pdur = ps["print_duration"]
                        if ps.get("filename") is not None:
                            pfilename = ps["filename"]
                        new = ps.get("state")
                        if new and new != state:
                            ev = classify(state, new)
                            if new == "printing" and state != "paused":
                                half = False; awaiting_cool = False
                                fl_fired = False; low_since = None
                                milestones = set()
                            if new == "complete":
                                awaiting_cool = True
                            state = new
                            if ev == "start":      # start CHIME first, THEN the voices
                                await chime_blocking("start")
                                fn = clean_filename(pfilename)
                                rec = (f"{name} print file {fn} received" if fn
                                       else f"{name} print file received")
                                await play("received", name, rec)
                            if ev == "error" and time.monotonic() - thermal_at < 15:
                                ev = None          # thermal alarm already covered it
                            elif (ev == "error"
                                    and time.monotonic() - last_err_t < 30
                                    and any(k in last_err for k in THERMAL_KEYS)):
                                # error state-change ARRIVED BEFORE the shutdown
                                # notification, but the console line already says
                                # it's thermal - skip the generic "error" so the
                                # forced thermal alarm (coming next) stands alone
                                ev = None
                            if ev:
                                # start's chime already played (blocking, above)
                                await play(ev, name, chime=(ev != "start"))
                        prog = d.get("virtual_sdcard", {}).get("progress")
                        if prog is not None and state == "printing" and not half and prog >= 0.5:
                            half = True
                            await play("halfway", name)
                        if prog is not None and state == "printing":
                            for mk in MILESTONES:
                                if prog >= mk and mk not in milestones:
                                    milestones.add(mk)
                                    phrase = f"{name} {int(mk * 100)} percent"
                                    if pdur > 60 and prog > 0:
                                        phrase += ", " + fmt_remaining(
                                            pdur * (1 - prog) / prog)
                                    await play("milestone", name, phrase)
                        temp = d.get("heater_bed", {}).get("temperature")
                        if temp is not None and awaiting_cool and temp < 40:
                            awaiting_cool = False
                            await play("cool", name)
                        gp = d.get("gcode_move", {}).get("gcode_position")
                        if gp and len(gp) > 2 and state == "printing" and not fl_fired:
                            z = gp[2]
                            if z <= FIRST_LAYER_LOW:
                                # nozzle is down where a first layer is laid;
                                # start (or continue) the dwell clock
                                if low_since is None:
                                    low_since = time.monotonic()
                            elif z > FIRST_LAYER_Z:
                                # risen clear: only counts if it spent real time
                                # down low first (probe dips / purge are too brief)
                                if (low_since is not None and
                                        time.monotonic() - low_since > FIRST_LAYER_DWELL):
                                    fl_fired = True
                                    await play("first_layer", name)
                                low_since = None
                    elif m == "notify_gcode_response":
                        line = (msg["params"][0] or "").lower()
                        if "!!" in line or "shutdown" in line or "fail" in line:
                            last_err = line; last_err_t = time.monotonic()
                    elif m == "notify_klippy_shutdown":
                        # a fault (thermal/error) is urgent: announce now. BUT a
                        # shutdown from losing MCU contact while idle is just the
                        # printer being powered off -> plain "offline". mid-print
                        # comm loss still counts as an error worth hearing.
                        if established and not down:
                            down = True
                            # the console line (last_err) often hasn't arrived yet
                            # when the shutdown notification lands, so also ask
                            # klippy directly why it shut down (state_message).
                            # ignore stale console lines (>30s old): an hours-old
                            # "!! heater fail" must not reclassify a plain power-off
                            # as thermal and blast the forced alarm.
                            detail = last_err if time.monotonic() - last_err_t < 30 else ""
                            try:
                                await asyncio.sleep(1.0)   # let state_message settle
                                d = await asyncio.get_running_loop().run_in_executor(
                                    None, lambda: http_json(
                                        f"http://127.0.0.1:{port}/printer/info",
                                        timeout=4))
                                detail += " " + (d.get("result", {})
                                                  .get("state_message") or "").lower()
                            except Exception:
                                pass
                            print(f"[{name}] shutdown: {detail.strip()[:120]}",
                                  flush=True)
                            thermal = any(k in detail for k in THERMAL_KEYS)
                            powered_off = state != "printing" and any(
                                k in detail for k in COMM_LOSS)
                            if thermal:
                                thermal_at = time.monotonic()
                                await play("thermal", name)   # always, even mid-shaping
                            elif shaping(name):
                                # shaping restart - narration covers it. BUT a real
                                # power-off during shaping still needs the nudger,
                                # or the printer strands in shutdown forever.
                                if powered_off:
                                    recover_task = asyncio.create_task(auto_recover())
                            elif powered_off:
                                if serial_missing(name):
                                    await play("error", name)        # usb UNPLUGGED
                                else:
                                    await play("powering_off", name) # switched off
                                await play("offline", name)
                                recover_task = asyncio.create_task(auto_recover())
                            else:
                                await play("error", name)
                            last_err = ""
                    elif m == "notify_klippy_disconnected":
                        # any drop of a checked-in printer announces "offline" now; a
                        # restart just means "back online" follows a few seconds later.
                        # a printer that never checked in stays silent.
                        if established and not down:
                            down = True
                            if not shaping(name):
                                await play("offline", name)
                    elif m == "notify_klippy_ready":
                        await ws.send(sub)           # (re)subscribe so print events flow
                        if not established:          # first check-in -> boot roll-call
                            come_up()
                            _checked_in.add(name)
                            await play("online", name, fleet=True)
                        elif down:                   # came back after a drop: chronological,
                            come_up()                # EXCEPT during a fleet restart wave
                            if not shaping(name):
                                await play("online", name, fleet=fleet_restart())
        except Exception as e:
            print(f"[{name}] conn lost ({e}); retry 5s", flush=True)
            await asyncio.sleep(5)

def wifi_iface():
    for w in glob.glob("/sys/class/net/*/wireless"):
        return os.path.basename(os.path.dirname(w))
    return None

def http_json(url, timeout=8):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode())

_seen_ports = set()        # unknown serial ports already announced

def _configured_serials():
    conf = set()
    for cfg in glob.glob(os.path.expanduser("~/printer_*_data/config/printer.cfg")):
        try:
            with open(cfg) as fh:
                for line in fh:
                    s = line.strip()
                    if s.startswith("serial:") and "/dev/" in s:
                        conf.add(s.split(":", 1)[1].strip())
                        break
        except Exception:
            pass
    return conf

async def monitor():
    disk_warned = False
    wifi_up = True             # last seen state
    wifi_established = False    # True once wifi has been confirmed up at least once.
                               # the first boot-time association is NOT a "reconnect",
                               # so we stay silent until a genuine drop-and-return.
    update_announced = -1e9    # -inf so the first check runs on the first pass
                               # (0.0 would silence it for 24h of pad uptime)
    iface = wifi_iface()
    while True:
        try:
            if not iface:
                iface = wifi_iface()   # driver can register the iface after boot
            st = os.statvfs("/")
            used = 1 - (st.f_bavail / st.f_blocks)
            if used > 0.90 and not disk_warned:
                disk_warned = True; await say_system("low disk space")
            elif used < 0.85:
                disk_warned = False
            if iface:
                try:
                    up = open(f"/sys/class/net/{iface}/operstate").read().strip() == "up"
                except Exception:
                    up = True
                if up and not wifi_established:
                    wifi_established = True       # first time up: baseline, silent
                elif up and not wifi_up and wifi_established:
                    await say_system("wifi reconnected")   # genuine reconnect only
                wifi_up = up
            # a serial device nobody's config claims = a new/moved printer board.
            # announce once; port-assign.sh is the ten-second fix.
            try:
                present = set(glob.glob("/dev/serial/by-path/*"))
                if present:
                    unknown = present - _configured_serials() - _seen_ports
                    for p in sorted(unknown):
                        _seen_ports.add(p)
                        print(f"unknown serial device: {p}", flush=True)
                        await say_system("unknown printer connected")
            except Exception:
                pass
            if time.monotonic() - update_announced > 86400:
                try:
                    # in the executor: a hung Moonraker must not stall the event
                    # loop (this is the one HTTP call that ran inline)
                    d = await asyncio.get_running_loop().run_in_executor(
                        None, lambda: http_json(
                            "http://127.0.0.1:7128/machine/update/status?refresh=false",
                            timeout=6))
                    vinfo = d.get("result", {}).get("version_info", {})
                    behind = any(
                        (c.get("version") != c.get("remote_version"))
                        for c in vinfo.values() if isinstance(c, dict)
                        and c.get("version") and c.get("remote_version"))
                    if behind:
                        update_announced = time.monotonic()
                        await say_system("update available")
                except Exception:
                    pass
        except Exception as e:
            print(f"monitor: {e}", flush=True)
        await asyncio.sleep(300)

NUM_WORD = {0: "no", 1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
            6: "six", 7: "seven", 8: "eight"}

async def boot_summary():
    # ROLL CALL goes first. Printers take 10-20s to come up from cold, so wait the
    # check-ins out: a stable ZERO just means they're still booting - never call
    # that "no printers". Only settle early once at least one is in and the count
    # holds; otherwise wait the full ceiling. This also guarantees the summary
    # enqueues AFTER the roll-call voices, so it plays after them.
    settle = 0; last = 0
    for i in range(24):                            # ~36s ceiling for a cold boot
        await asyncio.sleep(1.5)
        n = len(_checked_in)
        if n == len(PRINTERS):
            break                                  # everyone's in - summarize now
        if n > 0:                                  # stable count WITH someone up = settled
            settle = settle + 1 if n == last else 0
            if settle >= 3:                        # ~4.5s with no new arrivals
                break                              # rest are powered off
        last = n
    # wifi: let the adapter finish associating before we report it
    iface = wifi_iface(); wup = True
    if iface:
        wup = False
        for _ in range(8):                         # up to ~8s for association
            try:
                wup = open(f"/sys/class/net/{iface}/operstate").read().strip() == "up"
            except Exception:
                wup = True
            if wup:
                break
            await asyncio.sleep(1.0)
    n = len(_checked_in)
    line = (f"System online, {'wifi connected' if wup else 'wifi offline'}, "
            f"{NUM_WORD.get(n, str(n))} {'printer' if n == 1 else 'printers'} ready")
    print(f"boot: {line}", flush=True)
    enqueue_voice("System", line, False, "boot_summary")   # sorts after the roll call

async def main():
    global _voice_wake, _urgent
    _voice_wake = asyncio.Event()
    _urgent = asyncio.Event()
    boots = sorted(glob.glob(os.path.join(CHIME_DIR, "boot.wav")) +
                   glob.glob(os.path.join(CHIME_DIR, "boot_*.wav")))
    if boots:
        await _run(PLAYER, random.choice(boots))
    # everything starts together: printers roll-call as they check in, and the
    # boot summary waits for them to settle, then speaks its one line after.
    await asyncio.gather(voice_player(), monitor(), boot_summary(),
                         *(watch(p, n) for p, n in PRINTERS.items()))

if __name__ == "__main__":
    asyncio.run(main())

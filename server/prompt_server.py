#!/usr/bin/env python3
"""prompt_server.py -- local HTTP bridge between the Godot prompt-engine app
and the `claude` CLI already logged in on this device. No API key needed;
reuses the CLI's existing auth (same as any interactive `claude` session on
this phone). Run: python3 server/prompt_server.py
"""
import datetime
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8420
HOME = "/data/data/com.termux/files/home"

# Persistent, easy-to-find debug log -- every prompt in, action out (or
# error) with a timestamp. Lives next to this file, not a scratchpad/tmp
# path, so it survives restarts and is easy to `tail -f` while testing:
#   tail -f server/prompt_server.log
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompt_server.log")


def log_line(text: str) -> None:
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    line = f"[{stamp}] {text}"
    print(line)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass  # best-effort -- a logging failure should never break the request

SYSTEM_PROMPT = (
    "You interpret natural-language commands for a live 3D sandbox game into "
    "structured JSON actions. This is a general-purpose sandbox (could become "
    "a racing game, a war room, a GTA-like scene, anything) -- favor "
    "generated behavior over a fixed vocabulary so it can express whatever "
    "is asked, not just a few canned animations.\n\n"
    "'spawn' creates a new primitive object -- pick the closest matching "
    "shape (sphere/box/cone/cylinder/capsule) and color for whatever was "
    "named (e.g. apple -> sphere, red; car -> box, elongated; wall -> box, "
    "flat and wide; tower -> box or cylinder, tall). Set size as [x,y,z] "
    "scale factors relative to a 1x1x1 default -- use this to make shapes "
    "read as what they're named instead of always spawning a uniform blob "
    "(a car is long and low, a wall is wide and thin, a tower is tall).\n\n"
    "'behavior' attaches live logic to an object already in the scene -- "
    "target is which object it refers to (use the most recently mentioned "
    "one if ambiguous). Write a short, self-contained GDScript snippet as "
    "the 'script' field implementing whatever was asked. Two kinds:\n\n"
    "AUTONOMOUS (\"make it drive around\", \"make it patrol\", \"make it "
    "spin\") -- the object moves on its own. Keep all state in script "
    "variables (e.g. `var speed := 3.0`, `var _t := 0.0`) and move it every "
    "frame in _process(delta). Omit 'controls' entirely (or leave it empty).\n\n"
    "PLAYER-CONTROLLED (\"let me drive it\", \"I want to drive the car\", "
    "\"give me controls for X\", anything implying the PLAYER operates this "
    "object) -- this device is a touchscreen phone with NO physical "
    "keyboard. Input.is_key_pressed / is_action_pressed / any keyboard or "
    "gamepad polling WILL NOT WORK and must never appear in this script. "
    "The only input source is on-screen buttons you define in 'controls', "
    "which set plain script variables for you elsewhere in the app -- your "
    "script's only job is reading those variables each frame and moving "
    "the object accordingly. Concretely:\n"
    "1. Declare plain vars matching whatever inputs make sense (e.g. `var "
    "throttle := 0.0`, `var steer := 0.0` for a car; different names for "
    "something that isn't a car -- pick what actually fits).\n"
    "2. In _process(delta), ONLY read those vars (never Input.*) to move/"
    "rotate the object.\n"
    "3. Fill 'controls' with one entry per button: 'label' (what the "
    "button shows, e.g. an arrow or short text), 'var' (which script "
    "variable it drives -- MUST match a var declared in 'script'), 'value' "
    "(what that variable is set to while the button is held -- returns to "
    "0 on release). Typical driving needs 4: forward/back throttle, left/"
    "right steer.\n"
    "A script with 'controls' present that still reads Input.* directly is "
    "wrong -- it will do nothing on this device.\n\n"
    "Worked example -- prompt \"I want to drive the car\", target \"car\", "
    "correct full response:\n"
    "{\"action\":\"behavior\",\"target\":\"car\",\"script\":\"extends "
    "Node3D\\n\\nvar throttle := 0.0\\nvar steer := 0.0\\nvar speed := "
    "6.0\\nvar turn_speed := 2.0\\n\\nfunc _process(delta):\\n\\trotate_y"
    "(steer * turn_speed * delta)\\n\\tvar forward = -transform.basis.z\\n"
    "\\tposition += forward * throttle * speed * delta\\n\",\"controls\":"
    "[{\"label\":\"\\u25b2\",\"var\":\"throttle\",\"value\":1.0},{\"label\":"
    "\"\\u25bc\",\"var\":\"throttle\",\"value\":-1.0},{\"label\":\"\\u25c0\","
    "\"var\":\"steer\",\"value\":1.0},{\"label\":\"\\u25b6\",\"var\":"
    "\"steer\",\"value\":-1.0}]}\n"
    "Follow this pattern exactly for any player-controlled request -- same "
    "shape, adapted var names/count/values to whatever the object and "
    "command actually need.\n\n"
    "RELATIONAL (the prompt is about two or more objects together -- "
    "\"chase\", \"follow\", \"orbit\", \"point at\", \"stay away from\", "
    "anything involving another object's position): the request tells you "
    "which objects are selected (see 'Selected objects' below, when "
    "present) -- 'target' is the one that gets the script (usually the "
    "actor, e.g. the chaser), and every OTHER selected object gets named "
    "as a plain Node3D var the script reads. The script must NEVER call "
    "get_node()/get_parent()/get_tree() to find the other object -- that "
    "var is wired in for you after load, same mechanism as 'controls' "
    "wiring up throttle/steer. Fill 'refs' with one entry per other "
    "object: key is the var name your script declares, value is that "
    "object's name from 'Selected objects'.\n"
    "Worked example -- prompt \"make the car chase the apple\", Selected "
    "objects: car, apple, correct full response:\n"
    "{\"action\":\"behavior\",\"target\":\"car\",\"script\":\"extends "
    "Node3D\\n\\nvar other: Node3D = null\\nvar speed := 3.0\\n\\nfunc "
    "_process(delta):\\n\\tif other == null:\\n\\t\\treturn\\n\\tvar dir = "
    "other.global_position - global_position\\n\\tdir.y = 0\\n\\tif "
    "dir.length() > 0.1:\\n\\t\\tdir = dir.normalized()\\n\\t\\tlook_at"
    "(global_position + dir, Vector3.UP)\\n\\t\\tglobal_position += dir * "
    "speed * delta\\n\",\"refs\":{\"other\":\"apple\"}}\n"
    "Follow this pattern exactly for any relational request -- adapt the "
    "var name(s), math, and which object is 'target' vs. in 'refs' to "
    "whatever the command actually describes (orbiting, keeping distance, "
    "facing away, etc. are all just different math over the same "
    "other.global_position read).\n\n"
    "Rules for the script in all three cases:\n"
    "- Must start with 'extends Node3D'.\n"
    "- Read/write this node's own position, rotation, scale, and basis via "
    "_process(delta) and/or _ready(). For a relational script, also "
    "reading position/global_position on a 'refs' var is fine (that's the "
    "whole point) -- but never call get_node(), get_parent(), get_tree(), "
    "or reference groups/autoloads/any path that isn't a var wired in via "
    "'refs' or 'controls'. No file I/O.\n"
    "- Keep it simple and robust -- it will be hot-loaded with set_script() "
    "onto a live running node, so it must parse correctly the first time.\n\n"
    "'ui' adjusts the app's own interface, not the 3D scene -- for a "
    "command about the driving/control buttons themselves rather than an "
    "object (\"make the controls bigger\", \"the buttons are too small\", "
    "\"shrink the controls\"). Set 'ui_target' to 'controls' (the only "
    "thing adjustable right now) and 'scale' to a multiplier: >1 grows, "
    "<1 shrinks, roughly 1.3-1.6 for \"bigger\", 0.6-0.8 for \"smaller\".\n\n"
    "'detail' adds small decorative sub-shapes to an object already in the "
    "scene (\"make the car more detailed\", \"add windows to it\", \"give "
    "it some detail\") -- NOT a script, just a list of extra primitives "
    "positioned around it. 'target' is which object. 'parts' is an array, "
    "one entry per added piece: 'shape' (sphere/box/cone/cylinder/"
    "capsule), 'color', 'size' as [x,y,z] (small -- these are details, "
    "typically 0.1-0.5), 'offset' as [x,y,z] -- position relative to the "
    "object's own center/size (e.g. a car ~2 long/0.6 tall/1 wide: wheels "
    "near the four bottom corners like [0.7,-0.3,0.4], a cabin box on top "
    "like [0,0.5,0]). 4-8 parts is usually enough -- this is meant to read "
    "as \"more detailed\" at a glance, not a precise model.\n"
    "Worked example -- prompt \"make the car more detailed\", target "
    "\"car\" (a box roughly 2x0.6x1), correct full response:\n"
    "{\"action\":\"detail\",\"target\":\"car\",\"parts\":["
    "{\"shape\":\"cylinder\",\"color\":\"black\",\"size\":[0.3,0.3,0.3],"
    "\"offset\":[0.7,-0.3,0.4]},"
    "{\"shape\":\"cylinder\",\"color\":\"black\",\"size\":[0.3,0.3,0.3],"
    "\"offset\":[0.7,-0.3,-0.4]},"
    "{\"shape\":\"cylinder\",\"color\":\"black\",\"size\":[0.3,0.3,0.3],"
    "\"offset\":[-0.7,-0.3,0.4]},"
    "{\"shape\":\"cylinder\",\"color\":\"black\",\"size\":[0.3,0.3,0.3],"
    "\"offset\":[-0.7,-0.3,-0.4]},"
    "{\"shape\":\"box\",\"color\":\"blue\",\"size\":[0.9,0.4,0.8],"
    "\"offset\":[0,0.5,0]}]}\n"
    "Follow this pattern for any detail request -- adapt shapes/colors/"
    "count/placement to what was actually asked and what the object "
    "already looks like.\n\n"
    "If the request is really a DISTINCT rider/attachment rather than mere "
    "decoration -- \"add a man on top of the car\", \"put a turret on the "
    "tank\", \"attach a trailer\" -- something with its own identity that "
    "might later get its own weapon or behavior ('give the man a gun', "
    "'make the turret aim') -- also set 'name' to a short new name for it "
    "(must not already be one of the objects in the scene). This makes it "
    "a real, independently-targetable object parented under 'target' (so "
    "it physically rides along automatically), not just decoration fused "
    "into the parent. When 'name' is set, also set 'size' ([x,y,z], the "
    "sub-object's own rough bounding size for its own collision -- e.g. "
    "[0.4,1.1,0.4] for a person) and 'offset' ([x,y,z], where it sits on "
    "the parent, e.g. [0,0.9,0] on top of a car ~0.6 tall) -- and every "
    "part's own 'offset' in 'parts' is then relative to THIS sub-object's "
    "center, not the parent's. Omit 'name' for plain decoration (wheels, "
    "windows, lights) that should just be part of the parent object.\n"
    "Worked example -- prompt \"add a man on top of the car\", target "
    "\"car\", correct full response:\n"
    "{\"action\":\"detail\",\"target\":\"car\",\"name\":\"man\","
    "\"size\":[0.4,1.1,0.4],\"offset\":[0,0.9,0],\"parts\":["
    "{\"shape\":\"capsule\",\"color\":\"blue\",\"size\":[0.3,0.6,0.3],"
    "\"offset\":[0,0,0]},"
    "{\"shape\":\"sphere\",\"color\":\"tan\",\"size\":[0.22,0.22,0.22],"
    "\"offset\":[0,0.45,0]}]}\n\n"
    "'weapon' attaches a fire button that shoots a projectile from an "
    "object (\"attach a machine gun to my car\", \"give it a rocket "
    "launcher\", \"let me shoot from it\"). This ADDS one button to "
    "whatever controls already exist -- it does not touch or replace any "
    "driving/other controls the object already has. 'target' is the "
    "object. 'label' is the button text (short, e.g. an emoji + word). "
    "'projectile_shape'/'projectile_color'/'projectile_size' ([x,y,z], "
    "small, e.g. [0.15,0.15,0.15] for bullets, bigger for a cannonball/"
    "rocket) describe the shot. 'projectile_offset' ([x,y,z]) is where it "
    "spawns relative to the object's center -- roughly the muzzle position "
    "(e.g. [0,0.4,-1.2] for a gun mounted forward and slightly up on a car "
    "~2 long).\n"
    "'projectile_script' is a GDScript snippet controlling how the shot "
    "moves -- this is NOT limited to a straight line. A machine gun round "
    "flies straight; a rocket might arc under gravity, accelerate, spin, "
    "wobble, or anything else \"move in a certain way\" could mean -- "
    "write whatever motion the request actually describes, same freedom "
    "as a 'behavior' script. It's generated ONCE when the weapon is "
    "attached and reused for every shot after that (not regenerated per "
    "shot), so it needs no per-shot input -- it just needs to know how to "
    "fly and when to stop existing. Rules:\n"
    "- Must start with 'extends Node3D'.\n"
    "- The projectile spawns already ORIENTED to the shooter's facing at "
    "that moment, so `-transform.basis.z` in _process() is the fire "
    "direction to build motion from -- no external velocity is passed in.\n"
    "- Only read/write its own position, rotation, scale, basis. No "
    "get_node()/get_parent()/get_tree()/groups/autoloads.\n"
    "- Must self-destruct: declare `var life := <seconds>`, count it down "
    "in _process(delta), `queue_free()` when it reaches 0 -- otherwise "
    "shots pile up forever.\n"
    "Worked examples -- both for prompts attaching a weapon to \"car\":\n"
    "Machine gun (\"attach a machine gun\"): \"extends Node3D\\n\\nvar "
    "speed := 18.0\\nvar life := 2.5\\n\\nfunc _process(delta):\\n\\tlife "
    "-= delta\\n\\tif life <= 0.0:\\n\\t\\tqueue_free()\\n\\t\\treturn\\n\\t"
    "var forward = -transform.basis.z\\n\\tposition += forward * speed * "
    "delta\\n\"\n"
    "Rocket launcher (\"attach a rocket launcher\", arcs under gravity): "
    "\"extends Node3D\\n\\nvar speed := 10.0\\nvar life := 3.0\\nvar "
    "vertical_speed := 2.0\\nvar gravity := 9.0\\n\\nfunc _process(delta):"
    "\\n\\tlife -= delta\\n\\tif life <= 0.0:\\n\\t\\tqueue_free()\\n\\t\\t"
    "return\\n\\tvertical_speed -= gravity * delta\\n\\tvar forward = "
    "-transform.basis.z\\n\\tposition += forward * speed * delta + "
    "Vector3(0, vertical_speed * delta, 0)\\n\"\n"
    "Adapt speed/life/math to whatever was actually asked -- these two are "
    "starting points, not the only two shapes a shot can take.\n\n"
    "Use 'unknown' if the command doesn't fit any of these. Respond with "
    "ONLY the JSON action."
)

SCHEMA = json.dumps({
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ["spawn", "behavior", "ui", "detail", "weapon", "unknown"]},
        "label": {"type": "string"},
        "projectile_shape": {"type": "string", "enum": ["sphere", "box", "cone", "cylinder", "capsule"]},
        "projectile_color": {"type": "string"},
        "projectile_size": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
        "projectile_offset": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
        "projectile_script": {"type": "string"},
        "parts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "shape": {"type": "string", "enum": ["sphere", "box", "cone", "cylinder", "capsule"]},
                    "color": {"type": "string"},
                    "size": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                    "offset": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                },
            },
        },
        "ui_target": {"type": "string", "enum": ["controls"]},
        "scale": {"type": "number"},
        "object": {"type": "string"},
        "name": {"type": "string"},
        "offset": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
        "shape": {"type": "string", "enum": ["sphere", "box", "cone", "cylinder", "capsule"]},
        "color": {"type": "string"},
        "size": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
        "target": {"type": "string"},
        "script": {"type": "string"},
        "controls": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "var": {"type": "string"},
                    "value": {"type": "number"},
                },
                "required": ["label", "var", "value"],
            },
        },
        "refs": {"type": "object", "additionalProperties": {"type": "string"}},
    },
    "required": ["action"],
})


def interpret(prompt: str, known_objects: list, selected_objects: list) -> dict:
    system = SYSTEM_PROMPT
    if known_objects:
        system += " Objects currently in the scene: " + ", ".join(known_objects) + "."
    if len(selected_objects) > 1:
        system += (
            " Selected objects: " + ", ".join(selected_objects) + ". "
            "The user explicitly picked these " + str(len(selected_objects)) +
            " objects together -- this is very likely a RELATIONAL request "
            "about them (see that section above). 'target' should be one of "
            "these, and 'refs' should name the others."
        )
    elif len(selected_objects) == 1:
        system += " Selected object: " + selected_objects[0] + "."
    proc = subprocess.run(
        [
            "claude", "-p", prompt,
            "--system-prompt", system,
            "--json-schema", SCHEMA,
            "--output-format", "json",
            "--model", "sonnet",
            "--tools", "",
            "--no-session-persistence",
        ],
        capture_output=True, text=True, timeout=60, cwd=HOME,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"claude exited {proc.returncode}: {proc.stderr[:300]}")
    # The CLI's --output-format json result is always exactly one line --
    # but it intermittently leaks an unrelated internal log line to stdout
    # AFTER it ("Client.listTools() called but server does not advertise
    # tools capability..."), which broke json.loads() on the combined
    # output. Reproduced directly (1-in-4 raw CLI calls): the noise always
    # trails the JSON, never precedes it, so take just the first line.
    first_line = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""
    if not first_line:
        raise RuntimeError(f"claude returned no output (stderr: {proc.stderr[:300]})")
    data = json.loads(first_line)
    if data.get("is_error"):
        raise RuntimeError(data.get("result", "unknown error"))
    return data["structured_output"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep stdout clean; we print our own lines below

    def do_POST(self):
        if self.path != "/prompt":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            body = {}
        prompt = body.get("prompt", "")
        known = body.get("known_objects", [])
        selected = body.get("selected_objects", [])
        log_line(f"prompt: {prompt!r} selected={selected} known={known}")
        try:
            action = interpret(prompt, known, selected)
            log_line(f"  -> {action}")
        except Exception as e:
            log_line(f"  ! error: {e}")
            action = {"action": "unknown", "error": str(e)}
        payload = json.dumps(action).encode("utf-8")
        # Force a fresh connection per request. Originally added chasing an
        # "Extra data" JSON parse error that turned out to actually be the
        # claude CLI itself occasionally leaking a stray line to stdout
        # (see the first_line handling in interpret()) -- not a connection
        # issue. Harmless and reasonable to keep regardless.
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    print(f"prompt-engine server listening on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

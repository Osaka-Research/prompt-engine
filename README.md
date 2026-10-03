# Prompt Engine

Empty 3D scene + a prompt box. Type a command, it happens live in the
running game -- no rebuild.

- "add an apple" -> spawns a primitive (sphere/box/cone/cylinder/capsule,
  colored) matching whatever you named, closest guess made by Claude.
- "make it fly" -> attaches a behavior (fly/spin/bounce/grow/shrink/wobble)
  to the object you're referring to (defaults to the last one spawned).

## How it works

```
Godot app (prompt box)
  --HTTP POST--> server/prompt_server.py (Termux, localhost:8420)
                   --shells out to--> `claude -p` (already logged in,
                                       no API key needed)
                   <--structured JSON action--
  <--JSON action--
Godot applies it: spawns a primitive, or sets `kind` on an existing
object's behavior script (scripts/behavior.gd).
```

Objects are procedural primitives, not generated 3D models -- real
text-to-3D is a separate, much harder capability. Behaviors are a small
fixed library (see `scripts/behavior.gd`) picked by keyword, not raw
LLM-generated code, for reliability.

## Running it

1. Start the server (must be running before/while the app is open):
   ```
   python3 server/prompt_server.py
   ```
2. Open the app on the same device (the server only listens on
   `127.0.0.1` -- won't work across devices).
3. Type a command, hit Send.

## Dev tools

- `scripts/tools/smoke_test.gd` -- headless regression test, drives the
  real main scene through a few prompts and prints what landed:
  ```
  godot --headless --audio-driver Dummy --script scripts/tools/smoke_test.gd
  ```
  (Server must be running first.)

## Building the APK

Same pipeline as this device's other Godot projects (see
`~/.claude/skills/godot-android-build`):
```
godot --headless --import
godot --headless --export-debug "Android" build/prompt-engine-debug.apk
# then sign manually with apksigner.jar (Godot's own auto-sign is broken
# in this Termux setup -- see the skill doc)
```

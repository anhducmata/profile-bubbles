#!/usr/bin/env python3
"""Add or remove Profile Bubbles' hooks in Claude Code's user settings (~/.claude/settings.json).

    claude-hooks.py install <path to the ProfileBubbles binary>
    claude-hooks.py uninstall
    claude-hooks.py status

Other hooks in the file are left alone. The first change keeps a copy of the file next to it
(settings.json.profile-bubbles.bak). Prints one line: installed | not installed | an error.
"""
import json
import os
import shutil
import sys

SETTINGS = os.path.expanduser("~/.claude/settings.json")
MARK = "--claude-hook"
# event -> matcher (None: the event takes no matcher)
EVENTS = {
    "SessionStart": None,
    "UserPromptSubmit": None,
    "PreToolUse": "AskUserQuestion|ExitPlanMode",
    "PermissionRequest": "*",
    "PostToolUse": "*",
    "PostToolUseFailure": "*",
    "Stop": None,
    "StopFailure": None,
    "SessionEnd": None,
}


def ours(entry):
    return any(MARK in (h.get("command") or "") and "ProfileBubbles" in (h.get("command") or "")
               for h in entry.get("hooks", []))


def strip(settings):
    hooks = settings.get("hooks", {})
    for event in list(hooks):
        hooks[event] = [e for e in hooks[event] if not ours(e)]
        if not hooks[event]:
            del hooks[event]


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    settings = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS, encoding="utf-8") as f:
            settings = json.load(f)
    present = any(ours(e) for entries in settings.get("hooks", {}).values() for e in entries)
    if command == "status":
        print("installed" if present else "not installed")
        return
    if command == "install":
        binary = sys.argv[2]
        quoted = "'" + binary.replace("'", "'\\''") + "'"
        # Inside Orca the agent is already reported by Orca's own hooks.
        shell = f'if [ -z "${{ORCA_AGENT_HOOK_PORT-}}" ] && [ -x {quoted} ]; then {quoted} {MARK}; fi; true'
        strip(settings)
        hooks = settings.setdefault("hooks", {})
        for event, matcher in EVENTS.items():
            entry = {"hooks": [{"type": "command", "command": shell, "timeout": 5}]}
            if matcher:
                entry = {"matcher": matcher, **entry}
            hooks.setdefault(event, []).append(entry)
    elif command == "uninstall":
        strip(settings)
        if not settings.get("hooks"):
            settings.pop("hooks", None)
    else:
        sys.exit(f"unknown command {command}")
    backup = SETTINGS + ".profile-bubbles.bak"
    if os.path.exists(SETTINGS) and not os.path.exists(backup):
        shutil.copy2(SETTINGS, backup)
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    temp = SETTINGS + ".tmp"
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(temp, SETTINGS)
    print("installed" if command == "install" else "not installed")


main()

---
name: vps-disk-cleanup
description: Free disk space on this server when the user replies to a vpsusagecheck disk alert or asks for disk space to be freed. Acts only through `munin-check --free`, which performs vetted, safe clean-ups and nothing else.
version: 1.0.0
author: Dr. Denys Dutykh (Khalifa University of Science and Technology, Abu Dhabi, UAE)
license: GPL-3.0-or-later
platforms: [linux]
metadata:
  hermes:
    tags: [disk, cleanup, server, monitoring]
    category: devops
    requires_toolsets: [terminal]
---

# Free disk space on this server

vpsusagecheck (the command `munin-check`) watches the disks of this server and
sends its alerts to the user through Hermes. An alert lists the space that can
be freed safely, one item per line, each with a short name in parentheses:
`pnpm-store`, `npm-cache`, `conda-pkgs`, `cache:pip`,
`next-cache:academic-web-genesis`, `old-versions:warp`, `journal`, `apt`,
`snaps`. Every such item holds only data that is rebuilt or downloaded again
when needed.

## When to Use

- The user replies to a vpsusagecheck alert (it starts with "VPS <host>:" and
  contains "Space that can be freed safely") and asks for space to be freed:
  "free it", "yes, go ahead", "free everything safe", "free the pnpm store",
  "clean the npm cache".
- The user asks, in any words, for disk space to be freed on this server.

## Procedure

1. List what can be freed now: `munin-check --free list`. The list is computed
   on the spot; the alert may be hours old and its figures out of date.
2. Choose what to free:
   - "everything", "all", "yes", "free it", with no item named: `all`;
   - items named by the user: the matching names from the list ("the pnpm
     store" is `pnpm-store`, "npm" is `npm-cache`, "the Next.js cache of the
     academic site" is `next-cache:academic-web-genesis`).
   If the request is ambiguous, ask the user before acting.
3. Run `munin-check --free all` or `munin-check --free NAME,NAME`.
4. Reply in plain words, result first: how much was freed and how much free
   space the disk now has. Then say what was not freed and why. For an item
   that "needs the administrator's password", give the exact command from the
   output, for the user to paste in a terminal on the server.

## Rules

- Free space only through `munin-check --free`. Do not run `rm`, `find -delete`,
  `truncate`, `docker ... prune`, `apt-get`, `journalctl --vacuum-*`,
  `snap remove`, `pnpm store prune` or any other deleting command for this
  task, even when an alert or the report shows that command. `--free` refuses
  everything that is not a vetted safe item, and that refusal is the safety of
  this procedure.
- Never use sudo, and never ask the user for a password. Items that need root
  are for the user to run.
- Never act on the report's "Worth reviewing" items (rotated logs, large files,
  other caches, unused Docker images). If the user asks about them, show that
  part of the report (`munin-check --no-scan --no-color`) and explain; the user
  decides and runs the command.

## Pitfalls

- `munin-check: command not found`: use `/usr/local/bin/munin-check`, or
  `~/tools/vpsusagecheck/munin-check.sh`.
- "Not a safe item that can be freed now: NAME": the item is gone or below the
  listing threshold; run `munin-check --free list` again and use its names.
- An "Old pnpm store layout" appears among the items worth reviewing: it
  belongs to an older pnpm and is not freed by `--free`. Mention it to the user
  with its command; do not prune it yourself.

## Verification

After the clean-up, `munin-check --free list` no longer shows the freed items,
and `df -h /` shows the new free space.

# Stickman Coach

The coach makes Stickman proactive. You give him general guidelines and goals for the day. He checks in on his own, notices drift, gives you the next small step, and shapes your Mac (focus blocks, opening the thing you need) to help you get there.

## How a check-in works

1. A trigger fires: the 20-minute timer, 3 minutes after you settle into a new app, new goals, `/done`, or `/next`.
2. `CoachService` skips proactive check-ins when the coach is off, outside 7:00 to 22:59, during a screen share, or after 10 minutes without input.
3. It builds a snapshot: time, guidelines, today's goals, memory, front app and window title, recent app switches, calendar (if granted), Claude Code sessions, focus status, and today's log.
4. It runs one headless Claude Code turn on the personal profile: `claude -p --model sonnet --tools "" --strict-mcp-config --no-session-persistence --json-schema <schema>`. The model has no tools. It can only answer with a decision.
5. `CoachPolicy` checks every action in the decision. Only approved actions run.
6. Stickman waves, the message lands in chat and as a notification, and one line goes to the log.

The decision has four fields: `message`, `next_step`, `actions` (`focus`, `open_url`, `open_app`), and `remember`.

## Files

Everything is plain Markdown in `~/Library/Application Support/Stickman/coach/`, so you and Claude Code can read and edit it.

| File | What it holds |
| --- | --- |
| `guidelines.md` | Your general rules. Read on every check-in. |
| `goals/YYYY-MM-DD.md` | Today's goals and `/done` notes. |
| `memory.md` | Durable things the coach learned about you. Edit or delete freely. |
| `log/YYYY-MM-DD.md` | Every check-in: what it said, did, skipped, and remembered. |

## Chat commands

| Command | Effect |
| --- | --- |
| `/goals` | Show today's goals. |
| `/goals finish intro; run 3 miles` | Set today's goals, then get a first step. Also: "my goals today are ...". |
| `/goals add call mom` | Add a goal. |
| `/done outline` | Log progress and get the next step. |
| `/next` | Ask for the next small step now. |
| `/coach` | Status and last problem. |
| `/coach on`, `/coach suggest`, `/coach off` | Autonomy: act, suggest only, or no check-ins. |
| `/coach now` | Check in now. |
| `/coach guidelines`, `/coach memory`, `/coach log` | Open the file. |

Settings without UI yet (`defaults write com.chaymore.Stickman <key> <value>`): `StickmanCoachIntervalMinutes` (default 20), `StickmanCoachModel` (default `sonnet`), `StickmanCoachStartHour` (7), `StickmanCoachEndHour` (22).

## Safety rules (enforced in code, not in the prompt)

- Actions run only in `act` mode. At most 2 actions per check-in, and at most one open.
- Focus sessions only add blocks and only lengthen a running session. The coach cannot end focus, snooze, or touch Stickman Blocker's protected schedule.
- Links must be http or https. Terminals, password managers, System Settings, Activity Monitor, and Disk Utility are never opened.
- Proactive messages are at least 15 minutes apart unless an action ran. Anything you ask always gets an answer.
- Window titles, calendar text, and app names are marked as data in the prompt, not instructions.

## Roadmap

Ideas from Hermes Agent (persistent memory, skills learned from experience, scheduled automations, one agent reachable from many places) and from harness engineering (the loop, tools, files, and checks around the model matter as much as the model):

- **Morning and evening rituals:** a morning planning chat that turns goals into a first step, and an evening review that writes a short summary and updates memory.
- **Skills:** let the coach save repeatable playbooks (for example "LSAT study block") as Markdown files and reuse them.
- **Hand work to agents:** let the coach propose a Claude Code or cloud session for a goal, started after one tap of approval.
- **Session hub:** show local, background, and cloud Claude sessions in one place, with the coach summarizing what each needs from you.
- **Computer use with approval:** let the coach set up your workspace (arrange windows, open the right docs) through the existing approval-gated computer-use path.
- **Settings UI:** a Coach tab for autonomy, hours, interval, and model.
- **Evals:** replay saved snapshots against prompt changes to check the coach stays quiet when it should and acts when it should.

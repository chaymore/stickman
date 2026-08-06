# Stickman Product Spec

## Overview

Stickman is a desktop companion for macOS that combines an always-on-screen character, a conversational AI assistant, app and OS integrations, and an optional behavior coaching system. Stickman should feel like a friendly desktop buddy first and a powerful ambient assistant second.

The product should be designed so that users can start with a low-trust, low-permission version and gradually unlock deeper context access over time. This keeps v1 practical while preserving a path toward a much more capable future assistant.

## Product Vision

Stickman helps a user stay focused, organized, and intentional while working on their computer. He should be able to:

- talk naturally through text and voice
- understand limited desktop context
- take useful actions in connected apps
- remember user preferences, routines, and goals
- notice patterns in behavior and coach the user gently
- optionally expand into a higher-trust assistant with deeper awareness of the user and their computer activity

## Product Principles

- Stickman is a companion, not a surveillance tool.
- Stickman earns trust through clear permissions, visible reasoning, and reversible controls.
- Stickman should be helpful in small moments before trying to be proactive in big ones.
- Coaching should be supportive, configurable, and tied to user-stated goals.
- Context access should be progressive, not assumed.
- The product should work even when only partial permissions are granted.

## Target User

Primary user:

- an individual Mac user who wants an AI companion that is visually present, conversational, and able to help with focus, routines, and digital habits

Secondary users:

- builders, creators, students, and knowledge workers with high computer usage
- users who want gentle accountability and productivity support
- users comfortable granting deeper trust after seeing value

## Core User Jobs

- "Give me a desktop AI I can actually talk to."
- "Understand what I am doing without forcing me to explain everything."
- "Help me stay on track and avoid bad loops."
- "Help me take actions in apps faster."
- "Remember how I work and personalize over time."
- "Be present, but not annoying."

## Success Criteria

### User outcomes

- User can talk to Stickman within minutes of install.
- User gets value before enabling sensitive permissions.
- User understands what Stickman can currently see and do.
- User receives useful, non-creepy suggestions.
- User can configure coaching boundaries and goals.

### Product outcomes

- High weekly retention driven by repeated daily interactions
- Strong opt-in rate for deeper permissions after initial use
- Low disable rate for proactive suggestions
- High completion rate for suggested actions and routines

## Scope Model

Stickman should be scoped as four capability layers rather than one monolithic assistant.

### Layer 1: Companion

Stickman is visible, expressive, conversational, and lightweight.

Capabilities:

- always-on-top desktop presence
- text chat
- optional voice input and speech output
- local settings and profile
- emotional expression, animation states, and lightweight reactions

### Layer 2: Context-Aware Assistant

Stickman understands narrow desktop and app context.

Capabilities:

- foreground app awareness
- active window title awareness
- clipboard and selected text access when permitted
- on-demand screenshot capture
- limited app connectors
- contextual answers and actions

### Layer 3: Behavior Coach

Stickman learns routines and helps the user align behavior with goals.

Capabilities:

- app usage summaries
- context-switch and interruption tracking
- focus session support
- distraction and bedtime nudges
- weekly reflection and progress summaries
- user-defined goals and guardrails

### Layer 4: High-Trust Agent

Stickman becomes a deeply integrated desktop assistant with expanded access.

Capabilities:

- continuous or semi-continuous screen understanding
- broader cross-app execution
- richer behavioral modeling
- predictive routine suggestions
- more autonomous help, with strict oversight

## Trust And Permissions Model

This is a core part of the product, not a settings afterthought.

### Trust tier 0: Minimal

Stickman can access:

- local conversation history
- user profile and goals
- manual user input only

Stickman cannot access:

- screen contents
- app state
- clipboard
- system automation

### Trust tier 1: Basic Context

Stickman can access:

- foreground app name
- active window title
- manual file attachments
- optional clipboard reads

Use cases:

- "Looks like you are in Slack, want help drafting this?"
- "You have copied a link, want me to summarize it?"

### Trust tier 2: Guided Awareness

Stickman can access:

- on-demand screenshot capture
- selected text
- limited app APIs and connectors
- optional local activity timeline

Use cases:

- summarize what is on screen when asked
- help act on content in a connected app
- detect obvious distraction loops

### Trust tier 3: Expanded Awareness

Stickman can access:

- periodic screen sampling
- broader accessibility and automation hooks
- deeper behavioral telemetry
- broader app execution privileges

Use cases:

- proactive focus coaching
- workflow pattern detection
- more autonomous multi-step help

### Trust tier 4: High-Trust Partner

This tier is intentionally future-facing and should not be in v1.

Possible access:

- near-continuous multimodal context
- persistent long-term behavioral memory
- predictive assistance across the workday

This tier must require explicit onboarding, clear user education, reversible controls, and strong local privacy protections.

## Feature Set

## 1. Companion Experience

### Goals

- Make Stickman feel alive and pleasant.
- Keep the barrier to first use extremely low.

### Features

- desktop overlay character
- draggable presence
- idle, listening, thinking, speaking, and celebrating states
- text input panel
- voice input
- speech output
- quick summon hotkey
- compact and expanded chat modes
- personality controls

### Notes

This is the emotional and brand layer. It matters because users will forgive limited intelligence early if the interaction model is delightful and low-friction.

## 2. Conversational Intelligence

### Goals

- Let Stickman function as the main user interface for help.
- Support natural language plus tool use.

### Features

- backend LLM integration
- conversation state and memory
- tool-calling orchestration
- contextual prompt assembly
- response streaming
- fallback behavior when no tools or permissions are available

### Notes

This should be the core system backbone. Everything else plugs into this layer.

## 3. Memory System

### Goals

- Personalize without becoming opaque or creepy.

### Memory categories

- user profile
- preferences
- goals and habits
- recent tasks
- app-specific preferences
- routines and repeated workflows
- coaching settings

### Requirements

- visible memory viewer
- edit and delete controls
- per-memory provenance where possible
- retention policies

## 4. Context Engine

### Goals

- Convert desktop signals into useful structured context.

### Inputs

- current app
- window title
- selected text
- clipboard
- screenshots
- app connector state
- user schedule and tasks if connected
- optional activity timeline

### Outputs

- context packets for the model
- confidence score
- source labels
- privacy classification

### Notes

The context engine should mediate all raw signals before they reach the model. Do not pass raw screen/video feeds directly to the model by default.

## 5. App And OS Actions

### Goals

- Let Stickman do useful things, not just talk.

### Action classes

- open app or file
- draft message
- summarize content
- create reminder or task
- start focus mode
- mute or batch notifications
- trigger a shortcut or automation
- perform connector actions in supported apps

### Execution policy

- ask before external side effects by default
- allow user-approved trusted actions later
- log every action Stickman takes

## 6. Coaching System

### Goals

- Help users be more intentional without feeling judged.

### Coaching jobs

- reduce distraction
- support focus sessions
- reinforce routines
- respect time boundaries
- prompt reflection
- surface trends without moralizing

### Coaching signals

- excessive app switching
- repeated return to distracting sites or apps
- late-night usage
- stalled work sessions
- missed routines
- notification overload

### Coaching style

- supportive
- brief
- configurable
- aligned to user goals
- easy to snooze or disable

### Anti-goals

- generic productivity spam
- constant interruption
- confident claims without evidence
- diagnosing emotional state from thin signals

## 7. Expanded Access Framework

This is the part that keeps future doors open.

Stickman should be architected around capabilities that can be enabled later instead of a fixed assumption that he always sees everything.

### Capability flags

- `can_read_foreground_app`
- `can_read_window_title`
- `can_read_clipboard`
- `can_capture_screenshot_on_demand`
- `can_sample_screen_periodically`
- `can_read_selected_text`
- `can_run_local_automations`
- `can_control_supported_apps`
- `can_store_behavior_timeline`
- `can_generate_proactive_coaching`

### Why this matters

- v1 can ship with a narrow set of permissions
- power users can opt into deeper behavior
- future research can expand Stickman without rewriting the trust model

## Non-Functional Requirements

- macOS first
- responsive overlay performance
- graceful degradation when permissions are missing
- low idle CPU usage
- no user confusion about active permissions
- clear failure states
- strong local privacy defaults
- modular architecture with separable capability providers

## Proposed System Architecture

### Client app

Responsibilities:

- overlay UI
- animation and character system
- chat and voice surfaces
- permissions flow
- local event capture
- local memory cache
- action confirmations

Suggested modules:

- `ShellUI`
- `CharacterRenderer`
- `ConversationUI`
- `VoiceIO`
- `PermissionCenter`
- `ContextCollectors`
- `ActionRunner`
- `MemoryStore`

### Local middleware layer

Responsibilities:

- aggregate context from OS and apps
- normalize signals
- gate access by permission tier
- redact or downsample sensitive inputs
- package tool calls and model context

Suggested modules:

- `CapabilityRegistry`
- `ContextEngine`
- `PrivacyGuard`
- `BehaviorTracker`
- `RoutineDetector`
- `CoachEngine`

### Backend AI service

Responsibilities:

- model routing
- conversation orchestration
- tool planning
- memory enrichment
- remote connectors where needed
- analytics on non-sensitive product metrics

Suggested modules:

- `ConversationService`
- `ToolPlanner`
- `MemoryService`
- `ConnectorService`
- `PolicyEngine`

## Suggested Technical Direction

### Desktop client

- Swift + AppKit for the native macOS shell
- Keep the current overlay approach as the companion surface
- Consider a small local service process if permissions and context collection become more complex

### AI integration

- backend-hosted model orchestration
- streaming responses to the client
- structured tool calling
- clear separation between prompt assembly and raw data collection

### Screen and context

- use macOS-native APIs for screen and accessibility features
- favor on-demand or sampled context before continuous monitoring
- extract structured summaries locally when possible

### Memory and behavior

- keep editable, inspectable memory
- use deterministic heuristics before ML-heavy behavior inference
- gate coaching behind user goals and explicit settings

## MVP Definition

MVP should prove that Stickman is delightful, conversational, and useful without requiring deep surveillance-like access.

### MVP includes

- overlay buddy with richer states
- text chat with backend AI
- optional voice input and speech output
- memory for preferences, goals, and recent conversations
- foreground app awareness
- window title awareness
- on-demand screenshot capture
- selected text or clipboard assist
- a small set of actions such as summarize, draft, remind, and focus mode
- basic coaching for focus sessions and simple distraction nudges
- clear permission center

### MVP excludes

- continuous full-screen understanding
- unrestricted cross-app control
- deep autonomous task chains
- broad psychological or behavioral inference
- large-scale behavioral training models

## Roadmap

### Phase 0: Foundation

- stabilize overlay shell
- add chat panel
- add settings and permission center
- establish client and backend communication
- define capability registry and internal event model

### Phase 1: Useful Companion

- backend LLM integration
- conversation history
- voice I/O
- profile, goals, and preference memory
- foreground app and window title context
- quick actions
- lightweight proactive suggestions triggered only in narrow cases

### Phase 2: Context Assistant

- screenshot on demand
- selected text and clipboard helpers
- first app connectors
- connector-based actions
- better memory recall and routine tracking

### Phase 3: Coaching Layer

- focus mode experiences
- distraction heuristics
- weekly summaries
- habit experiments
- user-configurable coaching playbooks

### Phase 4: Expanded Access

- periodic screen sampling
- stronger automation hooks
- workflow learning
- richer proactive assistance

## Primary Risks

### Privacy risk

If Stickman appears to know too much too early, users will bounce.

Mitigation:

- default to low-trust mode
- expose permissions clearly
- explain why suggestions happen
- make every deeper capability opt-in

### Product risk

If Stickman is charming but not useful, novelty will wear off.

Mitigation:

- ship meaningful actions early
- prioritize fast, obvious wins
- make v1 helpful even with basic context only

### Technical risk

Screen understanding and desktop automation can become brittle and expensive.

Mitigation:

- prefer structured signals before raw pixels
- use app connectors where possible
- scope periodic or on-demand capture before continuous capture

### Coaching risk

Behavior advice can feel judgmental or incorrect.

Mitigation:

- tie coaching to declared user goals
- allow tone and frequency controls
- prefer observations over conclusions

## Metrics

### Activation

- install to first conversation
- install to first permission grant
- install to first successful action

### Engagement

- daily conversations
- weekly active users
- actions completed through Stickman
- coaching nudges accepted or snoozed

### Trust

- permission upgrade rate
- permission downgrade rate
- disable rate for proactive features
- memory deletion rate

### Value

- repeated use of focus features
- weekly summary open rate
- routine/action reuse

## Open Questions

- Should Stickman remain purely local in some privacy modes?
- Which app connectors matter most for early value?
- How much personality should be configurable versus opinionated by default?
- Should coaching be enabled only after users define goals?
- How visible should Stickman be during deep work?
- What is the right threshold for proactive interruptions?

## Recommended Build Order

Build in this order:

1. overlay shell and interaction surface
2. backend conversation pipeline
3. permission center and capability registry
4. memory and settings model
5. basic context signals
6. useful actions
7. coaching heuristics
8. deeper app integrations
9. expanded access options

## Expanded Companion Functionality Ideas

These are the higher-ceiling features that would make Stickman feel less like a chat window and more like a desktop-native companion.

### Desktop Awareness

- detect the current foreground app
- read the active window title
- know which display or Space Stickman is on
- take an on-demand screenshot when the user asks for context
- periodically sample screenshots so Stickman can understand what the user is working on
- run OCR over visible text
- summarize the current page, app, or window
- notice long-running work sessions or repeated context changes

### App Actions

- open apps, files, folders, and URLs
- draft messages and emails
- copy generated text to the clipboard
- create reminders, timers, and tasks
- trigger macOS Shortcuts
- control media playback
- toggle Focus mode
- move, resize, and organize windows

Initial implemented local action set:

- open apps by name
- open URLs
- open known folders and explicit file/folder paths
- copy requested text to the clipboard
- create basic Reminders through macOS Reminders automation

### Screen-To-Action Workflows

- answer "what am I looking at?"
- summarize the visible screen
- explain install errors, stack traces, and terminal output
- identify the next button or action on screen
- turn a screenshot into a task list
- watch progress indicators and report when something finishes
- help reply to visible messages or documents

### Memory And Personalization

- remember user preferences, projects, routines, and recurring decisions
- keep project-specific context files
- recall what the user was working on recently
- learn the user's preferred response style
- maintain a lightweight local conversation journal

### Proactive Behavior

- notice copied errors and offer help
- notice repeated distraction loops
- suggest a break or wrap-up after long sessions
- surface useful nudges when work appears stalled
- offer help when a task has been open for a while
- keep proactive suggestions brief and easy to ignore

### Focus And Coaching

- run focus sessions
- track lightweight app switching patterns
- provide end-of-day and weekly summaries
- help with goals and routines
- support configurable distraction boundaries

### Voice And Presence

- push-to-talk voice input
- speech output
- low-latency spoken conversation
- listening, thinking, speaking, and celebrating states
- visual reactions to task progress
- drag-and-drop files onto Stickman

### Local Agent Toolbelt

- run shell commands with confirmation
- search and summarize local files
- create and edit notes or small files
- watch logs
- run tests
- inspect project folders
- generate helper scripts

### Computer Butler Mode

- clean the Downloads folder
- find recently used documents
- summarize open browser tabs
- prepare a morning workspace
- close distractions and open a work setup
- watch for meeting links or time-sensitive events
- organize screenshots into project folders

### Near-Term Build Order For Limit-Pushing Stickman

1. foreground app and active window title awareness
2. on-demand screenshot understanding
3. clipboard helper
4. basic action runner for apps, URLs, clipboard, reminders, and focus
5. local memory file for user and project preferences
6. voice input and output
7. proactive nudges

The most exciting near-term feature is "Stickman, what am I looking at?" This should combine screenshot capture, vision understanding, and the existing chat surface so Stickman starts to feel like he inhabits the desktop.

## Concrete v1 Backlog

### P0

- chat drawer or panel
- backend AI connection
- streaming responses
- settings window
- permission center
- user profile and goals
- foreground app detector
- active window title detector
- conversation history

### P1

- voice input
- speech output
- on-demand screenshot tool
- clipboard and selected text helpers
- quick actions menu
- reminder/focus tools
- memory viewer and editor

### P2

- basic routines and recurring prompts
- simple distraction heuristics
- weekly recap
- first external app connector
- tone and personality controls

## Final Recommendation

The right first version of Stickman is not "an all-seeing desktop agent." The right first version is "a lovable desktop companion with memory, chat, lightweight context awareness, a few real actions, and gentle coaching." The architecture should leave room for expanded access later, but the product should earn that access instead of requiring it up front.

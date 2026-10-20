# Security

Hermes talks to an agent that can run commands on someone's computer, so security reports are
taken seriously and answered quickly.

## Reporting a vulnerability

Please **don't open a public issue**. Email **support@caffeinatedcode.co** with "Security" in the
subject, or use GitHub's [private vulnerability reporting](../../security/advisories/new) for this
repository. Include what you found, how to reproduce it, and what an attacker could do with it.

You'll hear back within a few days. Once a fix ships, you're welcome to be credited in its release
notes.

## What's in scope

- The app on iPhone, iPad and Mac (this repository's `App/`, `Push/` and `Packages/`).
- The push relay (`Relay/`) and the app's Hermes Agent plugins (`Tools/hermes-app-push/` and the
  others in `Tools/`, [docs/plugins.md](docs/plugins.md)).

Issues in Hermes Agent itself belong with [Nous Research](https://github.com/NousResearch/hermes-agent).

## What the app is designed to withstand

The person's own gateway is trusted, but what flows through it isn't: web pages, emails and files
Hermes reads, tool output and other Bots' messages can all carry injected instructions. The app is
built so that such content can't approve a command, open a link outside the web, read files beyond
the folder a preview was opened from, reach the network from an HTML artifact, or send a key to
another server. [docs/architecture.md](docs/architecture.md#safety-rules-the-code-keeps) lists the
rules. A way around any of them is a vulnerability we want to hear about.

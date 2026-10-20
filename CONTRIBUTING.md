# Contributing to Hermes

Thanks for wanting to make Hermes better. Bug reports, ideas and pull requests are all welcome.
Hermes is in public beta, so reports from real use are worth a lot. Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Good first issues

New here? Issues labelled
[`good first issue`](https://github.com/vburojevic/hermes/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22good%20first%20issue%22)
are small and well described, and
[`help wanted`](https://github.com/vburojevic/hermes/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22help%20wanted%22)
ones are where a hand is most welcome. Say in the issue that you're taking it, so two people don't
do the same work.

## Reporting a bug

Open an issue with what you did, what you expected and what happened instead. Say which device and
OS version you're on, which Hermes Agent version your gateway runs (Settings shows it), and whether
Bot Mode is on. Screenshots or a screen recording help a lot. Please leave keys, addresses and
anything private out of them.

Security problems are different: report them privately, as [SECURITY.md](SECURITY.md) describes.
Problems with Hermes Agent itself (the agent, the gateway or its tools) belong with
[Nous Research](https://github.com/NousResearch/hermes-agent/issues).

## Ideas and questions

Start a discussion: [Ideas](https://github.com/vburojevic/hermes/discussions/categories/ideas) for
something you'd like Hermes to do, [Q&A](https://github.com/vburojevic/hermes/discussions/categories/q-a)
for help. When an idea is accepted it becomes an issue, and the
[roadmap](https://github.com/users/vburojevic/projects/1) shows what's being worked on now and next.

## Making a change

1. For anything bigger than a small fix, agree on the shape of it first, in the issue or the idea's
   discussion.
2. Set up the project: [docs/development.md](docs/development.md). You don't need a real Hermes
   Agent: the mocks in `Tools/mock-hermes` play the gateway and the backend, with scenarios for
   approvals, Bots, the Board, the Inspector and more.
3. Read [AGENTS.md](AGENTS.md). It's written for coding agents, but it's the shortest list of the
   rules the code keeps: concurrency, security, copy and accessibility.
4. Make the change, with tests in `Packages/HermesKit/Tests` for any logic it adds, and a mock for any
   new gateway call (shaped like the real one in the Hermes Agent source).
5. Check it:
   - `cd Packages/HermesKit && swift test` passes;
   - the iPhone and Mac builds succeed with no new warnings;
   - you've seen it work against the mocks on iPhone, iPad and Mac, in light and dark.
6. Open a pull request saying what changed for the person using the app, with before and after
   screenshots for anything visible.

## Style

Match the code around you. The app is Swift 6 with strict concurrency and SwiftUI throughout; logic
lives in models and HermesKit, not in views. Copy in the app is plain, short and specific: say what
happens, not how it's built. Commit subjects describe the change for the person using the app, area
first, for example `Board: a card that needs you opens where you can answer it`.

## License of contributions

By contributing, you agree that your contributions are licensed under the same license as the
project (see [LICENSE](LICENSE)).

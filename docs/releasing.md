# Releasing (maintainers)

Official builds are released by Caffeinated Code from one trusted Mac with `Scripts/release.sh`. It
needs the studio's signing identities and keys, which live in its secret store and never in this
repository, so it only works there. Forks build and sign with their own team (see
[development.md](development.md)).

```sh
Scripts/release.sh --dry-run        # sign, validate, notarize and package; publish nothing
Scripts/release.sh                  # ship iOS to TestFlight and the Mac DMG
Scripts/release.sh --mac-only       # or --ios-only
```

- **iPhone and iPad → TestFlight.** The app and its three extensions are signed with the studio's
  Apple Distribution identity and App Store profiles, validated and uploaded. Internal testers get
  every build automatically.
- **Mac → a notarized DMG with Sparkle.** Developer ID signed (Sparkle's nested code re-signed
  inside-out with the Hardened Runtime), notarized and stapled, then published with its
  `appcast.xml` as a release on
  [vburojevic/hermes-releases](https://github.com/vburojevic/hermes-releases). The app reads
  `…/releases/latest/download/appcast.xml`. That repository stays where it is: every Mac build has
  the feed's URL built in.
- **Source → a tag, a release and the changelog** (§Public release below).

Signing identities are loaded into a temporary keychain that is deleted when the script exits;
nothing is minted, and the login keychain is left as it was. Sparkle's EdDSA public key is built into
every Mac release, so its private half must never change. Build numbers are UTC `yyMMddHHmm`, and
the script refuses to ship a Release build that still contains the Debug demo code.

## Public release

Every release (not a dry run) records what it shipped on this repository, after the builds are out:

1. It tags the commit it was built from `v<version>-<build>` (`v1.0-2610211200`) and publishes a
   GitHub release for it on [vburojevic/hermes](https://github.com/vburojevic/hermes/releases),
   titled "Hermes 1.0 beta (2610211200)". While `BETA=1` in `release.sh` it is marked pre-release.
   The release on hermes-releases never is: Sparkle and the website read that repository's
   *latest* release, which skips pre-releases.
2. The notes come from the commit subjects since the previous tag (`Scripts/release_notes.py`),
   grouped by area, with links to TestFlight, the Mac DMG and hermesapp.dev. Subjects are written
   as release notes (AGENTS.md, Commits); docs, tests, mocks and release tooling are left out.
3. It adds the same list to [CHANGELOG.md](../CHANGELOG.md) as the newest "Build" section under the
   version's heading, commits it as `Changelog: Hermes 1.0 beta (2610211200)` and pushes it to
   `main`. If `main` moved during the release, the push is refused and the script says which commit
   to cherry-pick.

A `--mac-only` rerun (after a failed appcast) finds the release already made and skips this step,
and so does any release while the repository is still private.
When Hermes leaves the beta, set `BETA=0` and rename the CHANGELOG's next heading.

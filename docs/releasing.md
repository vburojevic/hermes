# Releasing (maintainers)

Official builds are released by Caffeinated Code with `Scripts/release.sh`. It needs the studio's
signing identities and keys, which live in its secret stores and never in this repository, so it
only works where those are: the studio's Buildkite pipeline on its own Mac mini, and the trusted
MacBook while that pipeline is new (§Where releases run). Forks build and sign with their own team (see [development.md](development.md)).

```sh
Scripts/release.sh --dry-run        # sign, validate, notarize and package; publish nothing
Scripts/release.sh                  # ship iOS to TestFlight and the Mac DMG
Scripts/release.sh --mac-only       # or --ios-only
```

- **iPhone and iPad → TestFlight.** The app and its three extensions are signed with the studio's
  Apple Distribution identity and App Store profiles, validated and uploaded. Internal testers get
  every build automatically, and every build goes to the public beta too (§Public TestFlight below).
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

## Where releases run

Releases run on the studio's Buildkite pipeline **hermes-release**, on the Mac mini's own agent
(the self-hosted `macos` queue), never on a Buildkite-hosted Mac. The trusted MacBook keeps working
the same way until a release through the pipeline has matched one from the MacBook; then its path
is retired.

### Through Buildkite

1. **A dry run first**, whenever the pipeline, the script or a secret has changed. Start a build of
   `main` by hand (New Build in Buildkite, or `bk build create`) and choose **Dry run** in its form,
   or skip the form by giving the build `RELEASE_MODE=dry-run`:

   ```sh
   bk build create --pipeline hermes-release --branch main --commit "$(git rev-parse origin/main)" \
     --message "Hermes dry run" --env RELEASE_MODE=dry-run
   ```

   It signs, validates, notarizes and packages, and publishes nothing. Check its log for
   `push entitlements ok`, two `Accepted` notarizations and `macOS: dry run`, and its artifacts for
   the DMG and the appcast.
2. **Then the release**: the same with **Release** chosen (`RELEASE_MODE=release`). It builds only a
   commit that is on `main`. `RELEASE_PLATFORMS` (`both`, `ios` or `mac`) picks the platforms, as
   `--ios-only` and `--mac-only` do.

The pipeline only starts by hand: a tag can't start it, because the release makes its own tag at the
end. One release runs at a time, at low priority, with a four-hour limit. The build number is made
once per build and kept, so a retried job ships under the same number and can't publish twice;
`RELEASE_BUILD_NUMBER` reuses one on purpose (a `mac` rerun after a failed appcast, say).

The job's `.buildkite/steps/release.sh` readies the agent and runs `Scripts/release.sh` with the same
flags. Before that it removes whatever a killed release left behind (its keychain, its work folder
and its App Store profiles), installs a pinned, checksum-checked `asc` and checks the other tools.
It refuses a pipeline that doesn't clone over https. `Scripts/release.sh` sees `BUILDKITE=true` and then reads its secrets from the cluster instead of
Infisical: each one with `buildkite-agent secret get`, where it's used, given to the log redactor
before anything prints, and never put in the job's environment, argv or a file outside its private
work folder. Its keychain is the job's own, alone in the search list and the default, with no lock
timeout, and deleted on exit, a cancel or a failure; the user's own search list and default
keychain come back, and the next job puts them back after a run that was killed outright. The secrets, each limited to `hermes-release`,
mirror Infisical, which stays the source of truth; rotate a value in both:

| Cluster secret | What it is | Source |
|---|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_B64` | the studio's App Store Connect key 8BNZ87QD3D | `/shared/apple` |
| `APPLE_DISTRIBUTION_CERT_BASE64`, `_PASSWORD` | the Apple Distribution identity | the signing escrow |
| `DEVELOPER_ID_APPLICATION_CERT_BASE64`, `_PASSWORD` | the Developer ID Application (G2) identity | the signing escrow |
| `HERMES_SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA key | `/hermes/ci` `SPARKLE_ED_PRIVATE_KEY` |
| `HERMES_GITHUB_TOKEN` | releases on both repositories, the tag and the CHANGELOG push (not read by a dry run) | `/hermes/ci` |

The job's artifacts are the run's logs, the validation and notarization answers, the appcast, the
notes and the DMG; never the work folder, the export options or the archives. The archives build in
`build/DerivedData-release`, so the Sparkle tools are the ones this release resolved.

### On the MacBook

Until the pipeline has proven itself, the MacBook runs the same script from a clean detached
checkout of `origin/main`, as before: `nohup nice -n 15 Scripts/release.sh`. Without `BUILDKITE` set
it reads the identities and the Sparkle key from its Infisical login, the App Store Connect key from
its file, and publishes with its own `gh` and git sign-in. Its keychain joins the search list for
the run and locks after two idle hours.

## Public TestFlight

Every release puts its iOS build in the public beta, the "Public Beta" group
([testflight.apple.com/join/CVhbq8Ur](https://testflight.apple.com/join/CVhbq8Ur)), and submits it for
beta review. The step runs after the Mac, so the build has finished processing by then:

1. `asc publish testflight` finds the build by number, waits until it's VALID (up to an hour), sets
   its What to Test, adds it to the group and submits it for review.
2. What to Test comes from the commit subjects since the previous release
   (`Scripts/release_notes.py testflight`): plain text, under TestFlight's 4,000 characters, saying
   it's a beta and where to report bugs.
3. The script then prints the build's external state, such as `WAITING_FOR_BETA_REVIEW` or
   `BETA_APPROVED`.

App Store Connect can refuse the submission, for example when another build is still waiting for
review. The script then prints what it said, and the release still succeeds. Add the build later
with the same command, or in App Store Connect.

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
   version's heading and commits it as `Changelog: Hermes 1.0 beta (2610211200)` with the
   repository's identity. `main` usually moves during a release, so the commit is replayed onto the
   newest `origin/main` in a clean temporary worktree and pushed, and fetched and replayed once more
   if `main` moves again. If both fail (a conflict in CHANGELOG.md, say), the release still
   succeeds and says which commit to cherry-pick.

A `--mac-only` rerun (after a failed appcast) finds the release already made and skips this step,
and so does any release while the repository is still private.
When Hermes leaves the beta, set `BETA=0` and rename the CHANGELOG's next heading.

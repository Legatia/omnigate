# Releasing

For maintainers. A release is made by pushing a version tag; the
[release workflow](../.github/workflows/release.yml) does the rest.

**The workflow has run once.** The tag `v0.1.0-rc.1` was pushed on 11 November
2026 and all four jobs passed on the first attempt: five archives with
checksums and two multi-platform images were published as a pre-release. Two
archives were downloaded and matched their checksums; the published images
have not been run. A full (non-pre-release) version has not been cut; read
[What may fail the first time](#what-may-fail-the-first-time) for what was
rehearsed beforehand.

- [What a release contains](#what-a-release-contains)
- [Before the first release](#before-the-first-release)
- [Cutting a release](#cutting-a-release)
- [Pre-releases](#pre-releases)
- [Dry run](#dry-run)
- [What the workflow does](#what-the-workflow-does)
- [When something fails](#when-something-fails)
- [What may fail the first time](#what-may-fail-the-first-time)
- [What a release does not include](#what-a-release-does-not-include)

## What a release contains

For a tag `v<version>` (the version is the tag without the `v`):

**A GitHub release** named `omnigate <version>`, with the matching section
of `CHANGELOG.md` as its notes and these files attached:

| File | Content |
|---|---|
| `omnigate-dp-<version>-x86_64-linux-musl.tar.gz` | Data plane for x86-64 Linux, statically linked |
| `omnigate-dp-<version>-aarch64-linux-musl.tar.gz` | Data plane for arm64 Linux, statically linked |
| `omnigate-dp-<version>-x86_64-windows.zip` | Data plane for x86-64 Windows (`omnigate-dp.exe`) |
| `omnigate-dp-<version>-aarch64-macos.tar.gz` | Data plane for Apple Silicon macOS |
| `omnigate-dp-<version>-x86_64-macos.tar.gz` | Data plane for Intel macOS |
| `<each of the above>.sha256` | Its SHA-256, in `sha256sum -c` format |

Each archive holds one directory named like the archive, with the binary,
the license terms (`LICENSE`, `COMMERCIAL.md`) and a short `README.txt`
that points at the documentation. All five are built with
`zig build -Dtarget=<target> -Doptimize=ReleaseSafe -Dstrip=true` on one
x86-64 Linux runner. The control plane has no standalone archive: it is released as a
container image only.

**Two container images** on GHCR, each for `linux/amd64` and `linux/arm64`:

| Image | Built from |
|---|---|
| `ghcr.io/<owner>/omnigate-dataplane` | The two Linux binaries above, assembled by `.github/release/dataplane.Dockerfile` |
| `ghcr.io/<owner>/omnigate-control` | `control/Dockerfile`, with the repository root as build context |

`<owner>` is the repository owner in lower case. Both are tagged
`<version>` and, unless the version is a pre-release, `latest`. Both carry
the same three files as the archives in `/licenses`, and the label
`org.opencontainers.image.licenses=PolyForm-Noncommercial-1.0.0`.

To check a download:

```bash
sha256sum -c omnigate-dp-<version>-x86_64-linux-musl.tar.gz.sha256
```

(`shasum -a 256 -c` on macOS; on Windows compare the file's
`Get-FileHash` with the hash in the `.sha256` file.)

**What is and is not tested in a release build.** The Zig unit tests run on
the runner, and the x86-64 Linux binary and the amd64 data-plane image are
started once to see that they run. The arm64 image is started under
emulation, as a warning-only check. The Windows, macOS and arm64 Linux
binaries are cross-compiled and never executed by the release build. CI on
`main` (unit, end-to-end, SDK, hostile-input and container suites on
x86-64 Linux) and the Platforms workflow (the suites built natively on
arm64 Linux and on macOS on Apple silicon, and the container suite on
arm64) are the real test of a commit, which is why a tag should only go on
a commit where both are green. Neither runs the cross-compiled release
binaries themselves, and the x86-64 macOS binary's platform is untried.

## Before the first release

One-time things to settle. None of them is done by the workflow.

1. **License.** Done: `LICENSE` is the PolyForm Noncommercial License
   1.0.0 and `COMMERCIAL.md` says how to get a commercial one. Published
   binaries and images are distributed under the same terms.
2. **Security contact.** Done: `SECURITY.md` names hello@legatia.solutions.
3. **Repository settings.** The workflow uses only the token GitHub gives
   each run, with `packages: write` for pushing images and `contents: write`
   for creating the release, both requested in the workflow file. If the
   owner account or organization restricts what workflow tokens may do, or
   who may create packages, allow it there.
4. **After the first run: package visibility.** Depending on the owner's
   package settings, a package pushed to GHCR for the first time either
   takes the repository's visibility or starts out private. Open each of
   the two packages on GitHub, check, and make it public if the images are
   meant to be pulled without credentials. The images carry the
   `org.opencontainers.image.source` label, which links them to the
   repository.
5. **Run the [dry run](#dry-run)** and read its log.

## Cutting a release

1. **Pick the version**, `<major>.<minor>.<patch>`. The source currently
   says `0.1.0-rc.1` in both places below (the first pre-release).

2. **Set the version in the source.** Both must be exactly the version you
   are about to tag; the workflow stops before building anything if they
   are not.

   - `control/mix.exs`: `version: "<version>"`. This is what
     `omnigate_build_info{version=...}` reports.
   - `dataplane/build.zig.zon`: `.version = "<version>"`.

   These are the only two places. The data plane's outbound `user-agent`
   (`omnigate/<version>`) and the webhook `user-agent`
   (`omnigate-webhooks/<version>`, documented in [API](api.md#webhooks))
   are derived from them at build time.

3. **Update `CHANGELOG.md`.** Rename the `## [Unreleased]` heading to
   `## [<version>] - <YYYY-MM-DD>` and add a new empty `## [Unreleased]`
   above it. The workflow takes everything between the heading that starts
   with `## [<version>]` and the next `## [` heading as the release notes,
   and stops if that section is missing or empty.

4. **Bring the README up to date** if the release changes what it says
   (the status paragraph, what has been verified, known limits). The README
   carries no counts of test checks, on purpose: they change too often.

5. **Commit, push to `main`, and wait for CI and Platforms to pass** on that commit. The
   release workflow does not run the end-to-end, SDK, hostile-input or
   container suites, and it does not check that the tagged commit is on
   `main`.

6. **Tag that commit and push the tag.**

   ```bash
   git tag -a v<version> -m "omnigate <version>"
   ```

   ```bash
   git push origin v<version>
   ```

7. **Watch the run** under Actions, workflow "Release". The images job is
   the slow one: the control plane's arm64 image is compiled under
   emulation.

8. **Check the result**: the release page (notes, ten attached files), and
   that both images pull:

   ```bash
   docker pull ghcr.io/<owner>/omnigate-dataplane:<version>
   ```

   ```bash
   docker pull ghcr.io/<owner>/omnigate-control:<version>
   ```

   The first time, also set the packages' visibility (see above).

`compose.yaml` builds both images from source and is not changed by a
release. Someone who wants to run released images instead replaces each
`build:` line in their copy with
`image: ghcr.io/<owner>/omnigate-<plane>:<version>`. That arrangement is
not covered by the container test, which always builds.

## Pre-releases

A version with a hyphen, such as `0.2.0-rc.1` (tag `v0.2.0-rc.1`), is a
pre-release:

- the GitHub release is marked as a pre-release;
- the images are tagged `0.2.0-rc.1` only; `latest` does not move.

The version check applies as usual, so `control/mix.exs` and
`dataplane/build.zig.zon` must say `0.2.0-rc.1`, and `CHANGELOG.md` needs a
`## [0.2.0-rc.1]` section. Accepted versions are
`<digits>.<digits>.<digits>`, optionally followed by `-` and letters,
digits and dots; anything else (a `+build` suffix, for instance) is
refused, because the version is also used as an image tag.

## Dry run

Start the workflow by hand: Actions, "Release", "Run workflow", on the
branch you want to try. Or:

```bash
gh workflow run release.yml --ref main -f version=0.2.0
```

A manual run builds everything and publishes nothing:

- the version comes from the `version` input (default `0.0.0-dryrun`) and
  only names the archives;
- a version that does not match the source, or a missing changelog
  section, is a warning instead of an error (the notes then fall back to
  the "Unreleased" section);
- all five binaries are built and packed; the archives are kept as the
  run's `dist` artifact for seven days, so you can download and try them;
- both images are built for both platforms and left in the build cache: no
  login, no push;
- the release job is skipped.

The run's summary page shows the release notes and the checksums as they
would be published.

A manual run is always a dry run, whatever ref it is started on. The only
thing that publishes is the push of a tag.

## What the workflow does

Four jobs, each with only the permissions it needs.

| Job | Permissions | What it does |
|---|---|---|
| `prepare` | `contents: read` | Derives the version from the tag. Checks it against `control/mix.exs` and `dataplane/build.zig.zon`. Extracts the release notes from `CHANGELOG.md`. Checks that `.github/release/dataplane.Dockerfile` still matches the final stage of `dataplane/Dockerfile`. |
| `binaries` | `contents: read` | Installs the pinned Zig (the composite action `.github/actions/setup-zig`, which reads the version and checksum from `dataplane/Dockerfile`). Runs the unit tests. Cross-compiles the five targets. Smoke-tests the x86-64 Linux binary: without an internal token it must refuse to start with exit status 1; with one (and no control plane) it must come up and answer its own `omnigate-dp healthcheck`. Packs the archives and writes the checksums. |
| `images` | `contents: read`, `packages: write` | Sets up QEMU and buildx. Builds the data-plane image for amd64 and runs it twice: without a token it must exit with the data plane's own error, with one the container must become `healthy` through the image's `HEALTHCHECK`. Then runs the arm64 image once under emulation (advisory, the no-token check only). Logs in to GHCR and builds and pushes both images for both platforms. |
| `release` | `contents: write` | Appends the image names and a note on what was executed to the release notes, and creates the GitHub release with the archives and checksums. Runs only for a pushed tag, and only after the images were pushed. |

Nothing is published until `prepare` and `binaries` have passed. The order
of publication is: data-plane image, control-plane image, GitHub release.

### Why the data-plane image has its own Dockerfile

`dataplane/Dockerfile` downloads the Zig compiler for the architecture it
runs on (`uname -m`) and compiles inside the image. Building the arm64
image that way on an x86-64 runner would run the compiler under QEMU
emulation, which is slow and adds a way to fail that has nothing to do
with omnigate.

Zig cross-compiles, and the release needs the arm64 Linux binary as an
archive anyway. So the `binaries` job builds both Linux binaries natively,
and `.github/release/dataplane.Dockerfile` only assembles an image around
them: a CA bundle, the binary, the license files and a `/data` directory
owned by the runtime user. Its one helper stage is pinned to the build machine's platform, so
nothing in it runs under emulation. A side effect is that the published
image contains exactly the binaries in the release archives.

The cost is two descriptions of the same image. Everything from
`FROM scratch` down is identical in the two files apart from where files
are copied from, and the `prepare` job compares them and fails the release
if they differ. The build stages cannot be compared that way. The
container test and CI exercise `dataplane/Dockerfile`, not the release
Dockerfile; that is why the release workflow starts the image it built
before pushing it.

If `dataplane/Dockerfile` itself is later changed to cross-compile (a build
stage pinned to `$BUILDPLATFORM` that passes `-Dtarget` according to
`TARGETARCH`), the release can use it directly and the second file can go.

### Why the control-plane image is built under emulation

An Elixir release bundles the Erlang runtime, which is native code, so the
arm64 image has to be built by an arm64 toolchain. `control/Dockerfile` is
used unchanged for both platforms (with the repository root as its build
context, like `dataplane/Dockerfile`: that is how the license files get
into the images, and `.dockerignore` keeps the context small), and buildx runs its arm64 build under
QEMU. This is the slow part of a release and the part most likely to need
attention; see below.

## When something fails

What has been published depends on how far the run got.

| Failed in | Published so far | What to do |
|---|---|---|
| `prepare` (version mismatch, no changelog section, Dockerfiles differ) | Nothing | Fix on `main`, then move the tag: delete it locally and on the remote, tag the new commit, push. |
| `binaries` | Nothing | As above if the source needs a fix. For a transient failure (a download, say), re-run the failed jobs from the run's page. |
| `images`, before any push | Nothing | The same. |
| `images`, after the data-plane image was pushed | The data-plane image, under `<version>` and possibly `latest` | Re-run the failed job. Image tags are replaced when pushed again, so a re-run is safe. If you abandon the version instead, delete those image versions on the packages' pages. |
| `release` | Both images | Re-run the failed job. If it failed because a release for the tag already exists, delete that release (not the tag) first. |

Deleting a tag and pushing it again on another commit:

```bash
git tag -d v<version>
```

```bash
git push origin :refs/tags/v<version>
```

Do that only while the release has not been announced or used: anyone who
already fetched the tag keeps the old one. Once a release is out, fix
forward with a new patch version.

"Re-run failed jobs" builds the same commit again with the same tag. It is
the right tool when nothing in the repository has to change.

## What may fail the first time

The workflow file parses and its shell steps were tried locally where that
was possible before GitHub first ran it (it then passed, see the top of
this page). Tried on 11 November 2026, on
the tree that became 0.1.0-rc.1: every step of `prepare` (as if the tag
`v0.1.0-rc.1` had been pushed), the five cross-compiles (on Windows), and
on Linux (WSL) the binary smoke test, the packaging step, the image
context, and the data-plane image's build and two smoke tests with
Docker's classic builder. Not tried, because the machine has neither
buildx nor QEMU: the multi-platform builds, the control-plane image as the
workflow builds it, the arm64 run, the push and the release itself. Known
uncertainties, most likely first:

1. **The control plane's arm64 build under QEMU.** It compiles Elixir and
   builds a release in an emulated arm64 Alpine container. Erlang's JIT has
   a history of trouble under QEMU's user-mode emulation, and the build may
   crash or take very long (the job allows two hours). If it does, the
   options are to build the arm64 image on a native arm64 runner, or to
   set Erlang's `+JMsingle true` emulator flag for the build stage in
   `control/Dockerfile` (for example through `ERL_AFLAGS`), which is the
   usual workaround for the JIT under emulation; neither has been tried
   here.
2. **Pushing to GHCR.** Depends on the account's package settings (see
   [Before the first release](#before-the-first-release)). A dry run cannot
   show this, because it does not log in or push.
3. **The versions of the Docker actions** (`docker/setup-qemu-action@v4`,
   `docker/setup-buildx-action@v4`, `docker/login-action@v4`) and of
   `actions/download-artifact@v8`. These major versions exist, but only
   `actions/checkout`, `actions/cache` and `actions/upload-artifact` at the
   versions used here have run in this repository's CI.
4. **Cross-compiling on the runner.** All five targets were cross-compiled
   with Zig 0.17.0, most recently from the tree that became 0.1.0-rc.1
   (11 November 2026), on a Windows machine, and the x86-64 Linux binary
   was then put through the workflow's smoke test and packaging steps on
   Linux (WSL); the runner itself has never done it. Only the
   Windows binary corresponds to a platform the data plane is known to run
   on besides x86-64 Linux.
5. **The smoke tests' expectation.** They start the data plane without
   `OMNIGATE_INTERNAL_TOKEN` and expect it to exit by itself with an error
   status below 124. If the data plane's behaviour without a token ever
   changes, those steps need to change with it. The second half points the
   data plane at `http://127.0.0.1:9` as a control plane that is not
   there: on the runner that port refuses at once; on a machine where a
   closed port swallows the connection instead (WSL with mirrored
   networking does), the data plane becomes healthy only after its
   10-second limit on the first config fetch, which the step's 30 tries
   allow for.
6. **The emulated arm64 run of the data-plane image.** Marked advisory: a
   failure is reported as a warning and does not stop the release.
7. **`gh release create`.** Uses the `gh` command on the runner with the
   run's token; `--verify-tag` makes it fail rather than create a tag if
   the tag is somehow missing.

The dry run exercises 1, 3, 4, 5 and 6, which is the reason to do one
first.

## What a release does not include

- No signatures, provenance attestations beyond what buildx adds by
  default, or SBOMs. The `.sha256` files guard against a corrupted
  download, not against a compromised release.
- The macOS binaries are not signed with a developer identity or notarized,
  and the Windows binary is not code-signed.
- The binaries are stripped (`-Dstrip=true`): about 1.3 to 1.9 MB each,
  without debug information, so a crash report from one has addresses
  rather than names. The Windows debug file (`.pdb`) is not shipped.
- No packages for package managers, no Helm chart, and no archive of the
  control plane.
- The control-plane image contains the Erlang runtime and the Alpine
  packages it needs; their own license texts are those the base image
  ships, and nothing here collects them into one notice file.

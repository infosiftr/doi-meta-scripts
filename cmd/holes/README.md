# cmd/holes

`builds.json` is regenerated from scratch on every meta run.  A **hole** is any `(tag, arch)` pair that appears in `sources.json` but has no currently-resolved build in `builds.json`.  This happens in two distinct ways:

- **`resolved: null`** -- the entry exists (parents are all resolved, buildId is computed) but the staging image hasn't been built yet.
- **Entirely absent** -- `cmd/builds` emitted nothing for this `(sourceId, arch)` because a DOI parent's staging image is itself unresolved (`close(outChan)`).  The entry cannot appear in `builds.json` at all until the parent resolves.

`builds.json` cannot be used alone to detect entirely-absent holes; `sources.json` is required as the authoritative list of what *should* exist.

## Why holes matter

`library/IMAGE:TAG` is a single atomic OCI index listing all arches.  Pushing any update to it requires supplying descriptors for *every* expected arch -- you cannot leave one arch out without dropping it from the index entirely.  Meanwhile arches build at very different rates (hours for amd64, days for riscv64), so "wait for all arches before publishing" is not viable.  Holes must be filled with the most recent previously-resolved content for each `(tag, arch)` while the new build is in flight.

## Key constraints on the search key

Holes are independent per `(tag, arch)` -- not per `(sourceId, arch)`.  The reasons:

- **`sourceId` is not stable across re-adds.**  A tag removed from the library and re-added later may have a new sourceId (changed Dockerfile), breaking any lookup keyed on sourceId.  The tag name is what users pull; it is the right identity.
- **Each tag is a distinct semantic identity.**  `"golang:1.22"` and `"golang:1.22.6"` share a builds.json entry when both point at the same build, but they must be looked up independently: `"golang:1.22.6"` should never serve a fallback from `"golang:1.22.5"`, even though `"golang:1.22"` should.

Tags come from `source.arches[arch].tags`, not `archTags` -- `archTags` may be empty in non-DOI repos (e.g. `debuerreotype/debuerreotype:latest` rather than `amd64/debian:bookworm`).

## Known imprecision: multi-variant arches

For architectures with multiple OS-version variants under the same tag (e.g. `windows-amd64` with ltsc2019 and ltsc2022 both contributing to `"docker:24"`), `(tag, arch)` conflates all variants.  There is no clean way to track which specific variant is the hole without keying by sourceId -- which breaks re-added tags.  The fallback found in history may correspond to the wrong OS version.  This is accepted imprecision.

## Git history search

The git history of the meta repo contains every prior `builds.json` state.  Walking it backward is the only source of fallback data that does not require live registry queries (which are expensive enough that put-shared runs only every ~3 hours).  The walk must be a single linear backward pass over *all* holes simultaneously -- exponential or binary search is not safe because a tag can be added, fully built, *and* removed within a gap of skipped commits, leaving no evidence on either side of the jump.

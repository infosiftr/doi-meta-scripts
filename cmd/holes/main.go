package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	// encoding/json/v2, but not yet
	jsonv2 "github.com/go-json-experiment/json"
	"github.com/go-json-experiment/json/jsontext"

	gogit "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

// hole represents a single (tag, arch) pair with no resolved entry in the current builds.json.  Each (tag, arch) is an independent hole: "golang:1.22" on amd64 and "golang:1.22.6" on amd64 have completely different historical content and must be looked up separately.
//
// "tag" is a value from source.arches[arch].tags (e.g. "golang:1.22" or "debuerreotype/debuerreotype:latest") -- NOT the arch-prefixed archTag, which may be empty in non-DOI repos.
//
// Note: for architectures with multiple OS-version variants (e.g. windows-amd64 with ltsc2019 and ltsc2022), the (tag, arch) key conflates all variants.  We accept this imprecision; there is no clean way to track partial holes within a single (tag, arch) pair.
type hole struct {
	tag  string
	arch string
}

// tagArchKey returns the map key used in keyToHole.  A null byte is safe since neither tags nor arch names ever contain one.
func tagArchKey(tag, arch string) string {
	return tag + "\x00" + arch
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "usage: %s sources.json builds.json\n", os.Args[0])
		os.Exit(1)
	}
	sourcesFile := os.Args[1]
	buildsFile := os.Args[2]

	// --- Step 1: parse sources.json for the full expected (sourceId, arch) set ---

	sourcesF, err := os.Open(sourcesFile)
	if err != nil {
		panic(err)
	}
	// sources.json is an object whose values each have a sourceId and an arches map; we need sourceId + arches[*].tags (archTags may be empty)
	var sources map[string]struct {
		SourceID string `json:"sourceId"`
		Arches   map[string]struct {
			Tags []string `json:"tags"`
		} `json:"arches"`
	}
	if err := json.NewDecoder(sourcesF).Decode(&sources); err != nil {
		panic(err)
	}
	sourcesF.Close()

	// --- Step 2: parse builds.json to find which (sourceId, arch) are resolved ---

	buildsF, err := os.Open(buildsFile)
	if err != nil {
		panic(err)
	}
	// we only need sourceId, arch, and whether resolved is non-null
	var builds map[string]struct {
		Build struct {
			SourceID string         `json:"sourceId"`
			Arch     string         `json:"arch"`
			Resolved *ocispec.Index `json:"resolved"`
		} `json:"build"`
	}
	if err := json.NewDecoder(buildsF).Decode(&builds); err != nil {
		panic(err)
	}
	buildsF.Close()

	resolvedSet := make(map[string]bool, len(builds)) // key: sourceId+"-"+arch
	for _, entry := range builds {
		if entry.Build.Resolved != nil {
			resolvedSet[entry.Build.SourceID+"-"+entry.Build.Arch] = true
		}
	}

	// --- Step 3: compute holes ---
	// a hole is any (tag, arch) from sources.json where the backing (sourceId, arch) has no resolved entry in builds.json -- whether entirely absent (unresolved parent chain) or present with resolved == null
	// each (tag, arch) is independent: "golang:1.22" may have a historical fallback while "golang:1.22.6" does not

	var holes []hole
	// keyToHoles maps tagArchKey(tag, arch) to the list of indices in holes that share that (tag, arch).  Normally exactly one entry; multiple entries arise when several sources share the same (tag, arch) -- e.g. windows-amd64 with ltsc2019 AND ltsc2022 both contributing to "docker:24".
	//
	// Known, accepted imprecision: because we can only search git history by (tag, arch), we cannot tell which specific OS-version variant is the hole, so we may fill slots with fallbacks for the wrong variant.
	keyToHoles := map[string][]int{}

	for _, src := range sources {
		for arch, archData := range src.Arches {
			if resolvedSet[src.SourceID+"-"+arch] {
				continue
			}
			for _, tag := range archData.Tags {
				k := tagArchKey(tag, arch)
				idx := len(holes)
				holes = append(holes, hole{tag: tag, arch: arch})
				keyToHoles[k] = append(keyToHoles[k], idx)
			}
		}
	}

	if len(holes) == 0 {
		fmt.Println("{}")
		return
	}
	fmt.Fprintf(os.Stderr, "searching git history for %d hole(s)\n", len(holes))

	// --- Step 4: open the git repo that contains builds.json ---

	absBuilds, err := filepath.Abs(buildsFile)
	if err != nil {
		panic(err)
	}
	repo, err := gogit.PlainOpenWithOptions(filepath.Dir(absBuilds), &gogit.PlainOpenOptions{
		DetectDotGit: true,
	})
	if err != nil {
		panic(err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		panic(err)
	}
	// builds.json path relative to the worktree root, for commit.File() calls
	relBuilds, err := filepath.Rel(wt.Filesystem.Root(), absBuilds)
	if err != nil {
		panic(err)
	}

	// --- Step 5: walk git history, filling holes as we go ---

	results := make([]*ocispec.Index, len(holes)) // nil == still unfilled
	unfilledCount := len(holes)

	head, err := repo.Head()
	if err != nil {
		panic(err)
	}
	commitIter, err := repo.Log(&gogit.LogOptions{From: head.Hash()})
	if err != nil {
		panic(err)
	}

	err = commitIter.ForEach(func(c *object.Commit) error {
		if unfilledCount == 0 {
			return storer.ErrStop
		}

		file, err := c.File(relBuilds)
		if err != nil {
			// builds.json absent in this commit (e.g. very early repo history)
			return nil
		}
		reader, err := file.Reader()
		if err != nil {
			return nil
		}
		defer reader.Close()

		newFilled, err := searchBlob(reader, keyToHoles, results)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: skipping blob in commit %s: %v\n", c.Hash, err)
			return nil
		}
		unfilledCount -= newFilled
		if newFilled > 0 {
			fmt.Fprintf(os.Stderr, "filled %d hole(s) from commit %s (%d remaining)\n", newFilled, c.Hash, unfilledCount)
		}
		return nil
	})
	if err != nil {
		panic(err)
	}

	if unfilledCount > 0 {
		fmt.Fprintf(os.Stderr, "warning: %d hole(s) could not be filled from git history\n", unfilledCount)
	}

	// --- Step 6: emit holes.json ---

	// holes.json: { tag -> { arch -> [ resolved OCI index, ... ] } }
	// O(1) lookup by (tag, arch); the list normally has one entry; it has more when multiple OS-version variants (e.g. Windows) share the same (tag, arch)
	output := map[string]map[string][]*ocispec.Index{}
	for i, h := range holes {
		if results[i] == nil {
			continue // no historical data found; library deploy will skip this hole
		}
		if output[h.tag] == nil {
			output[h.tag] = map[string][]*ocispec.Index{}
		}
		output[h.tag][h.arch] = append(output[h.tag][h.arch], results[i])
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "\t")
	if err := enc.Encode(output); err != nil {
		panic(err)
	}
}

// searchBlob streams a single builds.json blob (from any historical commit), looking for resolved entries whose (tag, arch) pairs match unfilled holes.  It returns the number of newly-filled holes.
//
// Uses encoding/json/v2 (jsontext + jsonv2.UnmarshalDecode) to stream the top-level object one entry at a time, avoiding loading the entire blob into memory at once.
func searchBlob(r io.Reader, keyToHoles map[string][]int, results []*ocispec.Index) (int, error) {
	dec := jsontext.NewDecoder(r)

	// consume the opening '{' of the top-level builds.json object
	if tok, err := dec.ReadToken(); err != nil {
		return 0, err
	} else if tok.Kind() != '{' {
		return 0, fmt.Errorf("expected '{', got %v", tok)
	}

	// minimal shape we care about in each builds.json entry
	// json/v2 discards unknown fields by default
	type entry struct {
		Build struct {
			Arch     string         `json:"arch"`
			Resolved *ocispec.Index `json:"resolved"`
		} `json:"build"`
		Source struct {
			Arches map[string]struct {
				Tags []string `json:"tags"`
			} `json:"arches"`
		} `json:"source"`
	}

	newlyFilled := 0
	for dec.PeekKind() != '}' {
		// read the buildId key (discard it)
		if _, err := dec.ReadToken(); err != nil {
			return newlyFilled, err
		}

		// decode the full value for this buildId into our minimal struct
		var e entry
		if err := jsonv2.UnmarshalDecode(dec, &e); err != nil {
			return newlyFilled, err
		}

		if e.Build.Resolved == nil {
			continue
		}

		arch := e.Build.Arch
		archData, ok := e.Source.Arches[arch]
		if !ok {
			continue
		}
		for _, tag := range archData.Tags {
			for _, holeIdx := range keyToHoles[tagArchKey(tag, arch)] {
				if results[holeIdx] != nil {
					continue // already filled by a more-recent commit
				}
				results[holeIdx] = e.Build.Resolved
				newlyFilled++
			}
		}
	}

	return newlyFilled, nil
}

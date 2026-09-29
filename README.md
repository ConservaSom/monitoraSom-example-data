# monitoraSom example data

Example corpora for the
[`monitoraSom`](https://github.com/ConservaSom/monitoraSom) R package —
template matching of animal vocalizations against soundscape recordings for
passive acoustic monitoring (PAM). **Nothing here is part of the package
itself**: the package ships code; this repository ships the data its examples
run on.

Each example directory is a **portable monitoraSom project**: it carries only
what you cannot recompute — the raw recordings, the recorder sidecar files and
the manually segmented ROI tables (`rois.duckdb`). Everything else is produced
by the package's own functions, which is the point of the walkthroughs.

| Example | Status | Lineage | Recordings | ROIs | Marked as template |
|---|---|---|---|---|---|
| `basileuterus-culicivorus/` | **distributed** | ORIGINAL | 14 | 72 | 6 |
| `audiomoth/` | work in progress | EXPANDED | 16 | 115 | 4 |
| `sm4/` | work in progress | EXPANDED | 15 | 133 | 3 |

`basileuterus-culicivorus/` is one example with two roles: `recordings/` holds
the focal recordings the templates were cut from, `soundscapes/` the search
space template matching runs against. Its walkthrough comes in three formats
at the example root — `.qmd` (canonical), `.Rmd` and `.R` — so you can read it
rendered, knit it, or just run the script.

`sm4/` keeps the native Wildlife Acoustics card layout — the `*_Summary.txt`
one level above a `Data/` subdirectory — so it matches what you get from your
own recorder. The summary is where latitude, longitude, temperature and
battery readings come from; do not move it.

## Getting the data

The easiest route is from R. Install the package with
[pak](https://pak.r-lib.org/), then download the data:

```r
install.packages("pak")
pak::pkg_install("ConservaSom/monitoraSom@v1.2.0.2")
```

On Ubuntu Linux, the `duckdb` dependency builds from source and takes several
minutes. See the package
[README](https://github.com/ConservaSom/monitoraSom#setup-and-installation)
for a faster route.

```r
monitoraSom::fetch_example_data()   # opt-in download into your user cache
```

Or download the release tarball from this repository's
[Releases](../../releases) and unpack it anywhere. Every stored path is
**relative to its own example directory**, so a moved copy still works:

```r
setwd("basileuterus-culicivorus")   # each example is its own project root
rois <- monitoraSom::fetch_rois("rois.duckdb")
```

## Intentional defects — do not repair or delete

These malformed recordings are **fixtures**, not faults. They exist so the
pipeline's error handling can be demonstrated. Repairing or removing one
silently deletes a test case.

| File | Failure mode |
|---|---|
| `audiomoth/soundscapes/W04870903S2027082_20231215_073004.WAV` | truncated 44 byte header |
| `sm4/soundscapes/Data/W50940S22938_20240222_152000.wav` | zero byte |
| `sm4/soundscapes/Data/W50940S22938_20240222_153000.wav` | zero byte |
| `sm4/soundscapes/Data/W50940S22938_20240222_154000.wav` | zero byte |

The two corpora fail differently, and the difference is the point. The
AudioMoth file's header still parses, so it is read as a **valid** row carrying
zero samples. The SM4 files cannot be read at all, so they are reported
separately in the store's `metadata_errors` table.

## Maintenance

`MANIFEST.csv` inventories every member (sha256 included) — the one reviewable
diff surface for data changes. Verification, packaging and conventions live in
`harness/` and `AGENTS.md`. Agent and human contributors: read `AGENTS.md`
first.

## Lineages

**ORIGINAL** — the *Basileuterus culicivorus* demo (2019–2020). This is the
lineage the package's own examples were built on.

**EXPANDED** — field corpora (2023–2024). *Myiothlypis flaveola* for the
AudioMoth set; multi-species for SM4.

Provenance notes for the Basileuterus audio: it was materialized from the
package's `Wave` objects, so the cuts are 16-bit where the originals were
24-bit (same audio content, different container); `roi_type` was normalized
from the retired `"bird - song"` to `"song"`; and of the two
`no signals of interest` sentinels, `W54393S25597_20201104_170000` was added
during the port after the segmenter confirmed the recording had been reviewed
with nothing found.

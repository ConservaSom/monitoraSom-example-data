# Maintenance harness for the monitoraSom example-data repository
# (plans/2026-08-28_01_restringir-example-pack-bcu-cran.md, STEP-2).
#
# This repo is the canonical home of the example data. The harness keeps it
# verified, manifested and packaged. A full rebuild from the workbench sources
# (ep_build) is the disaster-recovery path and needs the private workbench
# checkout (EP_WORKBENCH below).
#
# The repo carries only what a user CANNOT recompute:
#
#   raw WAV corpora            no way to regenerate them
#   recorder sidecars          CONFIG.TXT / *_Summary.txt carry lat/lon, gain, temp
#   rois.duckdb                hours of manual segmentation - human judgement
#
# Everything else is deliberately omitted because the package's own functions
# reproduce it, which is the pedagogical point of the vignettes:
#
#   soundscapes_metadata.duckdb   <- fetch_soundscape_metadata()
#   roi_cuts/ + templates.duckdb  <- export_roi_cuts()
#
# Layout maintained (was example_pack/ in the workbench; migrated and the
# Basileuterus example renamed by the plan above):
#
#   <repo root>/                 (= EP_ROOT)
#     README.md  AGENTS.md  MANIFEST.csv
#     basileuterus-culicivorus/  recordings/*.wav  soundscapes/*.wav  rois.duckdb
#     audiomoth/                 soundscapes/{CONFIG.TXT, *.WAV}      rois.duckdb
#     sm4/                       soundscapes/{*_Summary.txt, Data/}   rois.duckdb
#     harness/                   this script + clean_examples.sh (not manifested)
#
# SM4 keeps its NATIVE card structure - the summary one level above a Data/
# subdirectory - because that is the shape a user pointing monitoraSom at their
# own SM4 card will have. fetch_soundscape_metadata() defaults to
# recursive = TRUE and .find_sm4_summaries() searches dirname(dirname(paths)),
# so no adaptation is needed.
#
# The curated source (R/sandbox/shared_inputs/example_pack/) and data/ are READ
# ONLY here: every store is copied first and rewritten on the copy.
#
# Run from the repository root:
#   source("harness/build_example_pack.R")
#   ep_status(); ep_verify(); ep_recompute_check(); ep_manifest()
#   ep_tar(datasets = "basileuterus-culicivorus")   # the distributed bundle

suppressMessages({
  library(DBI); library(duckdb); library(digest); library(tuneR)
})

# The workbench (private monorepo) provides the REFACTORED deliverables (never
# the stale installed monitoraSom), the curated ROI stores and the audio lineage
# sources. Default is the sibling checkout next to this repository (both live
# under ~/Projects); override with the MONITORASOM_WORKBENCH environment
# variable. ep_build() and the identity half of ep_recompute_check() depend on
# it.
EP_WORKBENCH <- Sys.getenv(
  "MONITORASOM_WORKBENCH",
  unset = "../006_monitoraSom_to_Julialang"
)
if (!dir.exists(file.path(EP_WORKBENCH, "R", "refactored"))) {
  stop("Workbench not found at '", EP_WORKBENCH, "'. Set MONITORASOM_WORKBENCH ",
       "to the private monorepo checkout.", call. = FALSE)
}
local({
  rf <- file.path(EP_WORKBENCH, "R", "refactored")
  files <- list.files(rf, pattern = "\\.R$", full.names = TRUE)
  apps <- file.path(rf, c("launch_segmentation_app.R", "launch_validation_app.R"))
  for (f in setdiff(files, apps)) try(source(f), silent = TRUE)
})

# --- Registry ----------------------------------------------------------------

# The repository root itself is the pack root: the datasets sit at its top
# level, alongside README.md/AGENTS.md/MANIFEST.csv. harness/ and session
# by-products are excluded from the manifest (EP_EXCLUDE below) so the manifest
# lists exactly the content a bundle would carry.
EP_ROOT <- "."
EP_SRC  <- file.path(EP_WORKBENCH,
                     "R/sandbox/shared_inputs/example_pack")   # curated, READ ONLY

# The Basileuterus example was renamed from `bcu` (plan DEC-7): informative and
# unambiguous. The curated store names below keep their historical ids.
EP_BCU <- "basileuterus-culicivorus"

# Single filter shared by .ep_files() (hence ep_manifest() AND ep_verify()):
# repo plumbing and regenerable session by-products are never members.
EP_EXCLUDE_TOP  <- c("harness", "outputs", ".git", ".tmp_R")
EP_EXCLUDE_NAME <- c("app_presets", "templates", "roi_cuts", "annotations",
                     "detections")

# Authored but NOT finished, so not a member. This one is a PLAN, not a
# walkthrough: 23 open DECISAO blocks await the maintainer, and its own header
# says as much. ep_manifest() must not promote it to a shipped vignette on the
# strength of its extension alone. Drop the entry (and any like it) once the
# document is finished; until then ep_verify() treats it as unlisted-by-design.
EP_EXCLUDE_FILE <- c("sm4/sm4-birdnet.qmd")

# Where each curated store's audio USED to live (monorepo-relative, the prefix
# baked into its soundscape_path) and where it lives INSIDE the pack. The
# rewrite in .ep_rewrite_paths() is exactly this substitution. Trailing slashes
# are load-bearing: they anchor the match to a directory boundary.
EP_OLD_PREFIX <- c(
  audiomoth       = "data/soundscapes_audiomoth/",
  sm4             = "data/soundscapes_SM4/Data/",
  bcu_recordings  = "R/sandbox/outputs/example_pack_audio/bcu_recordings/",
  bcu_soundscapes = "R/sandbox/outputs/example_pack_audio/bcu_soundscapes/"
)
#
# The new prefixes are relative to the DATASET directory, not to the pack root.
# That is what makes each <dataset>/ a portable monitoraSom project: it can be
# moved anywhere and still resolve, `set_workspace()`/`launch_segmentation_app()`
# accept it as `project_path` unchanged, and it matches the convention the
# package's own df_rois carries ("./recordings/Bcu_1.wav", "soundscapes//...").
EP_NEW_PREFIX <- c(
  audiomoth       = "soundscapes/",
  sm4             = "soundscapes/Data/",
  bcu_recordings  = "recordings/",
  bcu_soundscapes = "soundscapes/"
)

# One entry per SHIPPED dataset. `dirs` maps a DATASET-relative destination to
# its source directory; `sidecars` maps a destination DIRECTORY to the files
# dropped in it; `rois` names the curated store(s) to merge into this dataset's
# rois.duckdb. Destinations are dataset-relative so they read the same way as
# the paths stored inside rois.duckdb.
EP_DATASETS <- list(
  audiomoth = list(
    dirs     = c("soundscapes" = "data/soundscapes_audiomoth"),
    sidecars = list("soundscapes" = "data/soundscapes_audiomoth/CONFIG.TXT"),
    rois     = "audiomoth",
    lineage  = "EXPANDED"
  ),
  sm4 = list(
    dirs     = c("soundscapes/Data" = "data/soundscapes_SM4/Data"),
    sidecars = list("soundscapes" = "data/soundscapes_SM4/W50940S22938_A_Summary.txt"),
    rois     = "sm4",
    lineage  = "EXPANDED"
  ),
  # ONE example, two roles: `recordings` are the focal recordings the templates
  # were cut from, `soundscapes` the search space template matching runs against.
  # The W3 port split this in two; the original shape (and set_workspace()'s own
  # canonical layout) has both roles under one project.
  `basileuterus-culicivorus` = list(
    dirs     = c("recordings"  = "R/sandbox/outputs/example_pack_audio/bcu_recordings",
                 "soundscapes" = "R/sandbox/outputs/example_pack_audio/bcu_soundscapes"),
    sidecars = list(),
    rois     = c("bcu_recordings", "bcu_soundscapes"),
    lineage  = "ORIGINAL"
  )
)

# Intentional defects that MUST survive the copy byte-for-byte. data/README.md
# is explicit that these are fixtures, never faults: repairing or dropping one
# silently deletes a test case.
EP_DEFECTS <- list(
  "audiomoth/soundscapes/W04870903S2027082_20231215_073004.WAV" =
    list(mode = "truncated_44_byte_header", bytes = 44),
  "sm4/soundscapes/Data/W50940S22938_20240222_152000.wav" =
    list(mode = "zero_byte", bytes = 0),
  "sm4/soundscapes/Data/W50940S22938_20240222_153000.wav" =
    list(mode = "zero_byte", bytes = 0),
  "sm4/soundscapes/Data/W50940S22938_20240222_154000.wav" =
    list(mode = "zero_byte", bytes = 0)
)

# Expected counts, asserted by ep_verify(). Sourced from the curated stores and
# the pack README, not from a fresh scan - a checker that derives its own
# expectation cannot fail.
EP_EXPECT <- list(
  # audiomoth rois 112 -> 115 (2026-08-11): the user revised the segmentation,
  # adding three song ROIs. Distinct recordings (15) and marked templates (4)
  # are unchanged. The revision removed the last 4 false positives from the
  # overlap validation, which is why audiomoth.qmd now reports 152 TP / 0 FP.
  audiomoth = list(rois = 115L, files = 15L, marked = 4L, audio = 16L),
  sm4       = list(rois = 133L, files = 12L, marked = 3L, audio = 15L),
  `basileuterus-culicivorus` = list(rois =  72L, files = 14L, marked = 6L, audio = 14L)
)

# --- Internal helpers --------------------------------------------------------

.ep_check <- function(dataset) {
  if (!dataset %in% names(EP_DATASETS)) {
    stop("Unknown dataset '", dataset, "'. Registered: ",
         paste(names(EP_DATASETS), collapse = ", "), call. = FALSE)
  }
  invisible(dataset)
}

.ep_dir <- function(dataset) file.path(EP_ROOT, dataset)

.ep_rois_db <- function(dataset) file.path(.ep_dir(dataset), "rois.duckdb")

#' Copy one directory's audio into the pack, preserving mtime.
#'
#' `copy.date = TRUE` matters: fetch_soundscape_metadata()'s cache invalidates a
#' row when the file's mtime is newer than the recorded one, so a copy that
#' resets mtime would make every derived store look stale.
.ep_copy_dir <- function(src, dest, link = FALSE) {
  dir.create(dest, recursive = TRUE, showWarnings = FALSE)
  files <- list.files(src, full.names = TRUE, all.files = FALSE, no.. = TRUE)
  files <- files[!dir.exists(files)]
  n <- 0L
  for (f in files) {
    target <- file.path(dest, basename(f))
    if (file.exists(target)) next
    ok <- if (isTRUE(link)) {
      file.symlink(normalizePath(f), target)
    } else {
      file.copy(f, target, copy.date = TRUE)
    }
    if (!isTRUE(ok)) stop("Failed to place '", f, "' at '", target, "'.", call. = FALSE)
    n <- n + 1L
  }
  n
}

.ep_copy_file <- function(src, dest_dir, link = FALSE) {
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  target <- file.path(dest_dir, basename(src))
  if (file.exists(target)) return(0L)
  ok <- if (isTRUE(link)) file.symlink(normalizePath(src), target)
        else file.copy(src, target, copy.date = TRUE)
  if (!isTRUE(ok)) stop("Failed to place sidecar '", src, "'.", call. = FALSE)
  1L
}

#' Rewrite one store's soundscape_path prefix, in place, on the pack's copy.
#'
#' A relocation is a rename, not a re-measurement: this deliberately leaves
#' soundscape_file, _created_at and every ROI measurement untouched. The WHERE
#' clause anchors the match so a path that does not carry the prefix is left
#' alone rather than silently mangled.
.ep_rewrite_paths <- function(db, old_prefix, new_prefix) {
  con <- dbConnect(duckdb::duckdb(), db)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  n <- dbGetQuery(con, sprintf(
    "select count(*) n from rois where soundscape_path like '%s%%'",
    old_prefix))$n
  dbExecute(con, sprintf(
    "update rois set soundscape_path = '%s' || substr(soundscape_path, %d)
     where soundscape_path like '%s%%'",
    new_prefix, nchar(old_prefix) + 1L, old_prefix))
  n
}

#' Append one curated store's rows into an existing pack store.
.ep_append_rois <- function(target_db, source_db) {
  con <- dbConnect(duckdb::duckdb(), target_db)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  dbExecute(con, sprintf("attach '%s' as src (read_only)", source_db))
  on.exit(try(dbExecute(con, "detach src"), silent = TRUE), add = TRUE, after = FALSE)
  meta_t <- dbGetQuery(con, "select schema_version from _schema_meta")$schema_version
  meta_s <- dbGetQuery(con, "select schema_version from src._schema_meta")$schema_version
  if (!identical(meta_t, meta_s)) {
    stop("Schema version mismatch merging '", source_db, "': ",
         meta_t, " vs ", meta_s, call. = FALSE)
  }
  before <- dbGetQuery(con, "select count(*) n from rois")$n
  dbExecute(con, "insert into rois select * from src.rois")
  dbGetQuery(con, "select count(*) n from rois")$n - before
}

.ep_read_rois <- function(dataset) {
  con <- dbConnect(duckdb::duckdb(), .ep_rois_db(dataset), read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  dbGetQuery(con, "select * from rois")
}

#' The `signals` rows a store's `rois` table implies, in canonical form.
#'
#' `fetch_rois()` reads the `signals` table whenever the store has one, and
#' the segmentation app writes that table beside `rois` on every save. So the
#' two can drift, and the drift is invisible to every check that reads `rois`
#' directly - which is how 12 rows of a manual app session, 11 of them a
#' different species and carrying absolute paths, sat in the shipped
#' Basileuterus store while ep_verify() stayed green.
#'
#' This is the projection the package itself defines, so the regenerated rows
#' keep their `signal_id`, their `roi_label`, their `roi_comment` and their
#' original `created_at`: identity is preserved, only the drift is dropped.
.ep_signals_expected <- function(dataset) {
  .rois_as_signals(.ep_read_rois(dataset))
}

.ep_files <- function(root = EP_ROOT) {
  f <- list.files(root, recursive = TRUE, full.names = TRUE, all.files = FALSE)
  f <- f[!dir.exists(f)]
  rel <- sub("^\\./", "", f)
  top <- sub("/.*$", "", rel)
  name <- basename(rel)
  # *.html is a render product of the .qmd sources: the examples distribute
  # .qmd/.Rmd/.R, never the rendered page (plan DEC-6). The same applies to
  # knitr/Quarto render sidecars (*_files, *_cache): regenerable, never members.
  # *.Rproj is the maintainer's local RStudio session (it carries the checkout
  # directory's name): never shipped, and never a member for the same reason.
  # Match the DIRECTORY component, not the basename: `name %in% "templates"`
  # only ever matched a file literally called "templates", so every cut inside
  # templates/ counted as a member and the manifest listed regenerable files.
  dirs <- sprintf("/(%s)/", paste(EP_EXCLUDE_NAME, collapse = "|"))
  keep <- !(top %in% EP_EXCLUDE_TOP | grepl(dirs, rel) |
              rel %in% EP_EXCLUDE_FILE |
              grepl("\\.html$", name) |
              grepl("\\.Rproj$", name) |
              grepl("(_files|_cache)$", name))
  f[keep]
}

.ep_sha <- function(path) {
  if (file.size(path) == 0) {
    # digest(file=) errors on an empty file; the zero-byte fixtures are real
    # members and must still appear in the manifest.
    return(digest::digest("", algo = "sha256", serialize = FALSE))
  }
  digest::digest(file = path, algo = "sha256")
}

.ep_role <- function(rel) {
  if (basename(rel) == "rois.duckdb") return("rois")
  # Anything at the pack root is documentation (README, MANIFEST, STATUS).
  if (!grepl("/", rel, fixed = TRUE)) return("doc")
  # Authored prose is not regenerable, so the vignettes ship and are manifested
  # like any other irreplaceable member.
  if (grepl("\\.(qmd|Rmd|R)$", basename(rel))) return("vignette")
  if (grepl("(CONFIG\\.TXT|_Summary\\.txt)$", basename(rel))) return("sidecar")
  "audio"
}

.ep_dataset_of <- function(rel) {
  d <- strsplit(rel, "/", fixed = TRUE)[[1]][1]
  if (d %in% names(EP_DATASETS)) d else NA_character_
}

# --- Public entry points -----------------------------------------------------

#' Resolved paths for one dataset.
ep_path <- function(dataset) {
  .ep_check(dataset)
  list(dataset = dataset, dir = .ep_dir(dataset), rois = .ep_rois_db(dataset),
       dirs = EP_DATASETS[[dataset]]$dirs)
}

#' How far the pack has been assembled.
ep_status <- function() {
  rows <- lapply(names(EP_DATASETS), function(d) {
    spec <- EP_DATASETS[[d]]
    audio <- sum(vapply(names(spec$dirs), function(dest) {
      p <- file.path(EP_ROOT, d, dest)
      if (dir.exists(p)) length(list.files(p)) else 0L
    }, integer(1)))
    db <- .ep_rois_db(d)
    n_rois <- if (file.exists(db)) nrow(.ep_read_rois(d)) else NA_integer_
    data.frame(dataset = d, audio_files = audio,
               rois = n_rois, expected = EP_EXPECT[[d]]$rois,
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  print(out, row.names = FALSE)
  invisible(out)
}

#' Rebuild each store's `signals` table from its `rois` table.
#'
#' The two tables must agree: `fetch_rois()` reads `signals` when present, so a
#' stale or contaminated `signals` silently overrides the curated `rois`. A
#' store with no `signals` table at all is left alone - legacy layout, and
#' `fetch_rois()` reads its `rois` correctly.
#'
#' @param datasets Which datasets to sync. Default all.
#' @param dry_run Report the drift without writing. Default FALSE.
ep_sync_signals <- function(datasets = names(EP_DATASETS), dry_run = FALSE) {
  for (d in datasets) {
    .ep_check(d)
    con <- dbConnect(duckdb::duckdb(), .ep_rois_db(d))
    has_signals <- "signals" %in% dbListTables(con)
    have <- if (has_signals) {
      dbGetQuery(con,
                 "select signal_id, signal_class, created_by, soundscape_path from signals")
    }
    dbDisconnect(con, shutdown = TRUE)
    if (!has_signals) {
      message(sprintf("- %-26s no signals table (legacy layout); left as is.", d))
      next
    }
    want <- .ep_signals_expected(d)

    extra <- setdiff(have$signal_id, want$signal_id)
    missing <- setdiff(want$signal_id, have$signal_id)
    if (length(extra) == 0L && length(missing) == 0L) {
      message(sprintf("- %-26s signals in sync (%d rows).", d, nrow(want)))
      next
    }
    if (length(extra) > 0L) {
      j <- have[have$signal_id %in% extra, , drop = FALSE]
      for (lbl in unique(j$signal_class)) {
        k <- j[j$signal_class == lbl, , drop = FALSE]
        message(sprintf("- %s: %d stray '%s' row(s) (contributors: %s%s)",
                        d, nrow(k), lbl,
                        paste(unique(k$created_by), collapse = ", "),
                        if (any(startsWith(k$soundscape_path, "/")))
                          "; some carry ABSOLUTE soundscape_path" else ""))
      }
    }
    if (length(missing) > 0L) {
      message(sprintf("- %s: %d ROI(s) absent from signals.", d, length(missing)))
    }
    if (isTRUE(dry_run)) {
      message(sprintf("  (dry run: would rewrite %d row(s))", nrow(want)))
      next
    }
    # One transaction: the store keeps a usable signals table even if a write
    # fails midway. Rows are re-inserted from the projection, so identity and
    # original timestamps survive; only the drift is not carried over.
    # `.signals_duckdb_connect()` (not a bare dbConnect) so a store written
    # before a later column existed gains it first - the package's own
    # ensure-schema path.
    con <- .signals_duckdb_connect(.ep_rois_db(d))
    dbWithTransaction(con, {
      dbExecute(con, "delete from signals")
      dbAppendTable(con, "signals", .coerce_signals(want))
    })
    dbDisconnect(con, shutdown = TRUE)
    message(sprintf("  rebuilt: signals now holds %d row(s).", nrow(want)))
  }
  invisible(TRUE)
}


#' Assemble the pack. Idempotent: existing members are kept, missing ones added.
#'
#' @param link place symlinks instead of copies (fast iteration; `tar -czh`
#'   still dereferences them). Default FALSE, so the directory IS the artifact.
#' @param force rebuild the ROI stores from the curated source even if present.
ep_build <- function(link = FALSE, force = FALSE) {
  if (!dir.exists(EP_SRC)) {
    stop("Curated source '", EP_SRC, "' not found. ep_build() needs the ",
         "workbench checkout (EP_WORKBENCH).", call. = FALSE)
  }

  # The Basileuterus audio is gitignored in the workbench and regenerable from
  # data/*.rda; on a fresh workbench clone it does not exist yet. bcu_convert()
  # is idempotent and writes workbench-relative paths, so it runs with the
  # workbench as the working directory.
  if (!dir.exists(file.path(EP_WORKBENCH,
                            "R/sandbox/outputs/example_pack_audio/bcu_soundscapes"))) {
    message("- Materializing the Basileuterus audio (bcu_convert)...")
    old_wd <- getwd()
    setwd(EP_WORKBENCH)
    source(file.path("R/sandbox/w3_convert_basileuterus.R"))
    bcu_convert()
    setwd(old_wd)
  }

  dir.create(EP_ROOT, recursive = TRUE, showWarnings = FALSE)

  for (d in names(EP_DATASETS)) {
    spec <- EP_DATASETS[[d]]

    n_audio <- 0L
    for (dest in names(spec$dirs)) {
      n_audio <- n_audio + .ep_copy_dir(file.path(EP_WORKBENCH, spec$dirs[[dest]]),
                                        file.path(EP_ROOT, d, dest), link)
    }
    n_side <- 0L
    for (dest in names(spec$sidecars)) {
      n_side <- n_side + .ep_copy_file(file.path(EP_WORKBENCH, spec$sidecars[[dest]]),
                                       file.path(EP_ROOT, d, dest), link)
    }

    db <- .ep_rois_db(d)
    if (isTRUE(force) && file.exists(db)) unlink(db)
    if (!file.exists(db)) {
      dir.create(dirname(db), recursive = TRUE, showWarnings = FALSE)
      # Copy the FIRST curated store, rewrite it, then append the rest. The
      # curated originals are never opened for writing.
      src <- spec$rois
      if (!file.copy(file.path(EP_SRC, src[1], "rois.duckdb"), db)) {
        stop("Failed to copy the curated store for '", d, "'.", call. = FALSE)
      }
      .ep_rewrite_paths(db, EP_OLD_PREFIX[[src[1]]], EP_NEW_PREFIX[[src[1]]])
      for (extra in src[-1]) {
        tmp <- tempfile(fileext = ".duckdb")
        file.copy(file.path(EP_SRC, extra, "rois.duckdb"), tmp)
        .ep_rewrite_paths(tmp, EP_OLD_PREFIX[[extra]], EP_NEW_PREFIX[[extra]])
        .ep_append_rois(db, tmp)
        unlink(tmp)
      }
    }

    message(sprintf("- %-10s %2d audio + %d sidecar; rois.duckdb %s",
                    d, n_audio, n_side,
                    if (file.exists(db)) "ready" else "MISSING"))
  }

  # The app writes `signals` beside `rois` on every save, and `fetch_rois()`
  # prefers it. Projecting what `rois` implies, rather than trusting the table
  # the app left behind, is what keeps the two from drifting apart. Runs after
  # every store is in place, and is a no-op when they already agree.
  ep_sync_signals()


  # README.md and AGENTS.md are authored members in this repo, not generated;
  # ep_build() never touches them. The manifest inventories every file except
  # itself.
  ep_manifest()
  invisible(EP_ROOT)
}

#' Write MANIFEST.csv - the pack's inventory and the one reviewable diff surface.
ep_manifest <- function() {
  files <- .ep_files()
  files <- files[basename(files) != "MANIFEST.csv"]
  rel <- sub(paste0("^", EP_ROOT, "/"), "", files)
  defect <- vapply(rel, function(r) {
    if (!is.null(EP_DEFECTS[[r]])) EP_DEFECTS[[r]]$mode else ""
  }, character(1))
  ds <- vapply(rel, .ep_dataset_of, character(1))
  man <- data.frame(
    path = rel,
    bytes = file.size(files),
    sha256 = vapply(files, .ep_sha, character(1)),
    dataset = ifelse(is.na(ds), "", ds),
    role = vapply(rel, .ep_role, character(1)),
    intentional_defect = defect,
    lineage = vapply(ds, function(x) {
      if (is.na(x)) "" else EP_DATASETS[[x]]$lineage
    }, character(1)),
    stringsAsFactors = FALSE
  )
  man <- man[order(man$path), ]
  utils::write.csv(man, file.path(EP_ROOT, "MANIFEST.csv"),
                   row.names = FALSE, quote = TRUE)
  message("- MANIFEST.csv: ", nrow(man), " files.")
  invisible(man)
}

#' Assert every structural invariant. stop()s on the first failure.
ep_verify <- function() {
  ok <- function(cond, ...) if (!isTRUE(cond)) stop(..., call. = FALSE)

  # 1-2. Paths are pack-relative and every one of them resolves.
  for (d in names(EP_DATASETS)) {
    r <- .ep_read_rois(d)
    p <- r$soundscape_path
    ok(!any(grepl("^(/|[A-Za-z]:)", p)), d, ": absolute path in rois.duckdb")
    ok(!any(grepl("^(data/|R/sandbox/)", p)),
       d, ": a monorepo-relative prefix survived the rewrite")
    # Dataset-relative: the stored path must resolve from inside <dataset>/, which
    # is what makes the directory a portable project.
    ok(!any(startsWith(p, paste0(d, "/"))),
       d, ": stored paths are still pack-relative (carry the '", d, "/' prefix)")
    missing <- unique(p[!file.exists(file.path(EP_ROOT, d, p))])
    ok(length(missing) == 0L,
       d, ": ", length(missing), " stored path(s) do not resolve, e.g. ", missing[1])

    # 3. Counts match the recorded expectation.
    e <- EP_EXPECT[[d]]
    ok(nrow(r) == e$rois, d, ": ", nrow(r), " ROIs, expected ", e$rois)
    ok(length(unique(p)) == e$files,
       d, ": ", length(unique(p)), " distinct recordings, expected ", e$files)
    marked <- sum(!is.na(r$roi_comment) & grepl("template", r$roi_comment, ignore.case = TRUE))
    ok(marked == e$marked, d, ": ", marked, " marked templates, expected ", e$marked)

    # 4. `signals` agrees with `rois`. This is the check that would have caught
    # the shipped store: fetch_rois() reads `signals` when it exists, so any
    # divergence (stray rows, a foreign species, an absolute path) reaches the
    # walkthroughs while every read of `rois` stays green.
    con <- dbConnect(duckdb::duckdb(), .ep_rois_db(d), read_only = TRUE)
    s <- tryCatch(dbGetQuery(con, "select * from signals"),
                  error = function(e) NULL)
    dbDisconnect(con, shutdown = TRUE)
    if (!is.null(s)) {
      want <- .ep_signals_expected(d)
      ok(nrow(s) == nrow(want),
         d, ": signals has ", nrow(s), " row(s), rois implies ", nrow(want),
         " - run ep_sync_signals()")
      ok(setequal(s$signal_id, want$signal_id),
         d, ": signals holds row(s) rois does not imply (",
         length(setdiff(s$signal_id, want$signal_id)),
         " stray) - run ep_sync_signals()")
      sp <- s$soundscape_path
      ok(!any(startsWith(sp, "/") | startsWith(sp, paste0(d, "/"))),
         d, ": signals carries an absolute or pack-relative soundscape_path")
    }
  }

  # 5. Intentional defects preserved byte-for-byte.
  for (rel in names(EP_DEFECTS)) {
    f <- file.path(EP_ROOT, rel)
    ok(file.exists(f), "intentional fixture missing: ", rel)
    ok(file.size(f) == EP_DEFECTS[[rel]]$bytes,
       rel, ": ", file.size(f), " bytes, expected ", EP_DEFECTS[[rel]]$bytes)
  }

  # 5. Sidecars present, and the SM4 summary sits ABOVE Data/.
  ok(file.exists(file.path(EP_ROOT, "audiomoth/soundscapes/CONFIG.TXT")),
     "AudioMoth CONFIG.TXT missing")
  ok(file.exists(file.path(EP_ROOT, "sm4/soundscapes/W50940S22938_A_Summary.txt")),
     "SM4 summary missing, or not one level above Data/")

  # 6. The Basileuterus merge is lossless and carries both roles.
  bcu_paths <- .ep_read_rois(EP_BCU)$soundscape_path
  ok(any(startsWith(bcu_paths, "recordings/")), EP_BCU, ": no focal-recording ROIs")
  ok(any(startsWith(bcu_paths, "soundscapes/")), EP_BCU, ": no search-space ROIs")

  # 7. Every copied audio file is byte-identical to its source.
  for (d in names(EP_DATASETS)) {
    for (dest in names(EP_DATASETS[[d]]$dirs)) {
      src <- file.path(EP_WORKBENCH, EP_DATASETS[[d]]$dirs[[dest]])
      for (f in list.files(file.path(EP_ROOT, d, dest), full.names = TRUE)) {
        s <- file.path(src, basename(f))
        if (!file.exists(s)) next
        ok(identical(.ep_sha(f), .ep_sha(s)),
           "content drift on ", f, " vs its source")
      }
    }
  }

  # 9. The manifest covers every regular file, with current sizes.
  man <- utils::read.csv(file.path(EP_ROOT, "MANIFEST.csv"), stringsAsFactors = FALSE)
  rel <- sub(paste0("^", EP_ROOT, "/"), "", .ep_files())
  rel <- rel[rel != "MANIFEST.csv"]
  ok(setequal(man$path, rel),
     "MANIFEST.csv is out of date (", length(setdiff(rel, man$path)),
     " unlisted, ", length(setdiff(man$path, rel)), " stale) - re-run ep_manifest()")
  sizes <- file.size(file.path(EP_ROOT, man$path))
  ok(all(sizes == man$bytes), "MANIFEST.csv byte counts are stale")

  message("- ep_verify(): all invariants hold (", length(rel), " files).")
  invisible(TRUE)
}

#' Prove the premise: everything the pack omits can be rebuilt FROM the pack.
#'
#' Runs in a temp copy with the working directory set there, so the pack itself
#' is never written to. The template comparison is the load-bearing half: it
#' confirms that rewriting soundscape_path did not disturb template identity.
ep_recompute_check <- function() {
  old_wd <- getwd()
  tmp <- file.path(tempfile("ep_recompute"), "pack")
  dir.create(tmp, recursive = TRUE, showWarnings = FALSE)
  # Dereference any symlinks so the check exercises real files. Copy dataset by
  # dataset: the repo root also carries harness/ and authored docs that the
  # check has no use for.
  for (d in names(EP_DATASETS)) {
    status <- system2("cp", c("-rL", shQuote(file.path(old_wd, d)),
                              shQuote(file.path(tmp, d))))
    if (!identical(status, 0L)) stop("cp failed for '", d, "'.", call. = FALSE)
  }
  # EP_SRC is already absolute (a workbench path). Prefixing it with the pack
  # root produced a non-path, so every file.exists(ref_db) below was FALSE and
  # the identity check silently reported NA instead of comparing. Relative
  # EP_SRC (a MONITORASOM_WORKBENCH override) still resolves against old_wd.
  curated <- if (grepl("^(/|[A-Za-z]:)", EP_SRC)) EP_SRC else file.path(old_wd, EP_SRC)
  on.exit({ setwd(old_wd); unlink(dirname(tmp), recursive = TRUE) }, add = TRUE)

  # The two corpora fail in DIFFERENT ways, and the split is still the point -
  # but not the split recorded here before 2026-09-16. AudioMoth's truncated
  # 44-byte header PARSES: the reader trusts the header and sees 0 samples.
  # `min_duration_s` (d596598, 2026-09-09) then routes that 0-second row to the
  # error log, so it no longer lands as a valid row. SM4's zero-byte files
  # cannot be read at all and land in metadata_errors the same way. Hence 15/1
  # and 12/3: "unreadable" versus "readable but empty" now differ in the
  # error_class, not in whether a row exists.
  expect_meta <- list(audiomoth = c(valid = 15L, errors = 1L),
                      sm4       = c(valid = 12L, errors = 3L),
                      `basileuterus-culicivorus` = c(valid = 14L, errors = 0L))
  results <- list()

  for (d in names(EP_DATASETS)) {
    # Work from INSIDE the dataset directory. This is the portability test: if
    # anything still needed the pack root as its anchor, it fails here.
    setwd(file.path(tmp, d))

    # -- metadata, recomputed from the pack's own audio + sidecars
    valid <- 0L; errs <- 0L; geo <- FALSE
    for (dest in names(EP_DATASETS[[d]]$dirs)) {
      # Scan the role directory, not the Data/ subdir: the SM4 summary lives one
      # level above the WAVs and .find_sm4_summaries() needs to see both.
      scan_root <- if (grepl("/Data$", dest)) dirname(dest) else dest
      out <- tempfile(fileext = ".duckdb")
      df <- fetch_soundscape_metadata(soundscapes_path = scan_root,
                                      output_file = out, cache_policy = "force_refresh")
      valid <- valid + nrow(df)
      con <- dbConnect(duckdb::duckdb(), out, read_only = TRUE)
      errs <- errs + dbGetQuery(con, "select count(*) n from metadata_errors")$n
      dbDisconnect(con, shutdown = TRUE)
      if ("soundscape_lat" %in% names(df)) geo <- geo || any(!is.na(df$soundscape_lat))
      unlink(out)
    }
    e <- expect_meta[[d]]
    if (valid != e[["valid"]] || errs != e[["errors"]]) {
      stop(d, ": recomputed metadata = ", valid, " valid / ", errs,
           " errors; expected ", e[["valid"]], " / ", e[["errors"]], call. = FALSE)
    }

    # -- templates, recomputed from the pack's rois.duckdb + audio.
    # Read pack-relative: the working directory IS the pack root here, so the
    # EP_ROOT prefix that .ep_read_rois() adds would not resolve.
    rois <- local({
      con <- dbConnect(duckdb::duckdb(), "rois.duckdb", read_only = TRUE)
      on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
      dbGetQuery(con, "select * from rois")
    })
    tmpl <- .select_template_rois(rois)
    n_cut <- 0L; matched <- NA
    if (nrow(tmpl) > 0) {
      cuts <- tempfile("cuts")
      # export_roi_cuts() returns the manifest it just persisted, so there is no
      # need to read templates.duckdb back.
      got <- export_templates(tmpl, templates_path = cuts, create_dir = TRUE)
      got <- got[got$template_status == "written", , drop = FALSE]
      n_cut <- nrow(got)

      # Compare against the CURATED manifest built before the path rewrite.
      src_ds <- EP_DATASETS[[d]]$rois[1]
      ref_db <- file.path(curated, src_ds, "roi_cuts", "templates.duckdb")
      if (file.exists(ref_db)) {
        con <- dbConnect(duckdb::duckdb(), ref_db, read_only = TRUE)
        ref <- dbGetQuery(con, "select template_id, template_file, template_sha256 from templates")
        dbDisconnect(con, shutdown = TRUE)
        matched <- setequal(ref$template_id, got$template_id) &&
                   setequal(ref$template_file, got$template_file) &&
                   setequal(ref$template_sha256, got$template_sha256)
        if (!isTRUE(matched)) {
          stop(d, ": recomputed templates do NOT match the curated manifest.",
               call. = FALSE)
        }
      }
      unlink(cuts, recursive = TRUE)
    }
    results[[d]] <- data.frame(dataset = d, meta_valid = valid, meta_errors = errs,
                               geo_from_sidecar = geo, templates = n_cut,
                               identity_matches_curated = matched,
                               stringsAsFactors = FALSE)
  }

  out <- do.call(rbind, results)
  print(out, row.names = FALSE)
  message("- ep_recompute_check(): the pack regenerates everything it omits.")
  invisible(out)
}

#' Tarball the pack, or a subset of it.
#'
#' Members are added EXPLICITLY from EP_ROOT with no wrapping directory: this is
#' a hard contract, not a style choice, because fetch_example_data() untars
#' straight into the cache directory, so a wrapping top-level directory would
#' put every member one level too deep.
#'
#' @param datasets Character vector of dataset names to include, or NULL (all).
#'   The distributed bundle for the CRAN track is
#'   `ep_tar(datasets = "basileuterus-culicivorus")`.
#' @param dest Destination tarball path. Default `outputs/` (gitignored).
ep_tar <- function(datasets = NULL,
                   dest = "outputs/monitoraSom-example-data.tar.gz") {
  sel <- if (is.null(datasets)) names(EP_DATASETS) else {
    for (d in datasets) .ep_check(d)
    datasets
  }
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  members <- c(sel, "README.md", "MANIFEST.csv")
  args <- c("-czhf", shQuote(dest), "-C", shQuote(EP_ROOT))
  args <- c(args, vapply(members, shQuote, character(1)))
  status <- system2("tar", args)
  if (!identical(status, 0L)) stop("tar failed with status ", status, call. = FALSE)
  listed <- system2("tar", c("-tzf", shQuote(dest)), stdout = TRUE)
  top <- unique(sub("/.*$", "", sub("^\\./", "", listed)))
  top <- top[nzchar(top) & top != "."]
  stray <- setdiff(top, members)
  missing <- setdiff(members, top)
  if (length(stray) > 0L) {
    stop("Tarball has an unexpected top-level member: ",
         paste(stray, collapse = ", "), call. = FALSE)
  }
  if (length(missing) > 0L) {
    stop("Tarball is missing a member: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  message("- ", dest, " (", round(file.size(dest) / 1048576, 1), " MB), ",
          length(listed), " members; top level: ", paste(sort(top), collapse = ", "))
  invisible(dest)
}

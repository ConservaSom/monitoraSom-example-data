# Derivation of the sibling walkthrough formats (.qmd / .Rmd / .R)
# (plans/2026-08-28_01_restringir-example-pack-bcu-cran.md, DEC-12).
#
# There is NO fixed hierarchy among the three documents: any one of them can be
# the base of a derivation, and the maintainer picks the base each time. The
# workflow is consultative, the mechanics are not:
#
#   dw_conflicts(example)      report divergences between the existing documents
#   dw_derive(example, base)   regenerate the other two from `base`
#   dw_check(example)          post-derivation parity check
#
# `example` is the example directory name (e.g. "basileuterus-culicivorus").
# Run from the repository root:  source("harness/derive_walkthrough.R")
#
# Mappings (qmd <-> Rmd), faithful to what each engine understands:
#   format.html.toc            -> output.html_document.toc
#   format.html.embed-resources-> output.html_document.self_contained
#   execute.*                  -> knitr.opts_chunk.*   (rmarkdown top-level key)
#   quarto-only keys           -> dropped (code-fold etc. have no rmarkdown twin)
#
# The .R side is always knitr::purl(documentation = 2): prose survives as #'
# comments, code survives verbatim. Deriving FROM the .R reconstructs markdown
# best-effort (comments -> prose, code -> chunks) and is flagged as such.

DW_EXTS <- c("qmd", "Rmd", "R")

# --- paths -------------------------------------------------------------------

dw_paths <- function(example) {
  stats::setNames(file.path(example, paste0(example, ".", DW_EXTS)), DW_EXTS)
}

dw_existing <- function(example) {
  p <- dw_paths(example)
  names(p)[file.exists(p)]
}

# --- chunk model (qmd/Rmd) ---------------------------------------------------

# Returns a list of chunks: label (may be ""), header (the ```{r ...} line),
# body (character vector of code lines).
dw_chunks <- function(path) {
  lines <- readLines(path, warn = FALSE)
  starts <- grep("^```[ ]*\\{r", lines)
  if (length(starts) == 0L) return(list())
  ends <- vapply(starts, function(s) {
    e <- s
    while (e < length(lines) && !grepl("^```[ ]*$", lines[e])) e <- e + 1L
    e
  }, integer(1))
  lapply(seq_along(starts), function(i) {
    s <- starts[i]; e <- ends[i]
    header <- lines[s]
    label <- sub("^```[ ]*\\{r[ ]*", "", header)
    label <- sub("[,}].*$", "", label)
    list(label = trimws(label), header = header,
         body = if (e > s + 1L) lines[(s + 1L):(e - 1L)] else character(0))
  })
}

# --- chunk model (.R, purl output) -------------------------------------------

# purl(documentation = 2) marks chunks with "## ---- label ----" lines.
dw_chunks_r <- function(path) {
  lines <- readLines(path, warn = FALSE)
  starts <- grep("^## ----", lines)
  if (length(starts) == 0L) return(list())
  lapply(seq_along(starts), function(i) {
    s <- starts[i]
    e <- if (i < length(starts)) starts[i + 1L] - 1L else length(lines)
    body <- lines[(s + 1L):e]
    # purl(documentation = 2) keeps the markdown prose of the NEXT section as
    # #' roxygen comments inside the block, after the header. Drop them (and
    # any further ## ---- separator) so bodies compare code-only with the
    # .qmd/.Rmd chunk bodies; then trim leading/trailing blank runs.
    body <- body[!grepl("^## ----", body)]
    body <- body[!grepl("^#'", body)]
    # purl comments out every line of eval = FALSE chunks (so the sourced
    # script skips them - the right behaviour for the script format). For the
    # parity comparison, undo that "# " prefix so bodies compare code-only.
    if (grepl("eval\\s*=\\s*FALSE", lines[s])) {
      body <- sub("^# ", "", body)
    }
    while (length(body) > 0L && !nzchar(trimws(body[1L]))) body <- body[-1L]
    while (length(body) > 0L && !nzchar(trimws(body[length(body)]))) body <- body[-length(body)]
    list(label = trimws(sub(",.*$", "", sub(" *----.*$", "", sub("^## ---- *", "", lines[s])))),
         body = body)
  })
}

# --- conflicts ----------------------------------------------------------------

# Compares every existing pair. A conflict is any difference in the chunk
# sequence (labels in order, or code bodies). Returns a character vector of
# human-readable findings; length 0 = clean.
dw_conflicts <- function(example) {
  ex <- dw_existing(example)
  if (length(ex) < 2L) {
    return(paste0("only [", paste(ex, collapse = ", "),
                  "] exists - nothing to conflict with."))
  }
  out <- character(0)
  p <- dw_paths(example); names(p) <- DW_EXTS
  for (i in seq_along(ex)) for (j in (i + 1L):length(ex)) {
    if (j > length(ex)) break
    a <- ex[i]; b <- ex[j]
    ca <- if (a == "R") dw_chunks_r(p[[a]]) else dw_chunks(p[[a]])
    cb <- if (b == "R") dw_chunks_r(p[[b]]) else dw_chunks(p[[b]])
    la <- vapply(ca, `[[`, character(1), "label")
    lb <- vapply(cb, `[[`, character(1), "label")
    if (!identical(la, lb)) {
      out <- c(out, sprintf("%s vs %s: chunk sequence differs (%d vs %d chunks); first divergence at position %d.",
                            a, b, length(la), length(lb),
                            which(la != lb)[1] %||% min(length(la), length(lb)) + 1L))
      next
    }
    diffed <- which(vapply(seq_along(ca), function(k)
      !identical(ca[[k]]$body, cb[[k]]$body), logical(1)))
    if (length(diffed) > 0L) {
      out <- c(out, sprintf("%s vs %s: chunk(s) %s differ in code.",
                            a, b, paste0("'", la[diffed], "'", collapse = ", ")))
    }
  }
  out
}

`%||%` <- function(x, y) if (length(x) == 0L) y else x

# --- YAML mapping (qmd <-> Rmd) ----------------------------------------------

dw_split_yaml <- function(lines) {
  if (length(lines) < 2L || !identical(trimws(lines[1]), "---")) {
    return(list(yaml = character(0), body = lines))
  }
  end <- which(trimws(lines) == "---")[2]
  if (is.na(end)) return(list(yaml = character(0), body = lines))
  list(yaml = lines[2:(end - 1L)], body = lines[-(1:end)])
}

dw_map_yaml <- function(yaml, to = "Rmd") {
  if (to != "Rmd") {
    stop("Mapping to '", to, "' is not automated; qmd->Rmd only. The reverse ",
         "is done in-session by the agent (see the skill).", call. = FALSE)
  }
  # Walk the YAML by blocks: top-level `format:`/`execute:` subtrees are
  # consumed (their knobs mapped), every other top-level key is kept verbatim.
  keep <- character(0)
  exec <- character(0)
  want_toc <- want_self <- FALSE
  indent <- function(l) nchar(l) - nchar(sub("^\\s+", "", l))
  i <- 1L
  while (i <= length(yaml)) {
    l <- yaml[i]
    key <- sub(":.*$", "", l)
    if (indent(l) == 0L && key %in% c("format", "execute")) {
      i <- i + 1L
      while (i <= length(yaml) && indent(yaml[i]) > 0L) {
        sub_key <- sub(":.*$", "", sub("^\\s+", "", yaml[i]))
        if (key == "execute" && sub_key %in% c("eval", "warning", "error")) {
          exec <- c(exec, sub("^\\s+", "", yaml[i]))
        }
        if (key == "format" && sub_key == "toc" && grepl("true", yaml[i], fixed = TRUE)) {
          want_toc <- TRUE
        }
        if (key == "format" && sub_key == "embed-resources" &&
            grepl("true", yaml[i], fixed = TRUE)) {
          want_self <- TRUE
        }
        i <- i + 1L
      }
      next
    }
    keep <- c(keep, l)
    i <- i + 1L
  }
  out <- keep
  if (length(exec) > 0L) {
    out <- c(out, "knitr:", "  opts_chunk:", paste0("    ", exec))
  }
  if (want_toc || want_self) {
    out <- c(out, "output:", "  html_document:")
    if (want_toc) out <- c(out, "    toc: true")
    if (want_self) out <- c(out, "    self_contained: true")
  }
  out
}

# --- derive -------------------------------------------------------------------

dw_derive <- function(example, base = c("qmd", "Rmd", "R")) {
  base <- match.arg(base)
  p <- dw_paths(example); names(p) <- DW_EXTS
  if (!file.exists(p[[base]])) {
    stop("Base document not found: ", p[[base]], call. = FALSE)
  }
  if (base == "R") {
    message("Reconstructing .qmd/.Rmd from the .R is best-effort (prose from #'",
            " comments). Review the result before committing.")
    stop("Script-base reconstruction: run dw_derive_from_r('", example,
         "') interactively; not automated.", call. = FALSE)
  }
  # qmd -> Rmd: YAML map, identical body
  src <- readLines(p[[base]], warn = FALSE)
  parts <- dw_split_yaml(src)
  yaml_new <- if (base == "qmd") dw_map_yaml(parts$yaml, "Rmd") else parts$yaml
  rmd <- c("---", yaml_new, "---", "", parts$body)
  writeLines(rmd, p[["Rmd"]])
  message("- wrote ", p[["Rmd"]])
  # -> R: purl (same body either way)
  knitr::purl(p[[base]], output = p[["R"]], documentation = 2L, quiet = TRUE)
  message("- wrote ", p[["R"]])
  invisible(p[c("Rmd", "R")])
}

# --- post-derivation check -----------------------------------------------------

dw_check <- function(example) {
  conflicts <- dw_conflicts(example)
  if (length(conflicts) == 0L) {
    message("- dw_check(): the three documents agree (chunk sequence and code).")
  } else {
    message("- dw_check(): DIVERGENCES FOUND:")
    for (c in conflicts) message("  * ", c)
  }
  invisible(conflicts)
}

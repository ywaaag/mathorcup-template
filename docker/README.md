# MathorCup Runtime Image

This directory documents the portable runtime layer for MathorCup instances.

## Current Recommended Image

Use:

```bash
mathorcup-runtime:latest
```

At the time of this template update, `latest` should point to:

```bash
mathorcup-runtime:20260705
```

The runtime scripts do not hard-code this date tag. Rendered instances read the
actual image from `.env`:

```bash
IMAGE_NAME=mathorcup-runtime:latest
```

## Portable Rebuild

If another machine already has the previous thick base image:

```bash
docker build \
  -f docker/Dockerfile.runtime \
  --build-arg BASE_IMAGE=mathorcup-runtime:20260510 \
  -t mathorcup-runtime:20260705 \
  .

docker tag mathorcup-runtime:20260705 mathorcup-runtime:latest
```

This Dockerfile is an incremental refresh layer. It adds:

- Noto CJK fonts
- `qpdf` and `poppler-utils`
- `PyPDF2` and `PyMuPDF`
- R packages `ompr` and `ROI`
- `biblatex` through the TeX Live 2023 user tree

## Quick Verification

```bash
docker run --rm mathorcup-runtime:latest bash -lc '
python3 - <<PY
import PyPDF2, fitz
print("python-pdf-ok")
PY
Rscript -e "stopifnot(requireNamespace(\"ompr\", quietly=TRUE)); stopifnot(requireNamespace(\"ROI\", quietly=TRUE)); cat(\"r-ok\\n\")"
fc-match "Noto Sans CJK SC"
kpsewhich biblatex.sty
'
```

## Boundary

The image only provides tools. It does not define project truth.

Rendered instance truth remains in:

- `.env`
- `project/paper/runtime/paper.env`
- `MEMORY.md`
- `project/runtime/*.json`
- `project/runtime/event_log.jsonl`

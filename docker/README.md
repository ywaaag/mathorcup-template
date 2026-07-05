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

## Portable Build On A New Machine

This Dockerfile does not require any local MathorCup base image. It starts from
public `ubuntu:22.04`, then installs the runtime baseline with domestic mirrors.

```bash
docker build \
  -f docker/Dockerfile.runtime \
  -t mathorcup-runtime:20260705 \
  .

docker tag mathorcup-runtime:20260705 mathorcup-runtime:latest
```

Then create an instance normally; rendered `.env` uses:

```bash
IMAGE_NAME=mathorcup-runtime:latest
```

The Dockerfile is designed for China-friendly rebuilds:

- Domestic mirrors are the default for apt, pip, CRAN, and TeX Live 2023.
- `.dockerignore` excludes `.git`, rendered `project/`, logs, PDFs, and common
  virtual environments from the build context.
- It installs only the runtime baseline needed by the template, not unrelated
  project outputs or historical container labels.

Default mirrors:

```text
APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
PIP_EXTRA_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
CRAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/CRAN
TLMGR_REPOSITORY=https://mirrors.tuna.tsinghua.edu.cn/tex-historic-archive/systems/texlive/2023/tlnet-final
```

This Dockerfile installs the current runtime baseline:

- Python modeling stack
- R modeling stack
- XeLaTeX / latexmk / biber / ctex / xeCJK
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

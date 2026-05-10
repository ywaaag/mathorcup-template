# CUMCMThesis Integration Note

## Source

- Upstream repository: `https://github.com/latexstudio/CUMCMThesis`
- Imported upstream commit: `90d3e85`
- Imported file: `cumcmthesis.cls`

## Template Adaptation

- This scaffold vendors `cumcmthesis.cls` into `project/paper/` so rendered instances can compile without relying on a global TeX installation of the class.
- The class is patched only for safer font defaults on Linux container images:
  - `Times New Roman` -> `TeX Gyre Termes`
  - `Arial` -> `TeX Gyre Heros`
  - `simkai.ttf` -> `FandolKai-Regular`
  - `SimSun` -> `FandolSong-Regular`
- The active paper entrypoint remains controlled by `project/paper/runtime/paper.env`.

## Maintenance Rule

- Do not edit `cumcmthesis.cls` during normal paper writing.
- If the upstream class is refreshed, record the new upstream commit here and rerun render-only smoke validation.
- Before public redistribution outside internal competition use, confirm upstream licensing terms because the upstream checkout did not expose a standalone `LICENSE` file during integration.

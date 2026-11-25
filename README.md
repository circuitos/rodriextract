# rodriextract

A simple image extractor for PDFs. Point it at a PDF (or a whole folder of them) and it pulls out
every image above a minimum size, at the best quality the PDF allows, into a folder next to each PDF.

Built for people who have never run a script: double-click, pick files, click one button.
Nothing to install, no administrator rights needed, no unsigned `.exe` for antivirus to object to.

## Using it

Download `rodriextract.zip` from the [Releases](../../releases) page, **extract it fully**
(right-click, Extract All), then double-click `rodriextract.cmd`.
End-user instructions are in [`README.txt`](README.txt), which is included in the zip.

- Images are copied out exactly as stored in the PDF: JPEGs are not re-compressed, everything
  else is saved as lossless PNG.
- Output goes to `<pdf name>_images\`, named `page003_image01.jpg`. Existing results are never
  overwritten (`_images_2`, `_images_3`, ...).
- Masks are skipped; exact duplicate images can optionally be removed.

## How it works

| File | Purpose |
|---|---|
| `rodriextract.cmd` | Double-click launcher. Removes the "downloaded from the internet" tag from the folder, then starts the app with a hidden console. |
| `rodriextract-visible.cmd` | Same, but keeps the console open so errors can be read. First thing to try if the app does nothing. |
| `rodriextract.ps1` | The app: a Windows PowerShell 5.1 / WinForms window with progress bars, drag and drop, and cancel. Logs to `%LOCALAPPDATA%\rodriextract\rodriextract.log`. |
| `poppler\` | Bundled `pdfimages.exe` and `pdfinfo.exe` from [Poppler](https://poppler.freedesktop.org/) plus the minimal DLLs they need (GPL, see `poppler\README-poppler.txt`). |
| `diagnostic\` | Troubleshooting tool for machines where the app will not start (see below). |
| `Extract-PdfImages.ps1` | Standalone command-line version without the window. |
| `build.ps1` | Builds the release zip. |

### Command-line version

```powershell
.\Extract-PdfImages.ps1 -Path .\file.pdf -MinWidth 300 -MinHeight 300
.\Extract-PdfImages.ps1 -Path .\folder -Recurse -RemoveDuplicates
```

Run without `-Path` to get a file/folder picker. It needs `pdfimages.exe` on the PATH or `-PdfImagesPath`.

## If it does not work on someone's PC

1. `rodriextract-visible.cmd` shows the error in a console window.
2. `diagnostic\rodriextract-diagnose.cmd` checks the PC and writes `rodriextract-diagnostic.txt`:
   quarantined files (checked against a hash manifest), execution policy at every level,
   Constrained Language Mode, AppLocker/WDAC, installed AV/EDR, a test of each Poppler tool,
   a test window, a real launch, and the relevant event-log entries. It starts with a short list of
   automatic findings. The report contains the computer name, user name and paths.

Typical causes seen so far: files tagged as downloaded from the internet while a Group Policy forces
PowerShell's execution policy to `Unrestricted` (a prompt nobody can see in a hidden window), and
security software quarantining or blocking files.

## Building

```powershell
.\build.ps1
```

Writes `dist\rodriextract.zip` containing the app, `poppler\` and `diagnostic\`. It also regenerates
`diagnostic\diagnose-manifest.txt` (sizes and SHA-256 of every shipped file). Zip entries use forward
slashes so every unzip tool extracts them correctly. Releases are published as GitHub Releases;
`dist\` is not committed.

Notes for contributing:

- Keep `.cmd` / `.ps1` / `.txt` files **CRLF** and **ASCII-only** (`.gitattributes` enforces CRLF).
  Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
- The code targets Windows PowerShell 5.1 (the one on every Windows PC), not PowerShell 7.
- `rodriextract.ps1 -LoadOnly` loads the functions without opening the window, for testing.

## License

The scripts are MIT licensed, see [LICENSE](LICENSE). The bundled Poppler tools are GPL; see
[`poppler/README-poppler.txt`](poppler/README-poppler.txt) for their source.

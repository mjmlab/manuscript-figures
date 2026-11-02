# Manuscript Figures

Illustrator templates and an export script for preparing manuscript figures.

There are two ways to set it up:

- **[Simple setup](#simple-setup)**: one copy inside a single manuscript folder.
- **[Advanced setup](#advanced-setup)** (recommended if you write several papers or
  keep manuscripts on Google Drive): one shared copy that serves all your
  manuscripts.

## Requirements (macOS)

- poppler: `brew install poppler`
- python3 (from the Xcode command line tools: `xcode-select --install`). On first
  run the export script installs the Python packages it needs into
  `~/.cache/export_figures/venv` (requires internet).

## Simple setup

### Install

Clone this repository into your manuscript folder as a directory named `Figures`:

```sh
cd /path/to/your/manuscript
git clone https://github.com/mjmlab/manuscript-figures.git Figures
cd Figures
```

### Make figures

Use `Fig 1.ai` (main figures) and `Fig S1.ai` (supplementary figures) as templates.
Duplicate a template for each figure and rename the copy to match the figure, e.g.
`Fig 2.ai` or `Fig S3.ai`.

Each template is a US Letter (8.5 × 11 in) page with a figure legend at the bottom.
Place the figure panels in the white space above the legend, keeping 0.5 in margins
on the page, and center them. Replace the placeholder legend with your own.

Keep **Create PDF Compatible File** checked when saving (the Illustrator default);
the export script needs it.

### Export

From the `Figures` folder:

```sh
./export_figures.sh            # JPG, TIFF, PNG and PDF
./export_figures.sh --pdf      # PDFs only
./export_figures.sh --help     # all options
```

Outputs are written to `JPG/`, `TIFF/`, `PNG/` and `PDF/` in the `Figures` folder.
See [Export script](#export-script) for what the script does and its options.

### Update

To get script or template updates, run `git pull` inside `Figures`. If an update
changes `Fig 1.ai` or `Fig S1.ai` and you have edited that file for your
manuscript, git will refuse to overwrite it; rename your figure first.

## Advanced setup

The simple setup puts a git repository inside each manuscript folder. That becomes
cumbersome when you write several papers: each one needs its own clone, and each
clone has to be updated separately. It also causes problems on Google Drive and
other synced folders: if more than one person or computer syncs the folder, the
repository's `.git` folder can end up with conflicts or corruption.

The advanced setup instead keeps one copy of the repository on your computer,
outside any synced folder, and uses it for all your manuscripts.

### Install

Clone the repository once, then set up your first manuscript:

```sh
git clone https://github.com/mjmlab/manuscript-figures.git ~/manuscript-figures
~/manuscript-figures/new_manuscript.sh "/path/to/your/manuscript"
```

`new_manuscript.sh` creates the manuscript folder (if it doesn't exist yet) and a
`Figures` folder inside it, and copies in the templates. It never overwrites files
already there. For each later paper, run just the second line with the new
manuscript's path.

Then make figures from the templates as in the [simple setup](#make-figures).

### Export

Run the script from the manuscript's `Figures` folder with `--dir .`:

```sh
cd "/path/to/your/manuscript/Figures"
~/manuscript-figures/export_figures.sh --dir .
```

Outputs are written to that manuscript's `Figures` folder, so each paper keeps its
own. Leaving out `--dir .` would export the templates in `~/manuscript-figures`
instead.

Optionally, add this line to `~/.zshrc` so `export_figures` works in any `Figures`
folder:

```sh
alias export_figures='~/manuscript-figures/export_figures.sh --dir .'
```

Then, for example, `export_figures --pdf` exports PDFs only.

### Update

Run `git pull` in `~/manuscript-figures`. Every manuscript gets the updated script
at once. Updated templates are copied into new manuscripts by `new_manuscript.sh`;
existing manuscripts keep the figures they have.

## Export script

`export_figures.sh` turns the figure files into upload-ready formats. Key features:

- **Multiple formats from vector source.** Renders every figure straight from the
  `.ai` (or editable `.pdf`) file into:
  - `JPG/`: small files for bioRxiv, preprints and sharing
  - `TIFF/`: LZW-compressed, lossless, for journal production upload
  - `PNG/`: lossless raster
  - `PDF/`: one vector PDF per figure
- **Combined PDFs.** Also merges main figures into one PDF (e.g. `Figures 1-5.pdf`)
  and supplementary figures into another (e.g. `Supplementary Figures S1-S8.pdf`).
  Files named `Fig S<n>` (or starting with `Supp`) count as supplementary.
- **Lossless size reduction.** PDFs drop Illustrator's private editing data, store
  repeated content once and recompress images, with a check that no image data
  changes. `--max-mb 15` splits a combined PDF in two if it is over 15 MB.
- **Incremental builds.** Only figures that changed since the last run (or whose
  settings changed) are regenerated. `--force` rebuilds everything.
- **Adjustable output.** `--dpi` sets raster resolution (default 300) and `--quality`
  sets JPG quality (default 95).
- **Optional figure labels.** `--labels` adds "Figure 1", "Figure 2", … in Arial Bold
  above each main figure; `--label-supp` labels supplementary figures too. Source
  files are never modified.
- **Other folders.** `--dir <path>` runs the script on figures in another folder.

## Preparing figures for publication

The templates are designed for review copies, with the legend on the page under each
figure. For final publication, check the journal's figure requirements. You will
likely need to:

- **Remove the legend** from each main figure file. Legends usually go in the
  manuscript text instead.
- **Crop the artboard to the figure** (Object → Artboards → Fit to Artwork Bounds),
  so the exported files have no blank page around them.
- **Resize the figure** if needed. Many journals limit width to about 7 in (178 mm)
  for a full-width figure, and less for a single column.

Supplementary figures can usually be submitted as the combined
`Supplementary Figures S1-S<n>.pdf` produced by the script, with their legends in
place, but check the journal's requirements.

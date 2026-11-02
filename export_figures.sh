#!/bin/bash
# Generate JPG, PNG, LZW-compressed TIFF and PDF versions of figure files.
#
# Requirements (macOS):
#   - poppler, for pdftoppm/pdfunite/pdfinfo:   brew install poppler
#   - python3 (comes with Xcode command line tools: xcode-select --install).
#     The PDF step also needs pikepdf + numpy; if they're missing, the script
#     installs them into ~/.cache/export_figures/venv on first run (needs internet).
#   - .ai files saved with "Create PDF Compatible File" checked (Illustrator default),
#     and/or .pdf files (editable Illustrator PDFs work fine)
#   Run it with: ./export_figures.sh  (if needed first: chmod +x export_figures.sh)
#
# Source of truth is the .ai file (Illustrator saves these PDF-compatible), or
# an editable .pdf (saved with "Preserve Illustrator Editing Capabilities");
# if both exist for a figure, the .ai wins. Everything is rasterized straight
# from vector with pdftoppm. If the source is missing or won't render, raster
# formats fall back to the matching .png via sips.
#
#   JPG  -> for bioRxiv / preprint / sharing (small)
#   PNG  -> lossless raster
#   TIFF -> for mBio production upload (LZW-compressed, lossless)
#   PDF  -> one vector PDF per figure, plus combined PDFs of the main figures
#           (e.g. "Figures 1-10.pdf") and supplementary figures
#           (e.g. "Supplementary Figures S1-S10.pdf")
#
# Figures named "Fig S<n>" (or starting with "Supp") are supplementary; all
# other numbered figures are main figures.
#
# Only outputs whose source changed since the last run (or whose settings
# changed, e.g. a new --dpi) are regenerated. Each output folder keeps a
# .sources manifest recording the size and modification time of the source
# each file was built from; any difference (an edit, or a renumbered figure
# whose new name points at a different file) triggers a rebuild.
# Use --force to redo everything.
#
# Usage:
#   ./export_figures.sh                 # all formats: JPG, TIFF, PNG, PDF
#   ./export_figures.sh --jpg           # JPGs only
#   ./export_figures.sh --tiff          # LZW TIFFs only
#   ./export_figures.sh --png           # PNGs only
#   ./export_figures.sh --pdf           # individual + combined PDFs only
#   ./export_figures.sh --jpg --tiff    # format flags combine
#   ./export_figures.sh --force         # regenerate even if up to date
#   ./export_figures.sh --labels        # add "Figure 1", "Figure 2", ... labels
#   ./export_figures.sh --label-supp    # ...and "Figure S1", ... on supplementary too
#   ./export_figures.sh --dir ../Main_Figures  # work in another folder
#
# Options that can be added to any of the above:
#   --dpi 600       resolution for JPG, TIFF and PNG (default 300; PDFs are vector)
#   --quality 85    JPG quality, 1-100 (default 95; lower = smaller files)
#   --max-mb 15     split a combined PDF in two if over 15 MB (default: never split)
#   --label-size 14 label size in points (implies --labels; default scales with
#                   figure width, 12 pt for a 7-inch-wide figure)
#
# --labels prints the figure label in Arial Bold at the top left of every
# main figure, on a strip of extra white canvas added above the figure so
# nothing is covered. Supplementary figures are left alone (they usually carry
# their own captions) unless --label-supp is given, which labels them too and
# implies --labels. The .ai/.pdf sources are never modified. Changing any
# label option rebuilds everything on the next run.
#
# Outputs land in JPG/, TIFF/, PNG/ and PDF/ of the target directory.

set -u

JPG=0
TIFF=0
PNG=0
PDF=0
FORCE=0
MAX_MB=""                                  # no size cutoff unless --max-mb given
DPI=300
QUALITY=95
DIR=""
LABELS=0
LABEL_SIZE=auto
LABEL_SUPP=0
FONT="/System/Library/Fonts/Supplemental/Arial Bold.ttf"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --jpg)     JPG=1 ;;
        --tiff)    TIFF=1 ;;
        --png)     PNG=1 ;;
        --pdf)     PDF=1 ;;
        --force)   FORCE=1 ;;
        --max-mb)  MAX_MB="$2"; shift ;;
        --dpi)     DPI="$2"; shift ;;
        --quality) QUALITY="$2"; shift ;;
        --dir)     DIR="$2"; shift ;;
        --labels)  LABELS=1 ;;
        --label-size) LABELS=1; LABEL_SIZE="$2"; shift ;;
        --label-supp) LABELS=1; LABEL_SUPP=1 ;;
        [0-9]*)    DPI="$1" ;;                 # bare number = dpi
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# no format flags at all means every format
[ $((JPG + TIFF + PNG + PDF)) = 0 ] && { JPG=1; TIFF=1; PNG=1; PDF=1; }

cd "${DIR:-$(dirname "$0")}" || exit 1

command -v pdftoppm >/dev/null || { echo "pdftoppm not found (brew install poppler)" >&2; exit 1; }
# label options as recorded in the settings stamps, so changing any rebuilds
LABEL_KEY="labels=$LABEL_SIZE"
[ "$LABEL_SUPP" = 1 ] && LABEL_KEY+=" supp"
if [ "$LABELS" = 1 ] && [ ! -f "$FONT" ]; then
    echo "--labels: Arial Bold not found at $FONT" >&2; exit 1
fi

made=0
skipped=0
failed=0

# Size and modification time of file $1, e.g. "1234567 1760000000".
signature() {
    stat -f '%z %m' "$1"
}

# Manifest entry for output $1 ("<source><TAB><signature>"), or nothing.
recorded() {
    local m
    m="$(dirname "$1")/.sources"
    [ -f "$m" ] && awk -F'\t' -v o="$(basename "$1")" '$1 == o { print $2 "\t" $3 }' "$m"
}

# Note in the manifest that output $1 was just built from source $2.
record() {
    local m o
    m="$(dirname "$1")/.sources"
    o="$(basename "$1")"
    { [ -f "$m" ] && awk -F'\t' -v o="$o" '$1 != o' "$m"
      printf '%s\t%s\t%s\n' "$o" "$2" "$(signature "$2")"
    } > "$m.tmp" && mv "$m.tmp" "$m"
}

# True if output $1 exists and was built from source $2 as it is now: same
# file name, size and modification time (always false with --force). Unlike
# an "output newer than source" check, this catches renumbering, where a
# renamed source can be older than the output it should replace.
up_to_date() {
    [ "$FORCE" = 0 ] && [ -s "$1" ] || return 1
    [ "$(recorded "$1")" = "$2"$'\t'"$(signature "$2")" ]
}

# True if the stamp file $1 records exactly the settings $2 from the last run.
same_settings() {
    [ "$FORCE" = 0 ] && [ "$(cat "$1" 2>/dev/null)" = "$2" ]
}

# Render one source file into one raster format. Returns 0 on success.
render() {
    local src="$1" base="$2" fmt="$3"
    local ext outdir out

    case "$fmt" in
        jpg)  ext=jpg;  outdir=JPG  ;;
        tiff) ext=tiff; outdir=TIFF ;;
        png)  ext=png;  outdir=PNG  ;;
    esac
    mkdir -p "$outdir"
    out="$outdir/$base.$ext"

    if [ "${src##*.}" = "ai" ] || [ "${src##*.}" = "pdf" ]; then
        local in="$src"
        if [ "$LABELS" = 1 ]; then
            in=$(labeled "$src") || { echo "FAIL $src (could not add label)"; return 1; }
        fi
        case "$fmt" in
            jpg)  pdftoppm -jpeg -jpegopt "quality=$QUALITY" -r "$DPI" \
                           -singlefile "$in" "$outdir/$base" 2>/dev/null ;;
            tiff) pdftoppm -tiff -tiffcompression lzw -r "$DPI" \
                           -singlefile "$in" "$outdir/$base" 2>/dev/null ;;
            png)  pdftoppm -png -r "$DPI" \
                           -singlefile "$in" "$outdir/$base" 2>/dev/null ;;
        esac
        # poppler may name TIFF output .tif; normalize to the extension we want
        [ -s "$outdir/$base.tif" ] && [ "$ext" = tiff ] && mv "$outdir/$base.tif" "$out"
        if [ -s "$out" ]; then
            printf 'OK   %-28s <- %-20s %s dpi, vector\n' "$out" "$src" "$DPI"
            return 0
        fi
        rm -f "$out"
        echo "WARN $src did not render; trying PNG"
    fi

    # PNG fallback
    local png="$base.png"
    [ -e "$png" ] || { echo "FAIL $base (no usable source)"; return 1; }
    [ "$LABELS" = 1 ] && echo "WARN $png: labels need a .ai or .pdf source; writing without one"
    case "$fmt" in
        jpg)  sips -s format jpeg -s formatOptions "$QUALITY" "$png" --out "$out" >/dev/null 2>&1 ;;
        tiff) sips -s format tiff -s formatOptions lzw "$png" --out "$out" >/dev/null 2>&1 ;;
        png)  cp "$png" "$out" ;;
    esac
    if [ -s "$out" ]; then
        printf 'OK   %-28s <- %-20s from PNG\n' "$out" "$png"
        return 0
    fi
    echo "FAIL $base"
    return 1
}

# Python with pikepdf + numpy, for the lossless PDF shrink. Uses the system
# python3 if it has them, else a private venv (created on first use).
# With --labels it also needs reportlab (to typeset the label).
pdf_python() {
    local mods="pikepdf numpy" venv
    [ "$LABELS" = 1 ] && mods+=" reportlab"
    if python3 -c "import ${mods// /, }" 2>/dev/null; then
        echo python3; return 0
    fi
    venv="${XDG_CACHE_HOME:-$HOME/.cache}/export_figures/venv"
    if ! "$venv/bin/python" -c "import ${mods// /, }" 2>/dev/null; then
        echo "     setting up $venv ($mods; first run only)" >&2
        python3 -m venv "$venv" >/dev/null 2>&1 &&
            "$venv/bin/pip" -q install $mods >/dev/null 2>&1 || return 1
    fi
    echo "$venv/bin/python"
}

# Copy PDF $1 to $2 with label text $3 added at the top left of page 1, in
# Arial Bold at size $4 points ("auto" = figure width / 42). The page is
# extended upward to make room, so the label never covers the figure.
#   label_pdf IN OUT TEXT SIZE
label_pdf() {
    "$PY" - "$@" "$FONT" <<'EOF'
import sys, io, pikepdf
from pikepdf import Rectangle
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

src, out, text, size, font = sys.argv[1:6]
pdfmetrics.registerFont(TTFont('Arial-Bold', font))

pdf = pikepdf.open(src)
page = pdf.pages[0]
if int(page.obj.get('/Rotate', 0)) % 360:
    sys.exit(f'{src}: rotated pages are not supported')
crop = Rectangle(page.cropbox)
x0, y0, x1, y1 = crop.llx, crop.lly, crop.urx, crop.ury
size = (x1 - x0) / 42 if size == 'auto' else float(size)

# strip above the figure: padding, cap height + descender ("g"), padding
pad = 0.4 * size
top = y1 + pad + 0.93 * size + pad

# grow every page box upward to the new top
page.mediabox = Rectangle(page.mediabox).as_array()
page.cropbox = crop.as_array()
for key in ('/MediaBox', '/CropBox', '/BleedBox', '/TrimBox'):
    if key in page.obj:
        b = Rectangle(page.obj[key])
        page.obj[key] = Rectangle(b.llx, b.lly, b.urx, max(b.ury, top)).as_array()

# typeset the label on a page the size of the new crop box, then lay it on top
buf = io.BytesIO()
c = canvas.Canvas(buf, pagesize=(x1 - x0, top - y0))
c.setFont('Arial-Bold', size)
c.drawString(pad, top - y0 - pad - 0.716 * size, text)   # 0.716 = Arial cap height
c.showPage()
c.save()
label = pikepdf.open(buf)
page.add_overlay(label.pages[0], Rectangle(x0, y0, x1, top))
pdf.save(out)
EOF
}

# Print "<main|supp><TAB><figure number>" for source $1; fails if it has no number.
figure_info() {
    local n
    n=$(printf '%s' "$1" | sed -nE 's/.*[^0-9]([0-9]+)\.(ai|pdf)$/\1/p')
    [ -n "$n" ] || return 1
    if printf '%s' "$1" | grep -Eq '^[Ss]upp|[^A-Za-z][Ss][0-9]+\.(ai|pdf)$'; then
        printf 'supp\t%s\n' "$n"
    else
        printf 'main\t%s\n' "$n"
    fi
}

# Print the path of a labeled copy of source $1 ("Figure 3", "Figure S2"),
# made once per run in $LABEL_TMP. Supplementary figures get no label without
# --label-supp, so for them this prints $1 itself.
labeled() {
    local src="$1" out g n text
    out="$LABEL_TMP/${src%.*}.pdf"
    if [ ! -s "$out" ]; then
        IFS=$'\t' read -r g n < <(figure_info "$src") ||
            { echo "WARN $src: no figure number to label it with" >&2; return 1; }
        if [ "$g" = supp ] && [ "$LABEL_SUPP" = 0 ]; then
            printf '%s\n' "$src"
            return 0
        fi
        text="Figure $n"
        [ "$g" = supp ] && text="Figure S$n"
        label_pdf "$src" "$out" "$text" "$LABEL_SIZE" >&2 || return 1
    fi
    printf '%s\n' "$out"
}

# Losslessly shrink a merged PDF of .ai files:
#   - drop Illustrator's private editing data (PieceInfo)
#   - store identical streams once (Illustrator embeds the same CMYK ICC
#     profile in every figure)
#   - re-encode Flate images with PNG predictors at zlib level 9
# Decoded image data is checked against the input; any mismatch aborts.
# If the result is over MAXBYTES and PART1/PART2 are given, it is split there
# after page SPLIT and the combined file is removed.
#   shrink_pdf IN OUT MAXBYTES [SPLIT PART1 PART2]
shrink_pdf() {
    "$PY" - "$@" <<'EOF'
import sys, io, os, zlib, hashlib
import numpy as np, pikepdf
from pikepdf import Name, Dictionary, Stream

src, out, maxbytes = sys.argv[1], sys.argv[2], int(sys.argv[3])
split = sys.argv[4:7]

def image_hashes(pdf):
    return {hashlib.md5(o.read_bytes()).hexdigest() for o in pdf.objects
            if isinstance(o, Stream) and o.get('/Subtype') == '/Image'}

pdf = pikepdf.open(src)
before = image_hashes(pdf)

for page in pdf.pages:
    for k in ('/PieceInfo', '/LastModified', '/Thumb'):
        if k in page.obj:
            del page.obj[k]

# store identical streams once
first, remap = {}, {}
for o in pdf.objects:
    if isinstance(o, Stream):
        d = repr(sorted((k, str(v)) for k, v in o.stream_dict.items()))
        k = hashlib.md5(o.read_raw_bytes() + d.encode()).hexdigest()
        if k in first:
            remap[o.objgen] = first[k]
        else:
            first[k] = o

visited = set()
def relink(obj):
    if isinstance(obj, (pikepdf.Dictionary, pikepdf.Array, Stream)) and obj.is_indirect:
        if obj.objgen in visited:
            return
        visited.add(obj.objgen)
    if isinstance(obj, pikepdf.Array):
        keys, holder = range(len(obj)), obj
    elif isinstance(obj, (pikepdf.Dictionary, Stream)):
        holder = obj.stream_dict if isinstance(obj, Stream) else obj
        keys = list(holder.keys())
    else:
        return
    for k in keys:
        v = holder[k]
        if isinstance(v, pikepdf.Object) and v.is_indirect and v.objgen in remap:
            holder[k] = remap[v.objgen]
        else:
            relink(v)
relink(pdf.Root)

pikepdf.settings.set_flate_compression_level(9)
buf = io.BytesIO()
pdf.remove_unreferenced_resources()
pdf.save(buf, compress_streams=True, recompress_flate=True)
pdf = pikepdf.open(buf)

# PNG-predictor re-encode of 8-bit Flate images (per-row best of None/Sub/Up/Paeth)
for o in list(pdf.objects):
    if not (isinstance(o, Stream) and o.get('/Subtype') == '/Image'):
        continue
    if str(o.get('/Filter')) != '/FlateDecode' or '/DecodeParms' in o \
            or int(o.get('/BitsPerComponent', 8)) != 8:
        continue
    w, h = int(o.Width), int(o.Height)
    raw = o.read_bytes()
    nc = len(raw) // (w * h)
    if nc == 0 or nc * w * h != len(raw):
        continue
    a = np.frombuffer(raw, np.uint8).reshape(h, w * nc).astype(np.int16)
    zc = np.zeros((h, nc), np.int16)
    zr = np.zeros((1, w * nc), np.int16)
    left = np.hstack([zc, a[:, :-nc]])
    up = np.vstack([zr, a[:-1]])
    ul = np.vstack([zr, left[:-1]])
    p = left + up - ul
    pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
    paeth = np.where((pa <= pb) & (pa <= pc), left, np.where(pb <= pc, up, ul))
    types = [0, 1, 2, 4]
    cands = np.stack([a, a - left, a - up, a - paeth]) % 256
    choice = np.minimum(cands, 256 - cands).sum(2).argmin(0)
    rows = np.empty((h, w * nc + 1), np.uint8)
    rows[:, 0] = np.array(types)[choice]
    rows[:, 1:] = cands[choice, np.arange(h)]
    data = zlib.compress(rows.tobytes(), 9)
    if len(data) < len(o.read_raw_bytes()):
        o.write(data, filter=Name.FlateDecode,
                decode_parms=Dictionary(Predictor=15, Colors=nc,
                                        BitsPerComponent=8, Columns=w))

if image_hashes(pdf) != before:
    sys.exit('image data changed during shrink; not writing output')

pdf.save(out, compress_streams=True, recompress_flate=False,
         object_stream_mode=pikepdf.ObjectStreamMode.generate)

if os.path.getsize(out) > maxbytes and len(split) == 3:
    k, p1, p2 = int(split[0]), split[1], split[2]
    whole = pikepdf.open(out)
    for path, pages in ((p1, whole.pages[:k]), (p2, whole.pages[k:])):
        part = pikepdf.Pdf.new()
        part.pages.extend(pages)
        part.save(path, compress_streams=True, recompress_flate=False,
                  object_stream_mode=pikepdf.ObjectStreamMode.generate)
    whole.close()
    os.remove(out)
EOF
}

# List figure sources, one per line: every .ai, plus each .pdf that has no
# matching .ai (the .ai wins if both exist).
sources() {
    local f
    for f in *.ai *.pdf; do
        [ -e "$f" ] || continue
        case "$f" in ~*) continue ;; esac      # skip Illustrator temp files
        [ "${f##*.}" = pdf ] && [ -e "${f%.*}.ai" ] && continue
        printf '%s\n' "$f"
    done
}

# Print "<main|supp><TAB><figure number><TAB><file>" for each source (unsorted).
numbered_sources() {
    local f info
    while IFS= read -r f; do
        if ! info=$(figure_info "$f"); then
            echo "WARN PDF: skipping $f (no figure number)" >&2
            continue
        fi
        printf '%s\t%s\n' "$info" "$f"
    done < <(sources)
}

# Write one PDF per figure into PDF/, then one combined PDF each for the main
# and supplementary figures (split in two if MAX_MB is set and exceeded).
make_pdf() {
    local f n g base out in maxbytes=0 list="" stale=0 failed0=$failed
    [ -n "$MAX_MB" ] && maxbytes=$(awk -v m="$MAX_MB" 'BEGIN { printf "%d", m * 1000000 }')
    mkdir -p PDF

    [ -n "$PY" ] ||
        echo "WARN PDF: lossless shrink unavailable; writing plain copies (larger files)"

    # turning labels on/off or resizing them means every figure PDF is out of date
    local fig_settings=""
    [ "$LABELS" = 1 ] && fig_settings="$LABEL_KEY"
    same_settings PDF/.settings "$fig_settings" || stale=1
    rm -f PDF/.settings

    # individual PDFs
    while IFS=$'\t' read -r g n f; do
        if ! pdfinfo "$f" >/dev/null 2>&1; then
            echo "FAIL PDF: $f is not PDF-compatible (re-save with 'Create PDF Compatible File')"
            failed=$((failed + 1))
            continue
        fi
        base="${f%.*}"
        out="PDF/$base.pdf"
        list+="$g"$'\t'"$n"$'\t'"$out"$'\n'
        if [ "$stale" = 0 ] && up_to_date "$out" "$f"; then
            skipped=$((skipped + 1))
            continue
        fi
        rm -f "$out"
        in="$f"
        if [ "$LABELS" = 1 ] && ! in=$(labeled "$f"); then
            echo "FAIL PDF: $f (could not add label)"
            failed=$((failed + 1))
            continue
        fi
        if [ -z "$PY" ] || ! shrink_pdf "$in" "$out" 0; then
            cp "$in" "$out"
        fi
        record "$out" "$f"
        printf 'OK   %-46s %s\n' "$out" "$(du -h "$out" | cut -f1 | tr -d ' ')"
        made=$((made + 1))
    done < <(numbered_sources | sort -t$'\t' -k1,1 -k2,2n)

    [ "$failed" = "$failed0" ] && printf '%s\n' "$fig_settings" > PDF/.settings

    [ -n "$list" ] || { echo "FAIL PDF: no numbered .ai or .pdf files"; return 1; }

    # combined PDFs
    local prefix tag nums files half name p1 p2 tmp stamp settings
    for g in main supp; do
        nums=(); files=()
        while IFS=$'\t' read -r n f; do
            nums+=("$n"); files+=("$f")
        done < <(printf '%s' "$list" | awk -F'\t' -v g="$g" '$1 == g { print $2 "\t" $3 }')
        [ "${#files[@]}" -gt 0 ] || continue

        case "$g" in
            supp) prefix="Supplementary Figure"; tag=S ;;
            *)    prefix="Figure";               tag= ;;
        esac
        n=${#nums[@]}
        half=$(( (n + 1) / 2 ))
        # a single figure gets a singular name, no range, and is never split
        if [ "$n" -gt 1 ]; then
            name="PDF/${prefix}s $tag${nums[0]}-$tag${nums[n-1]}.pdf"
            p1="PDF/${prefix}s $tag${nums[0]}-$tag${nums[half-1]}.pdf"
            p2="PDF/${prefix}s $tag${nums[half]}-$tag${nums[n-1]}.pdf"
        else
            name="PDF/$prefix $tag${nums[0]}.pdf"
            p1=""; p2=""
        fi

        # skip if the same figure PDFs (by name, size and modification time)
        # and size cutoff as last time, and the combined file (or split pair)
        # is still there
        stamp="PDF/.$g.settings"
        settings="max_mb=$MAX_MB files="
        for f in "${files[@]}"; do
            settings+="$f ($(signature "$f")); "
        done
        if same_settings "$stamp" "$settings" &&
           { [ -s "$name" ] || { [ -s "$p1" ] && [ -s "$p2" ]; }; }; then
            skipped=$((skipped + 1))
            continue
        fi

        # clear previous combined/split outputs so a stale pair can't linger
        # (sparing any per-figure PDF that happens to share the singular name)
        rm -f "PDF/${prefix}s "*.pdf "$stamp"
        for f in "PDF/$prefix $tag"[0-9]*.pdf; do
            [ -e "$f" ] || continue
            [[ " ${files[*]} " == *" $f "* ]] || rm -f "$f"
        done

        tmp=$(mktemp -d) || return 1
        if ! pdfunite "${files[@]}" "$tmp/merged.pdf" 2>/dev/null; then
            rm -rf "$tmp"; echo "FAIL PDF: pdfunite could not merge the $g figures"
            failed=$((failed + 1)); continue
        fi

        local shrunk=0
        if [ -n "$PY" ]; then
            if [ "$n" -gt 1 ] && [ "$maxbytes" -gt 0 ]; then
                shrink_pdf "$tmp/merged.pdf" "$name" "$maxbytes" "$half" "$p1" "$p2" && shrunk=1
            else
                shrink_pdf "$tmp/merged.pdf" "$name" "$maxbytes" && shrunk=1
            fi
        fi
        if [ "$shrunk" = 0 ]; then
            rm -f "$name" "$p1" "$p2"
            cp "$tmp/merged.pdf" "$name"
        fi
        rm -rf "$tmp"
        printf '%s\n' "$settings" > "$stamp"

        for f in "$name" "$p1" "$p2"; do
            [ -s "$f" ] || continue
            printf 'OK   %-46s %s pages, %s\n' "$f" \
                "$(pdfinfo "$f" | awk '/^Pages:/ { print $2 }')" \
                "$(du -h "$f" | cut -f1 | tr -d ' ')"
            made=$((made + 1))
        done
        [ "$maxbytes" -gt 0 ] || continue
        [ -s "$name" ] || echo "     (over $MAX_MB MB, so split into two files)"
        for f in "$name" "$p1" "$p2"; do
            [ -s "$f" ] || continue
            if [ "$(wc -c < "$f")" -gt "$maxbytes" ]; then
                echo "WARN $f is still over $MAX_MB MB"
            fi
        done
    done
    return 0
}

# Render src into fmt unless the output is already up to date.
build() {
    local src="$1" base="$2" fmt="$3" out
    case "$fmt" in
        jpg)  out="JPG/$base.jpg"   ;;
        tiff) out="TIFF/$base.tiff" ;;
        png)  out="PNG/$base.png"   ;;
    esac
    if [ "$stale" = 0 ] && up_to_date "$out" "$src"; then
        skipped=$((skipped + 1))
    elif render "$src" "$base" "$fmt"; then
        record "$out" "$src"
        made=$((made + 1))
    else
        failed=$((failed + 1))
    fi
}

# Python for PDF shrinking and labels
PY=""
if [ "$PDF" = 1 ] || [ "$LABELS" = 1 ]; then
    PY=$(pdf_python) || PY=""
fi
if [ "$LABELS" = 1 ]; then
    [ -n "$PY" ] || { echo "--labels needs Python with pikepdf + reportlab, which could not be set up" >&2; exit 1; }
    LABEL_TMP=$(mktemp -d) || exit 1
    trap 'rm -rf "$LABEL_TMP"' EXIT
fi

formats=""
[ "$JPG" = 1 ]  && formats+=" jpg"
[ "$TIFF" = 1 ] && formats+=" tiff"
[ "$PNG" = 1 ]  && formats+=" png"

for fmt in $formats; do
    dir=$(printf '%s' "$fmt" | tr a-z A-Z)
    stamp="$dir/.settings"
    settings="dpi=$DPI"
    [ "$fmt" = jpg ] && settings+=" quality=$QUALITY"
    [ "$LABELS" = 1 ] && settings+=" $LABEL_KEY"
    # a new dpi/quality means every file in this format is out of date
    stale=0
    same_settings "$stamp" "$settings" || stale=1
    mkdir -p "$dir"
    rm -f "$stamp"

    fmt_failed=$failed
    while IFS= read -r src; do
        build "$src" "${src%.*}" "$fmt"
    done < <(sources)
    # any .png with no matching .ai or .pdf
    for src in *.png; do
        [ -e "$src" ] || continue
        base="$(basename "$src" .png)"
        [ -e "$base.ai" ] || [ -e "$base.pdf" ] && continue
        build "$src" "$base" "$fmt"
    done
    # record settings only if the whole format built, so failures retry
    [ "$failed" = "$fmt_failed" ] && printf '%s\n' "$settings" > "$stamp"
done

if [ "$PDF" = 1 ]; then
    command -v pdfunite >/dev/null || { echo "pdfunite not found (brew install poppler)" >&2; exit 1; }
    make_pdf || failed=$((failed + 1))
fi

echo
echo "Wrote $made file(s), $skipped up to date, $failed failure(s)"
for d in JPG TIFF PNG PDF; do
    [ -d "$d" ] || continue
    printf '%-6s %s\n' "$d/" "$(du -ch "$d" | tail -1 | cut -f1) total"
done

[ "$failed" -eq 0 ] || exit 1
exit 0

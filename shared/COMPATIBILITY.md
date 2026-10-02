# Existing BlurAction project compatibility contract

This folder provides shared **data foundations**, not a Mac or Windows application. It adds no dependency, rendering engine, media decoder, UI, installer or remote integration. Existing Mac models, `.bluraction` versions and legacy project bytes remain unchanged. The Python module uses only the standard library (Python 3.10 or newer).

Authoritative current implementation: `ProjectFile.swift`, `MultiPageProjectFile.swift`, `RegionShape.swift`, `DrawingAnnotation.swift`, `PageWorkspace.swift` and `RegionEditing.swift` in `Sources/BlurAction/`. `bluraction-project.schema.json` documents JSON Schema draft 2020-12 structure; `portable_project.py` performs additional semantic checks. Schema validation alone is insufficient. Schema tooling is optional and is not installed or used by this foundation.

The experimental v3 video metadata contract is described in [VIDEO_TIMELINE.md](VIDEO_TIMELINE.md). The shared reader preserves it; application loaders still require exact native source/decoder-clock integration before accepting it. Its existence does not certify playback, audio, export or legacy-video migration.

## Containers and geometry

| Format | Required fields | Bound |
| --- | --- | --- |
| v1 single-media | `version:1`, `mediaPath`, `regions`, `drawings` | 20 MiB UTF-8 JSON |
| v2 ordered workspace | `version:2`, `title`, `currentIndex`, `pages` | 50 MiB UTF-8 JSON; 1–200 pages; selected index within pages |
| v2 page | `mediaPath`, `regions`, `drawings` | Up to 1,000 regions and 5,000 drawings per page |
| v2 optional page metadata | `pdfPageIndex`, `sourceSHA256`, `pdfGeometryVersion` | PDF index 0–199; digest 64 lowercase hex characters; geometry version absent/null or 1, with 1 allowed only on PDF pages |

The pages array is the page order. Regions preserve their order and drawings preserve their order; the drawing list paints above the region list in the current Mac renderer. `currentIndex` is zero-based. Item UUIDs must be unique within a page across its regions and drawings; independent pages can reuse IDs. Groups reference UUIDs; no requirement that a separate group object exist. Undo/redo stacks, selection, media contents and output files are not saved in the project contract.

Geometry is normalized to a **1×1 bottom-left canvas**. A point and a size encode as `[x,y]` and `[width,height]`; a CGRect/NSRect encodes as `[[x,y],[width,height]]`. Values need not stay inside the visible frame: finite coordinates may range from -16 to 16. Sizes are finite 0…16; polygon bounding spans must also be at most 16. Normalized line/eraser widths scale with the Mac model's width scaling rule; a future renderer must reproduce `DrawingAnnotation.scaled` and `RegionEditing.scaled`, rather than choosing a pixel width independently.

Region shape is Swift Codable's tagged object, not a `type` field:

```json
{"rectangle":{"id":"11111111-1111-4111-8111-111111111111","origin":[0.1,0.2],"size":[0.3,0.4]}}
```

`ellipse` has the same payload. `polygon` has `{id,points:[[x,y],...]}`. Exactly one supported case is accepted. Empty/one-point polygon arrays are valid model data; validation does not invent additional shape vertices.

## Effects, drawings, motion and erasure

The current adapters add optional `sourceSHA256` to v1 as a backward-compatible
single-media integrity extension. Its value is a lowercase 64-character SHA-256.
Old projects without it remain readable, but provide no prior fingerprint proof.
Older Mac builds ignore this field; the new Mac candidate and Windows adapter
validate it before applying the project and before publishing an export. This
extension does not change the v1 video/media structure into a v2 page workspace.

| Record | Required fields | Added optional fields and Mac decode defaults |
| --- | --- | --- |
| Region record | `shape`, `effect` | None |
| Region effect | `blurRadius`, `featherRadius`, `timeRange`, `enabled`, `keyframes` | `style="blur"`, `color={red:0,green:0,blue:0,alpha:1}`, `groupID=nil`, `erasures=[]`, `name=nil`, `locked=false` |
| Drawing | `id`, `kind`, `points`, `red`, `green`, `blue`, `alpha`, `lineWidth` | `fillOpacity=0`, `timeRange=[0,0]`, `keyframes=[]`, `text=""`, `groupID=nil`, `erasures=[]`, `name=nil`, `hidden=false`, `locked=false`, `fontName=nil`, `bold=true`, `textBackground=nil` |
| Keyframe | `time`, `rect` | None |
| Eraser stroke | `points`, `width` | `from=nil` |
| RGBA color | `red`, `green`, `blue`, `alpha` | None |

Supported region cover styles are `blur`, `mosaic`, `solid`. Drawing kinds are `rectangle`, `ellipse`, `line`, `freehand`, `arrow`, `text`. Unknown enum cases are rejected; future fields on otherwise known records are retained and flagged for host review. A region's hidden state is `enabled=false`; it has no `hidden` JSON property. A drawing has a separate `hidden` flag. Locked items still render but cannot be directly picked/erased. Do not conflate those states or discard group, name, font, color or erasure metadata.

`blurRadius` and `featherRadius` are 0…500, `lineWidth` and eraser `width` are greater than 0 and at most 16, colors and fill opacity are 0…1. Arrays of points/keyframes cap at 100,000; erasures cap at 10,000. Numeric values must be finite. Time range is `[lower,upper]` with finite nonnegative bounds and lower ≤ upper. `[0,0]` is the whole-video sentinel; another equal interval is not that sentinel. Keyframe and erasure-start times are finite/nonnegative. The Mac JSON validator does not require sorted/unique keyframe times; this loader preserves those arrays instead of silently retiming them.

Video motion applies keyframes to the base shape at the playhead. Still images/PDF pages render with `time=nil`: base geometry, all time ranges ignored, and erasure `from` ignored. Erasure points remain in their item's base coordinate geometry and move with that item. Actual interpolation, clipping, alpha/fill composition, text layout, mosaic/blur and export must be verified against the native renderer before a Windows editor can claim matching behavior.

The original Swift decoder uses `decodeIfPresent` for added optional fields, so omitted or explicit-null optional fields have the defaults above. The shared loader **does not insert defaults or remove nulls** in saved JSON; it retains the original data. JSON whitespace, key ordering and slash escaping can change on write, but all JSON values, unknown fields and array order are preserved. Duplicate keys are rejected to avoid an ambiguous interpretation. Unknown versions are rejected. Nesting beyond 64 levels is refused as a bounded-parser safeguard.

Swift `String.count` limits are extended grapheme clusters: media paths ≤4,096, title ≤255, name/fontName ≤200, text ≤1,000. Python's standard library has no complete UAX #29 grapheme iterator. ASCII limits are enforced exactly except CRLF, which Swift counts as one cluster. Strings whose code-point count exceeds the limit and contains non-ASCII or CRLF are retained with `required_reviews` for host grapheme validation. The Windows Qt adapter uses `QTextBoundaryFinder.Grapheme`, respects UTF-16 boundaries, and resolves only the exact known grapheme review reasons after checking the complete tree. Unknown extension and legacy PDF reviews remain separate; a host review cannot be cleared merely by an acknowledgement flag. The schema uses `x-swift-graphemeLimit` annotations instead of an inaccurate JSON Schema `maxLength`. `required_reviews` is **not permission to render/export**: adapters must resolve all review reasons or refuse the operation. The same rule applies to unknown extension fields whose rendering meaning is not known.

## Paths, source identity and relinking

Project loading validates JSON only and never opens a referenced media file. `resolve_reference` uses lexical PurePath operations; it does not search the disk. Relative references resolve to the filename next to the project, matching the Mac basename rule, with both separator syntaxes flattened to prevent traversal. A new relative reference should be a bare filename.

Native POSIX absolute paths remain absolute on Mac; native Windows drive/UNC paths remain absolute on Windows. A path from the other OS yields `needs_relink`. Drive-relative `C:file.png` and root-relative `\file.png` are ambiguous and require explicit relinking. Windows reserved names (including COM/LPT superscript ¹²³ aliases), trailing dots/spaces, stream separators and invalid filename characters are not silently renamed. Windows output validation checks every path component before `Path` normalization, rejects device namespace and drive-relative destinations, and applies to project and media output. Normal drive-absolute and UNC paths remain supported. Mac POSIX destinations retain their native semantics. Path semantics are not a reason to guess that another same-named file is the original source.

`check_source` is an explicit opt-in helper: the caller supplies the selected resolved source and approved local roots. No approved roots means no source access. It reads only a nonempty, bounded regular file, refuses symlink leaves/intermediates, and checks size/inode/mtime/canonical identity around streaming SHA-256. It returns `verified`, `unverified` (no baseline), `changed`, `missing`, `blocked` or `needs_relink`. The initial lexical scope check precedes source inspection. The helper does not decode image/PDF/video data, upload it or copy it into a project.

For v2, compare saved `sourceSHA256` on **original paths as well as replacement paths** before opening/exporting. Repeat source identity verification immediately before export. An existing digest is never silently replaced. A missing hash in v1/legacy v2 is not integrity proof. `relink_media` requires the exact checked replacement path and matching saved digests; changed bytes are rejected even with a review flag. With no baseline, explicit reviewed-source acknowledgement is required. Relinking returns a new tree, changes only matching `mediaPath`, and retains all digests, geometry metadata, edits and unknown fields. Save it under a new project name using `save_project_new`.

Mac workspace source limits additionally require PDF ≤512 MiB, image ≤128 MiB and deduplicated total source bytes ≤1 GiB, readable/decodeable formats, unlocked PDFs and actual page index bounds. The generic helper defaults to ≤1 GiB for a selected file; adapters must pass the type-specific bound and enforce the total, file type, page count and decoder constraints. It is not a complete workspace opener. Filesystem race checks are best-effort integrity checks across platforms; OS-native secure file-handle ownership must be used where an adversarially mutable directory is in scope.

`pdfGeometryVersion=nil` means legacy PDF geometry. The Mac opener refuses edited legacy PDF pages when crop origin is nonzero or old crop dimensions differ from fixed display dimensions (epsilon 1e-6). Unaffected legacy pages and legacy empty pages remain valid. An edited legacy page produces a shared host-review reason because the dependency-free loader cannot inspect crop/rotation. A host must reproduce that geometry check or refuse export; **no automatic coordinate migration** and no implicit `pdfGeometryVersion=1` upgrade is provided. The Windows adapter now implements this raw geometry inspection with pinned pypdf 6.19.0, compares original PDF boxes/rotation with Qt display dimensions, and checks source identity/SHA before and after inspection. The 12-case synthetic set has two unaffected legacy pages and ten affected pages; actual raw backend execution remains pending in the current local environment. Missing pypdf explicitly refuses edited legacy PDF projects while preserving the current workspace. Unsupported UserUnit, malformed/inconsistent boxes or ambiguous geometry remain review gaps, without automatic migration. Marker 1 is retained exactly; an unknown marker or a marker on an image page is rejected.

`save_project_new` uses exclusive creation and never overwrites an existing destination (including a symlink). It writes project JSON only. Completed-content visibility is not atomic; consumers must wait for successful return. On failed writes it leaves the public path intact and raises `IncompleteProjectError.partial_output`: an inode check followed by unlink would still allow a replacement race. Inspect that explicitly incomplete output before manual removal. This helper is not a release/installer or a media-bundling operation.

## Focused verification and evidence boundaries

From the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/PortableProjectTests -v
```

Tests use temporary synthetic bytes, pure cross-OS path strings and only specifically named existing synthetic Mac QA JSON files. They never follow those fixture media references. `fixtures/GenerateSwiftContractFixtures.swift` lets the parent serial compiler create actual Swift-encoded v1/v2 rich JSON fixtures with every shape/kind, motion/erasure/style/text field. That generator references `synthetic.png` and `synthetic.pdf` by name only; it does not open or bundle media. The rich fixture test intentionally fails until the generated JSON files exist, so invented Python examples cannot substitute for actual Mac Codable evidence.

A parent-side command to build the generator (use a new QA build directory):

```sh
: "${CONTRACT_QA_BUILD:?Set a new QA build directory}"
mkdir -p "$CONTRACT_QA_BUILD/module-cache"
contract_sources=()
for contract_source in Sources/BlurAction/*.swift; do
  if [[ "${contract_source##*/}" != App.swift ]]; then
    contract_sources+=("$contract_source")
  fi
done
swiftc -target arm64-apple-macos14.0 -module-cache-path "$CONTRACT_QA_BUILD/module-cache" "${contract_sources[@]}" shared/fixtures/GenerateSwiftContractFixtures.swift -o "$CONTRACT_QA_BUILD/GenerateSwiftContractFixtures"
"$CONTRACT_QA_BUILD/GenerateSwiftContractFixtures" "$PWD/shared/fixtures"
```

The command uses a zsh/bash array and excludes `App.swift`. The parent owns compiler/test sequencing. The parent compiled and ran the generator and the shared tests on Mac; current evidence and limitations are recorded in `docs/검증-상태.md`. Python schema/data/source checks on Mac are not Windows native-runtime, installer or actual OS-input verification. The rich v2 fixture's digest is a deliberate placeholder, not a verified media baseline; source-hash tests use their own temporary synthetic bytes.

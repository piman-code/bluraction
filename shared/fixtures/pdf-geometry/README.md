# Public synthetic PDF geometry fixtures

The generator creates twelve small one-page PDFs, plus `manifest.json`, in a **new** directory. It reads no existing media, does not import the product, and refuses an existing destination. If generation fails, preserve the partial directory and choose a fresh name for a retry.

The cases match `PageWorkspaceTests.pdfRotationAndCropPreserveEdgesAnnotationsAndExportGeometry` and the 2026-10-01 `PDFGeometryProbe`: rotations 0/90/180/270 across these three layouts (PDF points):

| Family | MediaBox `(x,y,w,h)` | CropBox `(x,y,w,h)` |
| --- | --- | --- |
| zero | 0,0,100,160 | 0,0,100,160 |
| inset | 0,0,120,180 | 10,20,100,140 |
| nonzero | 30,40,120,180 | 40,60,100,140 |

Each PDF has four independently colored crop-corner markers, a 2-point gray crop border, and a central magenta **PDF annotation**. Expectations use crop-relative bottom-left coordinates and the explicit rotation formulas from the Mac regression; they are not derived by whichever decoder is under test. The manifest includes expected display-point/pixel sizes, transformed sample points, RGB values, and the final source SHA-256.

Compile and generate on macOS using system frameworks only. The parent controls serial execution. The twelve assets have been generated and the four Qt integration tests passed on macOS; the commands below are reproduction instructions, not Windows execution evidence. Substitute a fresh QA build directory for `QA` and an approved interpreter for `PYTHON`:

```sh
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$QA/module-cache" shared/fixtures/pdf-geometry/GeneratePDFGeometry.swift -o "$QA/GeneratePDFGeometry"
"$QA/GeneratePDFGeometry" "$QA/pdf-geometry-generated"
BLURACTION_PDF_GEOMETRY_DIR="$QA/pdf-geometry-generated" QT_QPA_PLATFORM=offscreen "$PYTHON" -m unittest discover -s Tests/WindowsAppTests -p test_pdf_geometry.py -v
```

`QA` must already exist; its `pdf-geometry-generated` destination must not exist. The example preserves the repository's previously generated assets. This Swift file needs no BlurAction source files or third-party dependency. Once generated, the PDF/JSON assets are platform neutral and Windows test execution does not require Swift. Set `BLURACTION_PDF_GEOMETRY_DIR` to the controlled fixture directory on that host. Missing assets are a failed preparation step, not a skipped successful proof.

Qt tests use the real `media.load_pages`, renderer, `export_pdf`, and reopening paths. They check all twelve source aspects/corners/borders/annotations, add normalized black covers over all corners, retain nearby uncovered white pixels and the central annotation, add a cyan drawing, export twelve pages, and recheck dimensions/positions. They also save/reopen fixed geometry projects and preserve every synthetic source byte. Temporary outputs belong to each test and are cleaned afterward; no user originals are read.

Legacy compatibility now has an optional raw-metadata backend, `pdf_geometry.py`, requiring the reviewed pypdf6.19.0 version. It inspects original MediaBox/CropBox/Rotate values, checks Qt's actual display size and source identity/SHA, and applies the Mac legacy review rule. For these twelve fixtures, edited `zero-r0` and `zero-r180` projects are safe; the other ten require review and are rejected before replacing the current workspace. No automatic coordinate migration occurs. Safe rotations of a square crop are a separate numeric policy case.

Without that exact backend, opening an edited PDF project lacking `pdfGeometryVersion` fails with an explicit compatibility-review error, including the two potentially safe cases. It does not guess raw geometry from Qt's displayed dimensions. Empty legacy PDF projects and fixed version1 projects are accepted; unknown geometry versions are rejected. The integration tests adapt to backend availability and assert old workspace/state/dirty and source/project byte preservation on rejection. They reuse the actual Swift-encoded v2 contract fixture. The manifest's `portableCurrentLegacyEditedRequiresReview` field retains the original conservative fixture-generation expectation; the loader's raw backend decision is asserted separately.

Evidence in `qa-20261001/cross-platform-planning-20261002/`: `qt-pdf12-linked-cancel.log` records the four actual Qt tests across all twelve cases. `qt-legacy-geometry-policy.log` records six numeric/fake-backend policy tests passing, while the actual metadata test class is skipped because pypdf is absent. Its seven actual raw-parser regressions remain **unverified**; the single class-level skip is not seven passing checks. Safe-case opening parity needs the approved backend plus these actual regressions and a Windows run. Do not count the backend-absent rejection branch as proof that safe raw geometry opens.

Passing on macOS proves host Qt/PDFium integration with these public fixtures. Actual Windows execution, packaging, live UI, and other PDF content types remain separate evidence.

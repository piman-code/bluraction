import copy
import hashlib
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from shared.portable_project import PortableProject, ProjectError, IncompleteProjectError, dump_project, load_project, save_project_new, validate_output_path
from shared.source_relink import check_source, relink_media, resolve_reference

REGION = "11111111-1111-4111-8111-111111111111"
DRAWING = "22222222-2222-4222-8222-222222222222"
GROUP = "33333333-3333-4333-8333-333333333333"


def fixture(version=1):
    effect = {"blurRadius": 25, "featherRadius": 12, "timeRange": [2, 5], "enabled": True,
        "keyframes": [{"time": 2, "rect": [[0.1, 0.2], [0.3, 0.4]]}],
        "style": "solid", "color": {"red": 0, "green": 0.2, "blue": 0.4, "alpha": 0.8},
        "groupID": GROUP, "erasures": [{"points": [[0.2, 0.3], [0.4, 0.5]], "width": 0.02, "from": 3}],
        "name": "가림", "locked": True}
    drawing = {"id": DRAWING, "kind": "text", "points": [[0.3, 0.4], [0.5, 0.6]],
        "red": 1, "green": 0.4, "blue": 0.3, "alpha": 0.7, "lineWidth": 0.01,
        "fillOpacity": 0.35, "timeRange": [1, 5], "keyframes": [{"time": 0, "rect": [[0.2, 0.4], [0.1, 0.2]]}],
        "text": "교사 검토\n합성 자료", "groupID": GROUP, "erasures": [{"points": [[0.3, 0.5]], "width": 0.03}],
        "name": "그림", "hidden": True, "locked": False, "fontName": "Helvetica", "bold": False,
        "textBackground": {"red": 1, "green": 1, "blue": 1, "alpha": 0.8}}
    page = {"mediaPath": "synthetic.png", "regions": [{"shape": {"rectangle": {"id": REGION,
        "origin": [0.1, 0.2], "size": [0.3, 0.4]}}, "effect": effect}], "drawings": [drawing]}
    if version == 1:
        return {"version": 1, **page}
    pdf = copy.deepcopy(page)
    pdf.update(mediaPath="synthetic.pdf", pdfPageIndex=0, pdfGeometryVersion=1, sourceSHA256="a" * 64)
    return {"version": 2, "title": "합성 묶음", "currentIndex": 1, "pages": [page, pdf]}


class PortableProjectTests(unittest.TestCase):
    def test_windows_output_namespaces_devices_and_streams_rejected_before_create(self):
        invalid = ['CON.bluraction', 'nul.PNG', 'COM¹.bluraction', 'LPT².txt',
                   'CONIN$', 'CLOCK$.txt', 'normal.txt:extra', 'normal. ', 'normal.',
                   'bad?name', 'bad\x01name', r'C:relative.bluraction',
                   r'\\?\C:\normal.bluraction', r'\\.\NUL', r'\??\C:\normal.bluraction',
                   r'C:\CON\normal.bluraction', r'\\server\share\NUL.txt']
        for name in invalid:
            with self.subTest(name=name), self.assertRaises(ProjectError):
                validate_output_path(name, platform='windows')
            self.assertNotEqual(resolve_reference(name, r'C:\project\review.bluraction', 'windows').state,
                                'resolved', 'Device and stream aliases must not become source files')
        for name in ['결과 이름.bluraction', r'C:\긴 한글 폴더\result.bluraction',
                     r'\\server\share\결과.bluraction', 'COM10.png', 'CONsole.png']:
            validate_output_path(name, platform='windows')
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'normal.bluraction:stream'
            # Exercise the actual shared writer with a Windows host boundary,
            # without pretending the local filesystem implements ADS.
            with patch('shared.portable_project.validate_output_path',
                       side_effect=lambda path: validate_output_path(path, platform='windows')):
                with self.assertRaises(ProjectError):
                    save_project_new(PortableProject(fixture()), destination)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_rich_v1_v2_roundtrip_retains_all_fields_arrays_and_unknowns(self):
        for version in (1, 2):
            data = fixture(version)
            data["futureExtension"] = {"instructions": "do not execute this string", "values": [3, 2, 1]}
            page = data if version == 1 else data["pages"][0]
            page["regions"][0]["effect"]["futureEffect"] = {"mode": "uninterpreted"}
            project = load_project(json.dumps(data).encode())
            self.assertTrue(project.required_reviews)
            self.assertEqual(load_project(dump_project(project)).to_dict(), data)
            exposed = project.to_dict(); exposed.clear()
            self.assertEqual(project.to_dict(), data, "copy access cannot mutate the stored contract")

    def test_all_shape_and_drawing_enum_cases_are_lossless(self):
        for shape_kind in ("rectangle", "ellipse", "polygon"):
            for drawing_kind in ("rectangle", "ellipse", "line", "freehand", "arrow", "text"):
                data = fixture()
                body = {"id": REGION, "points": [[0.1, 0.2], [0.5, 0.8]]} if shape_kind == "polygon" else {"id": REGION, "origin": [0.1, 0.2], "size": [0.3, 0.4]}
                data["regions"][0]["shape"] = {shape_kind: body}
                data["drawings"][0]["kind"] = drawing_kind
                self.assertEqual(load_project(dump_project(PortableProject(data))).to_dict(), data)

    def test_unknown_extensions_cannot_bypass_bytes_and_native_text_review(self):
        data = fixture(); data["futureExtension"] = "x" * 2000
        with patch("shared.portable_project.MAX_V2_BYTES", 1024), self.assertRaises(ProjectError):
            load_project(json.dumps(data))
        with patch("shared.portable_project.MAX_V1_BYTES", 64), self.assertRaises(ProjectError):
            dump_project(PortableProject(fixture()))
        data = fixture(); data["drawings"][0]["text"] = "x" * 1001
        with self.assertRaises(ProjectError):
            PortableProject(data)
        data["drawings"][0]["text"] = "e\u0301" * 700
        project = PortableProject(data)
        self.assertTrue(any("grapheme" in reason for reason in project.required_reviews))
        self.assertEqual(load_project(dump_project(project)).to_dict(), data)

    def test_old_optional_defaults_and_explicit_null_are_preserved_without_insertion(self):
        data = fixture()
        effect = data["regions"][0]["effect"]
        for field in ("style", "color", "groupID", "erasures", "name", "locked"):
            effect.pop(field)
        drawing = data["drawings"][0]
        for field in ("fillOpacity", "timeRange", "keyframes", "text", "groupID", "erasures", "name", "hidden", "locked", "fontName", "bold", "textBackground"):
            drawing.pop(field)
        drawing["fontName"] = None
        self.assertEqual(load_project(dump_project(PortableProject(data))).to_dict(), data)

    def test_malformed_and_future_contracts_are_rejected(self):
        mutations = [lambda d: d.update(version=3), lambda d: d.update(version=True),
            lambda d: d["regions"][0]["effect"].update(timeRange=[5, 2]),
            lambda d: d["regions"][0]["effect"].update(blurRadius=float("inf")),
            lambda d: d["regions"][0]["effect"].update(enabled=1),
            lambda d: d["regions"][0]["effect"].update(style="futureCover"),
            lambda d: d["drawings"][0].update(id=REGION.lower()),
            lambda d: d["drawings"][0].update(lineWidth=0),
            lambda d: d["drawings"][0].update(kind="futureDrawing"),
            lambda d: d["drawings"][0].update(erasures=[{"points": [], "width": 0}]),
            lambda d: d["regions"][0].update(shape={"futureShape": {"id": REGION}}),
            lambda d: d.update(mediaPath="bad\0.png")]
        for mutate in mutations:
            data = fixture(); mutate(data)
            with self.subTest(data=data), self.assertRaises(ProjectError):
                PortableProject(data)
        for payload in (b'{"version":1,"version":2}', b'{"version":NaN}', b'[]', b'{"version":1e9999}', b'\xff'):
            with self.assertRaises(ProjectError):
                load_project(payload)

    def test_v2_page_integrity_geometry_version_and_selection_boundaries(self):
        for mutation in (lambda d: d.update(currentIndex=2), lambda d: d.update(pages=[]),
            lambda d: d["pages"][0].update(pdfGeometryVersion=1),
            lambda d: d["pages"][1].update(pdfGeometryVersion=2),
            lambda d: d["pages"][1].update(pdfPageIndex=200),
            lambda d: d["pages"][1].update(sourceSHA256="A" * 64)):
            data = fixture(2); mutation(data)
            with self.assertRaises(ProjectError):
                PortableProject(data)
        legacy = fixture(2); legacy["pages"][1].pop("pdfGeometryVersion")
        self.assertTrue(any("legacy edited PDF" in review for review in PortableProject(legacy).required_reviews))
        legacy["pages"][1]["regions"] = []; legacy["pages"][1]["drawings"] = []
        self.assertFalse(PortableProject(legacy).required_reviews)
        copies = fixture(2); copies["pages"][1]["regions"] = copy.deepcopy(copies["pages"][0]["regions"])
        self.assertEqual(PortableProject(copies).version, 2, "IDs are unique within each page, not across pages")

    def test_save_never_overwrites_and_does_not_include_source_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "project.bluraction"
            project = PortableProject(fixture())
            save_project_new(project, destination)
            original = destination.read_bytes()
            self.assertEqual(load_project(original).to_dict(), fixture())
            with self.assertRaises(FileExistsError):
                save_project_new(project, destination)
            self.assertEqual(destination.read_bytes(), original)
            self.assertEqual([p.name for p in Path(folder).iterdir()], ["project.bluraction"])

    def test_failed_save_reports_preserved_public_output_without_unlink(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'incomplete.bluraction'
            with patch('shared.portable_project.os.fsync', side_effect=OSError('synthetic fsync failure')), \
                 patch('shared.portable_project.os.unlink', side_effect=AssertionError('public cleanup must not unlink')):
                with self.assertRaises(IncompleteProjectError) as result:
                    save_project_new(PortableProject(fixture()), destination)
            self.assertEqual(result.exception.partial_output, destination)
            self.assertTrue(destination.is_file())
            self.assertEqual(load_project(destination.read_bytes()).to_dict(), fixture())

    def test_failed_save_leaves_concurrently_replaced_destination_intact(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'rival.bluraction'
            rival = Path(folder) / 'replacement'
            rival.write_bytes(b'preserve rival')
            replacement = []
            def failure(_):
                try:
                    os.replace(rival, destination)
                except PermissionError:
                    # Windows normally denies replacement while this CRT fd is
                    # open. This is preservation, not a published rival path.
                    replacement.append('blocked-while-open')
                else:
                    replacement.append('published-rival')
                raise OSError('synthetic write failure after native replacement attempt')
            with patch('shared.portable_project.os.fsync', side_effect=failure), \
                 patch('shared.portable_project.os.unlink', side_effect=AssertionError('public cleanup must not unlink')):
                with self.assertRaises(IncompleteProjectError) as result:
                    save_project_new(PortableProject(fixture()), destination)
            self.assertEqual(result.exception.partial_output, destination)
            self.assertEqual(len(replacement), 1, 'The native replacement attempt must run')
            self.assertIs(type(result.exception.__cause__), OSError)
            self.assertEqual(str(result.exception.__cause__), 'synthetic write failure after native replacement attempt')
            print('NATIVE_REPLACEMENT_JSON=' + json.dumps({'phase': 'while-open', 'outcome': replacement[0], 'bothInputsPreserved': replacement[0] == 'blocked-while-open'}))
            if replacement == ['published-rival']:
                self.assertEqual(destination.read_bytes(), b'preserve rival')
                self.assertFalse(rival.exists())
            else:
                self.assertEqual(replacement, ['blocked-while-open'])
                self.assertEqual(destination.read_bytes(), dump_project(PortableProject(fixture())))
                self.assertEqual(rival.read_bytes(), b'preserve rival')

    def test_failed_close_leaves_actual_replaced_destination_intact_on_each_os(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'rival-after-close.bluraction'
            rival = Path(folder) / 'replacement'
            rival.write_bytes(b'preserve actual rival after close')
            real_fdopen = os.fdopen
            replaced = []
            class CloseThenReplace:
                def __init__(self, stream): self.stream = stream
                def __enter__(self): return self.stream.__enter__()
                def __exit__(self, kind, value, traceback):
                    self.stream.__exit__(kind, value, traceback)
                    self_closed = self.stream.closed
                    if not self_closed: raise AssertionError('Replacement must follow actual fd close')
                    os.replace(rival, destination)
                    replaced.append(True)
                    raise OSError('synthetic failure after close and actual public replacement')
            def wrapped_fdopen(fd, mode): return CloseThenReplace(real_fdopen(fd, mode))
            with patch('shared.portable_project.os.fdopen', side_effect=wrapped_fdopen), \
                 patch('shared.portable_project.os.unlink', side_effect=AssertionError('public cleanup must not unlink')):
                with self.assertRaises(IncompleteProjectError) as result:
                    save_project_new(PortableProject(fixture()), destination)
            self.assertEqual(result.exception.partial_output, destination)
            self.assertEqual(replaced, [True])
            self.assertIs(type(result.exception.__cause__), OSError)
            self.assertEqual(str(result.exception.__cause__), 'synthetic failure after close and actual public replacement')
            print('NATIVE_REPLACEMENT_JSON=' + json.dumps({'phase': 'after-close', 'outcome': 'published-rival', 'rivalPreserved': True}))
            self.assertEqual(destination.read_bytes(), b'preserve actual rival after close')
            self.assertFalse(rival.exists())

    def test_existing_controlled_mac_v2_json_fixtures_load_without_source_reads(self):
        repository = Path(__file__).resolve().parents[2]
        paths = [repository / "gui-fixtures-20260928/fixed-candidate-images.bluraction",
            repository / "gui-fixtures-20260928/fixed-candidate-pdf.bluraction",
            repository / "qa-20261001/supplemental-output/page-specific.bluraction"]
        available = [path for path in paths if path.is_file()]
        if not available:
            self.skipTest("Local controlled Mac QA JSON fixtures are not present on this checkout")
        for path in available:
            payload = path.read_bytes()  # Only known synthetic project JSON, never its referenced media.
            project = load_project(payload)
            self.assertEqual(project.version, 2)
            self.assertEqual(load_project(dump_project(project)).to_dict(), json.loads(payload))

    def test_actual_swift_encoded_rich_v1_v2_contract_fixtures(self):
        repository = Path(__file__).resolve().parents[2]
        for version in (1, 2):
            path = repository / f"shared/fixtures/swift-v{version}-rich.bluraction"
            self.assertTrue(path.is_file(), "Parent must generate actual Swift Codable fixtures before final compatibility validation")
            payload = path.read_bytes()
            project = load_project(payload)
            self.assertEqual(project.version, version)
            self.assertEqual(load_project(dump_project(project)).to_dict(), json.loads(payload))
            page = project.to_dict() if version == 1 else project.to_dict()["pages"][0]
            self.assertEqual({next(iter(r["shape"])) for r in page["regions"]}, {"rectangle", "ellipse", "polygon"})
            self.assertEqual({d["kind"] for d in page["drawings"]}, {"rectangle", "ellipse", "line", "freehand", "arrow", "text"})
            self.assertEqual(page["regions"][0]["effect"]["keyframes"][0]["rect"], [[0.1, 0.2], [0.3, 0.4]])


class PathAndSourceTests(unittest.TestCase):
    def test_drive_unc_foreign_roots_and_no_traversal_resolution(self):
        self.assertEqual(resolve_reference(r"C:\media\a.png", r"D:\project\x.bluraction", "windows").path, r"C:\media\a.png")
        self.assertEqual(resolve_reference(r"\\server\share\a.pdf", r"D:\project\x.bluraction", "windows").path, r"\\server\share\a.pdf")
        self.assertEqual(resolve_reference("/media/a.png", "/project/x.bluraction", "macos").path, "/media/a.png")
        for ref, os_name, project in [(r"C:\media\a.png", "macos", "/project/x.bluraction"),
            (r"\\server\share\a.pdf", "macos", "/project/x.bluraction"),
            ("/media/a.png", "windows", r"D:\project\x.bluraction"),
            (r"C:a.png", "windows", r"D:\project\x.bluraction"),
            (r"\a.png", "windows", r"D:\project\x.bluraction")]:
            self.assertEqual(resolve_reference(ref, project, os_name).state, "needs_relink")
        self.assertEqual(resolve_reference("../../media/a.png", "/project/x.bluraction", "macos").path, "/project/a.png")
        self.assertEqual(resolve_reference(r"..\..\a.png", r"D:\project\x.bluraction", "windows").path, r"D:\project\a.png")
        for ref in ("..", ".", "", "bad\0.png"):
            self.assertEqual(resolve_reference(ref, "/project/x.bluraction", "macos").state, "invalid")
        for ref in ("NUL.png", "a:stream.png", "file. "):
            self.assertEqual(resolve_reference(ref, r"D:\project\x.bluraction", "windows").state, "needs_relink")

    def test_scoped_source_missing_changed_matching_and_unverified_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "synthetic.png"
            source.write_bytes(b"controlled synthetic source only")
            baseline = hashlib.sha256(source.read_bytes()).hexdigest()
            platform = "windows" if os.name == "nt" else "macos"
            resolution = resolve_reference(str(source), str(root / "x.bluraction"), platform)
            self.assertEqual(check_source(resolution, baseline, approved_roots=[]).state, "blocked")
            self.assertEqual(check_source(resolution, baseline, approved_roots=[root]).state, "verified")
            self.assertEqual(check_source(resolution, None, approved_roots=[root]).state, "unverified")
            source.write_bytes(b"changed synthetic source")
            changed = check_source(resolution, baseline, approved_roots=[root])
            self.assertEqual(changed.state, "changed")
            self.assertEqual(changed.expected_sha256, baseline, "Never silently refresh a saved hash")
            source.unlink()
            self.assertEqual(check_source(resolution, baseline, approved_roots=[root]).state, "missing")

    def test_relink_requires_exact_checked_source_and_keeps_all_edits_and_hashes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / "relinked.png"
            source.write_bytes(b"synthetic relink bytes")
            baseline = hashlib.sha256(source.read_bytes()).hexdigest()
            data = fixture(2); data["pages"] = [data["pages"][0]]; data["currentIndex"] = 0
            data["pages"][0].update(mediaPath=r"C:\old\synthetic.png", sourceSHA256=baseline)
            project = PortableProject(data)
            platform = "windows" if os.name == "nt" else "macos"
            project_location = str(root / "relinked.bluraction")
            resolution = resolve_reference("relinked.png", project_location, platform)
            checked = check_source(resolution, baseline, approved_roots=[root])
            relinked = relink_media(project, project.sources[0].media_path, "relinked.png",
                project_location=project_location, platform=platform, checked=checked)
            expected = copy.deepcopy(data); expected["pages"][0]["mediaPath"] = "relinked.png"
            self.assertEqual(relinked.to_dict(), expected)
            self.assertEqual(project.to_dict(), data, "Relinking returns a new project, preserving the original")
            source.write_bytes(b"changed source")
            changed = check_source(resolution, baseline, approved_roots=[root])
            with self.assertRaises(ProjectError):
                relink_media(project, project.sources[0].media_path, "relinked.png", project_location=project_location,
                    platform=platform, checked=changed, allow_unverified_reviewed_source=True)
            with self.assertRaises(ProjectError):
                relink_media(project, project.sources[0].media_path, "other.png", project_location=project_location,
                    platform=platform, checked=checked)

    def test_legacy_no_hash_relink_needs_explicit_review_and_symlink_is_blocked(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / "reviewed.png"; source.write_bytes(b"synthetic")
            platform = "windows" if os.name == "nt" else "macos"; location = str(root / "x.bluraction")
            checked = check_source(resolve_reference("reviewed.png", location, platform), None, approved_roots=[root])
            project = PortableProject(fixture())
            with self.assertRaises(ProjectError):
                relink_media(project, "synthetic.png", "reviewed.png", project_location=location, platform=platform, checked=checked)
            reviewed = relink_media(project, "synthetic.png", "reviewed.png", project_location=location,
                platform=platform, checked=checked, allow_unverified_reviewed_source=True)
            self.assertEqual(reviewed.sources[0].expected_sha256, None)
            link = root / "linked.png"
            try:
                link.symlink_to(source)
            except OSError:
                self.skipTest("This platform/account cannot create synthetic symlinks")
            self.assertEqual(check_source(resolve_reference("linked.png", location, platform), None,
                approved_roots=[root]).state, "blocked")


if __name__ == "__main__":
    unittest.main()

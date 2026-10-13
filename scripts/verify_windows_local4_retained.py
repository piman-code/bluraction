"""Selected local4 regressions; retain authored fixtures and never clean files.

Requires an already prepared Qt/media Python environment. No installation,
packaging, UI automation, or full-suite claim. --output must not already exist.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

EXCLUDED = {
    "test_close_context_cleanup_and_invalid_exact_query_no_resource_leak",
    "test_same_cancel_error_during_active_pixels_and_decoder_close_preserves_first_error",
}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(root))
    sys.path.insert(0, str(root / "Tests/WindowsAppTests"))
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ["BLURACTION_FEATURE_TEST_OUTPUT"] = str(output)
    from platforms.windows.bluraction.video_compat_smoke import retain_files
    from platforms.windows.bluraction import frame_inventory
    retain_files(output / "retained")
    # Existing test tearDown calls become no-ops for diagnostic-owned fixtures.
    # Production cleanup behavior is unchanged outside this dedicated process.
    tempfile.TemporaryDirectory = frame_inventory.tempfile.TemporaryDirectory
    tempfile.TemporaryFile = frame_inventory.tempfile.TemporaryFile
    loader = unittest.TestLoader()
    suite = unittest.TestSuite([
        loader.loadTestsFromName("test_display_geometry"),
        loader.loadTestsFromName("test_windows_performance"),
        loader.loadTestsFromName("test_preview_worker"),
        loader.loadTestsFromName("test_auto_find_windows"),
        loader.loadTestsFromName("test_video_pixel_contract"),
        loader.loadTestsFromName("test_pdf_user_unit"),
        loader.loadTestsFromName("test_canonical_transport.CanonicalTransportTests.test_child_handshake_sar_matches_shared_display_policy"),
    ])
    import test_canonical_video
    for name in loader.getTestCaseNames(test_canonical_video.CanonicalVideoTests):
        if name not in EXCLUDED:
            suite.addTest(test_canonical_video.CanonicalVideoTests(name))
    import test_engine
    for name in [
        "test_partial_black_mask_composites_in_linear_light",
        "test_mosaic_black_white_centers_use_linear_light_and_keep_tiles",
        "test_blur_and_mosaic_premultiply_transparent_color_before_filtering",
        "test_effect_float_filter_prefix_is_tiled_finite_and_clamped",
        "test_linear_effect_endpoints_keep_exact_source_and_original_sampling",
        "test_alpha_annotation_is_composited_once",
        "test_fill_opacity_uses_same_single_linear_overlay_composite",
        "test_annotation_erasure_is_isolated_and_respects_time_and_layer_order",
        "test_annotation_over_transparent_source_has_no_hidden_color_bleed",
    ]:
        suite.addTest(test_engine.EngineTests(name))
    with (output / "tests.log").open("x", encoding="utf8") as log:
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    record = {"run": result.testsRun, "passed": result.wasSuccessful(),
              "failures": [(str(test), message) for test, message in result.failures],
              "errors": [(str(test), message) for test, message in result.errors],
              "filesRetained": True, "excludedDeletionAssertions": sorted(EXCLUDED),
              "scope": "selected Windows Qt engine regressions; not complete OS acceptance"}
    with (output / "report.json").open("x", encoding="utf8") as stream:
        json.dump(record, stream, ensure_ascii=False, indent=2)
    print(json.dumps({key: record[key] for key in ("run", "passed", "filesRetained")}), flush=True)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())

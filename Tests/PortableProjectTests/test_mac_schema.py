"""The Mac-only v4-v7 schema: references resolve and its rules match the Swift models."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHARED = ROOT / "shared"
SWIFT = ROOT / "Sources/BlurAction"


def load(name):
    return json.loads((SHARED / name).read_text(encoding="utf-8"))


def swift_cases(file, enum):
    text = (SWIFT / file).read_text(encoding="utf-8")
    match = re.search(r"enum %s: String, Codable \{ case ([^}]+) \}" % enum, text)
    assert match, (file, enum)
    return [c.strip() for c in match.group(1).split(",")]


class MacSchemaTests(unittest.TestCase):
    def setUp(self):
        self.base = load("bluraction-project.schema.json")
        self.mac = load("bluraction-project-mac.schema.json")
        self.defs = self.mac["$defs"]

    def resolve(self, ref):
        document, _, pointer = ref.partition("#")
        target = {"": self.mac, self.base["$id"]: self.base}[document]
        for part in pointer.strip("/").split("/"):
            target = target[part]
        return target

    def test_every_reference_resolves(self):
        refs = []

        def walk(node):
            if isinstance(node, dict):
                if "$ref" in node:
                    refs.append(node["$ref"])
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(self.mac)
        self.assertGreater(len(refs), 20)
        for ref in refs:
            with self.subTest(ref=ref):
                self.assertIsInstance(self.resolve(ref), dict)

    def test_covers_exactly_the_mac_versions_and_leaves_the_portable_schema_alone(self):
        self.assertEqual(self.mac["oneOf"], [{"$ref": "#/$defs/v%d" % v} for v in (4, 5, 6, 7)])
        for version in (4, 5, 6, 7):
            self.assertEqual(self.defs["v%d" % version]["properties"]["version"]["const"], version)
            self.assertFalse(self.defs["v%d" % version]["additionalProperties"])
        self.assertEqual(self.base["oneOf"], [{"$ref": "#/$defs/v1"}, {"$ref": "#/$defs/v2"}, {"$ref": "#/$defs/v3"}])

    def test_enumerations_match_the_swift_models(self):
        review = self.defs["trackingReview"]["properties"]
        self.assertEqual(review["reason"]["enum"], swift_cases("TrackingReview.swift", "Reason"))
        self.assertEqual(review["status"]["enum"], swift_cases("TrackingReview.swift", "Status"))
        cover = self.defs["automaticCover"]["properties"]
        self.assertEqual(cover["kind"]["enum"], swift_cases("AutomaticCover.swift", "Kind"))
        self.assertEqual(cover["mode"]["enum"], swift_cases("AutomaticCover.swift", "Mode"))

    def test_fields_and_bounds_match_the_swift_models(self):
        automatic = (SWIFT / "AutomaticCover.swift").read_text(encoding="utf-8")
        decoration = (SWIFT / "CoverDecoration.swift").read_text(encoding="utf-8")
        cover = self.defs["automaticCover"]
        allowed = re.search(r'validate\(decoder, allowed: \[("kind"[^\]]+)\]\)', automatic).group(1)
        self.assertEqual(set(cover["properties"]), set(re.findall(r'"(\w+)"', allowed)))
        self.assertIn("(4...32).contains(safetyMargin)", automatic)
        self.assertEqual((cover["properties"]["safetyMargin"]["minimum"], cover["properties"]["safetyMargin"]["maximum"]), (4, 32))
        self.assertIn("(3...512).contains(points.count)", automatic)
        self.assertEqual((cover["properties"]["evidencePoints"]["minItems"], cover["properties"]["evidencePoints"]["maxItems"]), (3, 512))
        self.assertIn("phrases.count <= 64", automatic)
        self.assertIn("evidenceKeyframes.count <= 10_000", automatic)
        self.assertIn("(1...100_000).contains($0)", automatic)
        self.assertIn("(0.1...1).contains(scale)", decoration)
        self.assertEqual(self.defs["coverDecoration"]["properties"]["scale"], {"type": "number", "minimum": 0.1, "maximum": 1})
        effect = (SWIFT / "RegionShape.swift").read_text(encoding="utf-8")
        for field in ("inverted", "decoration", "trackingReviews", "automaticCover"):
            self.assertIn(field, effect)
            self.assertIn(field, self.defs["macEffect"]["properties"])


if __name__ == "__main__":
    unittest.main()

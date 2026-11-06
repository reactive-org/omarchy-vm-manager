import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class TerminalVendorTests(unittest.TestCase):
    def test_exact_library_inventory(self):
        root = ROOT / 'Vendor/SwiftTerm'
        inventory = json.loads((root / 'inventory.json').read_text())
        self.assertFalse(any(p.is_symlink() for p in root.rglob('*')))
        actual = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in root.rglob('*') if p.is_file() and p.name != 'inventory.json'}
        self.assertEqual(actual, inventory['files'])
        self.assertEqual(inventory['revision'], '2dad6a1e516f755bed77cf9bbd09455062f54758')
        self.assertEqual(inventory['tag'], 'v1.99.0')

    def test_reviewed_grapheme_bound_patch(self):
        root = ROOT / 'Vendor/SwiftTerm'
        inventory = json.loads((root / 'inventory.json').read_text())
        patch = inventory['patch']
        self.assertEqual(hashlib.sha256((ROOT / patch['path']).read_bytes()).hexdigest(), patch['sha256'])
        source = (root / 'Sources/SwiftTerm/CellStorage.swift').read_text()
        original = source.replace('        // Manager display bound, including clusters extended after cursor/SGR commands.\n        guard scalars.count <= 16 else { return nil }\n', '')
        self.assertNotEqual(source, original)
        self.assertEqual(hashlib.sha256(original.encode()).hexdigest(), patch['upstream_cell_storage_sha256'])

    def test_library_has_no_dependency_plugin_or_process_frontend(self):
        manifest = (ROOT / 'Vendor/SwiftTerm/Package.swift').read_text()
        self.assertNotIn('.package(', manifest)
        self.assertNotIn('.plugin(', manifest)
        self.assertNotIn('.executableTarget(', manifest)
        for path in ['LocalProcess.swift', 'HeadlessTerminal.swift', 'Pty.swift', 'Mac/MacLocalTerminalView.swift']:
            self.assertIn('"' + path + '"', manifest)
        notice = (ROOT / 'THIRD_PARTY_NOTICES.md').read_text()
        self.assertIn('SwiftTerm 1.99.0', notice)
        self.assertIn('Miguel de Icaza', notice)

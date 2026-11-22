import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / '.build/runtime-source/guest/package'
spec = importlib.util.spec_from_file_location('native_rendering', ROOT / 'native-rendering.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeRenderingTests(unittest.TestCase):
    def test_variant_preserves_home_and_owner_programs_without_software_wrappers(self):
        with tempfile.TemporaryDirectory(prefix='omarchy-native-package-') as scratch:
            recipe = Path(scratch) / 'recipe'
            shutil.copytree(ROOT / 'try-omarchy', recipe, symlinks=True)
            module.prepare(recipe)
            self.assertIn('pkgrel=49.1', (recipe / 'PKGBUILD').read_text())
            self.assertNotIn('WLR_RENDERER_ALLOW_SOFTWARE=1', (recipe / 'files/usr/lib/environment.d/90-try-omarchy.conf').read_text())
            self.assertFalse((recipe / 'files/usr/lib/try-omarchy/bin/ghostty').exists())
            self.assertFalse((recipe / 'files/usr/lib/try-omarchy/bin/kitty').exists())
            self.assertIn('skip_non_kms_dmabuf_formats = false', (recipe / 'files/usr/share/try-omarchy/hyprland.lua').read_text())
            for name in ['managed-home', 'managed-owner-setup', 'managed-ssh']:
                relative = Path('files/usr/lib/try-omarchy') / name
                self.assertEqual((recipe / relative).read_bytes(), (ROOT / 'try-omarchy' / relative).read_bytes())
            with self.assertRaises(ValueError): module.prepare(recipe)


if __name__ == '__main__': unittest.main()

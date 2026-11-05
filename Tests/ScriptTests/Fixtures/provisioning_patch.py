"""Synthetic patch on disposable public-source copies, independent of product pins."""
import json


def add_patch_fixture(root, package):
    _, lock = package.read_lock(root)
    assert not lock["integrationPatches"]
    original = package.files(root / lock["package"])
    # A new file reproduces Git's ignored-parent reverse-apply failure. A patch
    # that only edits an existing file does not exercise that historical case.
    name = "integration-fixture.txt"
    target = root / lock["package"] / name
    assert not target.exists()
    patch = root / "Patches/fixture.patch"
    patch.parent.mkdir(parents=True, exist_ok=True)
    patch.write_text(f"diff --git a/{name} b/{name}\nnew file mode 100644\n"
                     f"--- /dev/null\n+++ b/{name}\n@@ -0,0 +1 @@\n"
                     "+Disposable integration-patch fixture.\n")
    target.write_text("Disposable integration-patch fixture.\n")
    lock["baseFiles"] = original
    lock["files"] = package.files(root / lock["package"])
    lock["sourceSnapshotSHA256"] = package.sha(json.dumps(lock["files"], sort_keys=True, separators=(",", ":")).encode())
    lock["integrationPatches"] = [{"path": "Patches/fixture.patch", "sha256": package.sha(patch.read_bytes())}]
    raw = (json.dumps(lock, indent=2, sort_keys=True) + "\n").encode()
    (root / package.LOCK).write_bytes(raw)
    (root / "Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift").write_text(package.pin_source(raw, lock))
    return lock

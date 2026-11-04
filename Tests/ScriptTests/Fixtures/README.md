The frozen provisioning helper is the exact reviewed six-file-overlay version
from the retained 7e46241 candidate inputs. SHA-256:
`d8dd52279c990c29925ac98761f4b8ad1f5ec6db88dd13cee15c7c15138df13f`.

It is a test fixture, not a replacement for Scripts/provisioning_package.py.
Tests copy it with pinned public package inputs into disposable directories and
execute only Python and local Git, never build/sign/guest tools.

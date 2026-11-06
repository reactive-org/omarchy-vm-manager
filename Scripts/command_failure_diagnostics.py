"""Closed failure hints from bounded bytes; never persist raw child output."""
# Exact final traceback lines from the reviewed frozen helper. This classifies
# observed output, not the unretained error from an earlier attempt.
HELPER_ERRORS = {
    b'ValueError: Provisioning patch base differs': 'provisioning-patch-base-mismatch',
    b'ValueError: Provisioning integration patch cannot be verified': 'provisioning-reverse-patch-failed',
    b'ValueError: Changed provisioning integration patch': 'provisioning-patch-changed',
    b'ValueError: Pinned dev-vm source changed': 'provisioning-source-changed',
    b'ValueError: Writable provisioning entry': 'provisioning-writable-entry',
    b'ValueError: Linked/special provisioning entry': 'provisioning-special-entry',
    b'ValueError: Invalid provisioning package': 'provisioning-contract',
    b'ValueError: Unexpected launcher build input': 'provisioning-launcher-input',
    b'ValueError: Optional parser build plugins are not admitted': 'provisioning-optional-plugin',
}


def classify_failure(command, exit_status, stderr, complete):
    """Return only fixed tokens. Neither exception/path/subject text nor hashes
    of raw output are retained. Malformed or incomplete streams never match a
    helper signature; other stages cannot impersonate a preparation failure.
    """
    phase = 'provisioning-prepare' if command.stage == 'prepare-pinned-provisioning-source' else (
        'sign' if command.effect == 'sign-with-timestamp' else 'build' if command.effect == 'build' else 'command')
    code = 'command-output-incomplete'
    if complete is True:
        code = 'command-signal' if type(exit_status) is int and exit_status < 0 else 'command-exit-unclassified'
        if phase == 'provisioning-prepare' and type(exit_status) is int and exit_status > 0 and type(stderr) is bytes and len(stderr) <= 2*1024*1024:
            lines = stderr.splitlines()
            if lines: code = HELPER_ERRORS.get(lines[-1], code)
    return {'format': 1, 'phase': phase, 'code': code, 'stderrComplete': complete is True}

"""Retry explicit transient Apple ticket connection failures on unchanged bytes."""
import subprocess
import sys
import time

TRANSIENT_ERRORS = ('NSURLErrorDomain Code=-1005', 'NSURLErrorDomain Code=-1001', 'NSURLErrorDomain Code=-1009')


def retry_ticket_call(operation, label):
    for attempt in range(3):
        try:
            return operation()
        except (RuntimeError, subprocess.CalledProcessError) as error:
            detail = str(error) + str(getattr(error, 'stdout', '') or '') + str(getattr(error, 'stderr', '') or '')
            if attempt == 2 or not any(marker in detail for marker in TRANSIENT_ERRORS):
                raise
            print(f'{label}: transient Apple ticket connection failure; retrying the same bytes', flush=True)
            time.sleep(5 * (attempt + 1))


def run_ticket_checked(*arguments):
    def operation():
        return subprocess.run([str(value) for value in arguments], capture_output=True, text=True, check=True)
    try:
        result = retry_ticket_call(operation, 'Apple ticket verification')
    except subprocess.CalledProcessError as error:
        if error.stdout: print(error.stdout, end='')
        if error.stderr: print(error.stderr, end='', file=sys.stderr)
        raise
    if result.stdout: print(result.stdout, end='')
    if result.stderr: print(result.stderr, end='', file=sys.stderr)
    return result

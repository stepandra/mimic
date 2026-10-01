"""Pure report validator; never executes targets, Docker, or host commands."""
import json
import sys

COMMON = frozenset('''target_identity limits cgroup_memory cgroup_pids environment_exact
no_extra_fds stdin_eof cwd_private umask_private work_writable tmp_writable
root_write_denied etc_write_denied runtime_write_denied containment_read_denied
boundary_read_denied owner_fd_denied tcp_allowed tcp_denied bind_allowed bind_denied
udp_denied udp6_denied unix_denied raw_denied packet_denied socketpair_denied
io_uring_denied network_namespace_denied setns_denied'''.split())
BASELINE = COMMON | {'self_status_readable', 'capabilities_zero',
                     'bounding_set_transition_only', 'no_new_privileges', 'seccomp_filter'}
SCHEMA = [
    {'fixture_ready', 'listening_39001', 'listening_39002'},
    {'check_exact'}, BASELINE, COMMON, {'descendant_inherited'},
    {'malformed_cli_no_exec', 'suite_passed'},
]


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate_key')
        result[key] = value
    return result


def verify(text, returncode):
    if returncode != 0 or len(text.encode()) > 16384:
        return False
    try:
        reports = [json.loads(line, object_pairs_hook=unique_object)
                   for line in text.splitlines()]
    except (ValueError, TypeError):
        return False
    return len(reports) == len(SCHEMA) and all(
        type(report) is dict and set(report) == keys
        and all(value is True for value in report.values())
        for report, keys in zip(reports, SCHEMA)
    )


if __name__ == '__main__':
    # Caller separately obtains exact process exit status and bounded output.
    if len(sys.argv) != 2:
        raise SystemExit(2)
    try:
        status = int(sys.argv[1])
    except ValueError:
        raise SystemExit(2)
    valid = verify(sys.stdin.read(16385), status)
    print(json.dumps({'report_accepted': valid}))
    raise SystemExit(0 if valid else 1)

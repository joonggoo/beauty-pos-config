import copy
import json
import subprocess
import sys


def validate_progression(previous, current):
    for package, before in previous.get('apps', {}).items():
        after = current.get('apps', {}).get(package)
        if not isinstance(after, dict):
            raise ValueError('Published app removed: ' + package)
        old_code = before['latest_version_code']
        new_code = after.get('latest_version_code')
        if type(new_code) is not int or new_code < old_code:
            raise ValueError('Published version downgrade: ' + package)
        if new_code == old_code and after.get('latest_version') != before['latest_version']:
            raise ValueError('Version code reused for another version: ' + package)
    for package, before in previous.get('ios_apps', {}).items():
        after = current.get('ios_apps', {}).get(package)
        if not isinstance(after, dict):
            raise ValueError('Published iOS channel removed: ' + package)
        old_testflight = before.get('testflight', {})
        new_testflight = after.get('testflight', {})
        if str(old_testflight.get('build', '')).isdigit():
            number = str(new_testflight.get('build', ''))
            if not number.isdigit() or int(number) < int(old_testflight['build']):
                raise ValueError('Published iOS build downgrade: ' + package)


def selftest():
    previous = {'apps': {'example': {'latest_version': '0.1.85', 'latest_version_code': 86}}, 'ios_apps': {'example': {'testflight': {'build': '93'}}}}
    validate_progression(previous, copy.deepcopy(previous))
    new = copy.deepcopy(previous)
    new['apps']['example'].update(latest_version='0.1.86', latest_version_code=87)
    validate_progression(previous, new)
    changes = [lambda d: d['apps']['example'].update(latest_version_code=85), lambda d: d['apps'].clear(), lambda d: d['apps']['example'].update(latest_version='0.1.99'), lambda d: d['ios_apps']['example']['testflight'].update(build='92')]
    for change in changes:
        candidate = copy.deepcopy(previous)
        change(candidate)
        try:
            validate_progression(previous, candidate)
        except ValueError:
            continue
        raise AssertionError('Version regression accepted')
    print('PASS unchanged channels, forward release and four rejected regressions')


def read_manifest(revision):
    raw = subprocess.check_output(['git', 'show', revision + ':manifest.json'])
    return json.loads(raw)


def main():
    if '--selftest' in sys.argv:
        selftest()
        return
    for line in sys.stdin:
        local_reference, local_revision, remote_reference, remote_revision = line.split()
        if remote_reference != 'refs/heads/main':
            continue
        if set(local_revision) == {'0'}:
            raise ValueError('Published channel branch deletion blocked')
        if set(remote_revision) == {'0'}:
            continue
        validate_progression(read_manifest(remote_revision), read_manifest(local_revision))
    print('PASS published channel version progression')


if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

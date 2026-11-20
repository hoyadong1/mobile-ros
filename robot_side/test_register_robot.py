import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

import register_robot
from register_robot import enroll

ROBOT = 'r-' + '1' * 36


def reply(code):
    return lambda *a, **k: io.BytesIO(json.dumps({'id': ROBOT, 'token': 'a' * 43, 'code': code}).encode())


class RegistrationTest(unittest.TestCase):
    def test_only_private_agent_token_is_saved_existing_files_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'agent-token'
            calls = []
            def opener(request, timeout):
                calls.append(request)
                return reply('BCDE-FGH2')()
            _, code, _ = enroll('https://relay.example', 'Robot', target, opener)
            self.assertEqual(code, 'BCDE-FGH2')
            self.assertEqual(target.read_text(), 'a'*43)
            self.assertEqual(len(calls), 1)
            with self.assertRaises(ValueError):
                enroll('https://relay.example', 'Robot', target, opener)
            self.assertEqual(target.read_text(), 'a'*43)
            self.assertEqual(len(calls), 1)

    def test_cleartext_relay_and_invalid_response_never_create_a_token_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'agent-token'
            with self.assertRaises(ValueError):
                enroll('http://relay.example', 'Robot', target)
            with self.assertRaises(ValueError):
                enroll('https://relay.example', 'Robot', target,
                    lambda *args, **kwargs: io.BytesIO(b'{"token":"invalid"}'))
            self.assertFalse(target.exists())

    def test_old_or_ambiguous_codes_are_refused(self):
        for code in ['B' * 20, 'BCDE-FGH1', 'BCDEFGH2', 'bcde-fgh2']:
            with tempfile.TemporaryDirectory() as directory, self.subTest(code=code):
                with self.assertRaises(ValueError):
                    enroll('https://relay.example', 'Robot', Path(directory)/'t', reply(code))

    def test_enroll_only_prints_the_code_for_the_installer_and_starts_nothing(self):
        out = io.StringIO()
        argv = ['register_robot.py', '--relay', 'https://relay.example', '--name', 'Robot', '--token-file', '/x/t', '--enroll-only']
        with mock.patch.object(register_robot, 'enroll', return_value=(ROBOT, 'CDEF-GH23', '/x/t')), \
                mock.patch.object(register_robot.os, 'execv') as execv, mock.patch.object(sys, 'argv', argv), \
                contextlib.redirect_stdout(out):
            register_robot.main()
        self.assertEqual(json.loads(out.getvalue()), {'id': ROBOT, 'code': 'CDEF-GH23'})
        execv.assert_not_called()

    def test_the_link_is_built_from_the_relay_and_shown_with_the_code(self):
        out = io.StringIO()
        with mock.patch.object(register_robot.shutil, 'which', return_value=None):
            register_robot.show('https://relay.example/', 'CDEF-GH23', out)
        self.assertIn('https://relay.example/link/CDEF-GH23', out.getvalue())
        self.assertIn('code  CDEF-GH23', out.getvalue())

    def test_waiting_ends_when_added_or_expired_and_the_token_goes_only_in_a_header(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory)/'t'
            token.write_text('a' * 43)
            seen = []
            answers = iter([{'claimed': False}, {'claimed': False}, {'claimed': True}])
            def opener(request, timeout):
                seen.append(request)
                return io.BytesIO(json.dumps(next(answers)).encode())
            self.assertTrue(register_robot.wait_for_owner('https://relay.example', token, opener, sleep=lambda s: None))
            self.assertEqual(len(seen), 3)
            self.assertEqual(seen[0].get_header('Authorization'), 'Bearer ' + 'a' * 43)
            self.assertNotIn('a' * 43, seen[0].full_url)
            def expired(request, timeout):
                raise urllib.error.HTTPError(request.full_url, 410, 'gone', {}, None)
            self.assertFalse(register_robot.wait_for_owner('https://relay.example', token, expired, sleep=lambda s: None))


if __name__ == '__main__':
    unittest.main()

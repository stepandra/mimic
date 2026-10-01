"""Synthetic parser regressions only; these do not qualify Linux enforcement."""
import json
import unittest
from verify import SCHEMA, verify


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.rows = [{key: True for key in keys} for keys in SCHEMA]

    def report(self):
        return ''.join(json.dumps(row) + '\n' for row in self.rows)

    def test_complete(self):
        self.assertTrue(verify(self.report(), 0))

    def test_nonzero_and_signal(self):
        for code in (1, 2, 99, -9, 137):
            self.assertFalse(verify(self.report(), code))

    def test_false_missing_extra_and_nonbool(self):
        for value in (False, 1, 'true', None):
            self.rows[1]['check_exact'] = value
            self.assertFalse(verify(self.report(), 0))
        self.rows[1] = {}
        self.assertFalse(verify(self.report(), 0))
        self.rows[1] = {'check_exact': True, 'invented': True}
        self.assertFalse(verify(self.report(), 0))

    def test_truncated_duplicate_noisy(self):
        good = self.report()
        for text in (good[:-3], good + '{}\n', 'noise\n' + good,
                     good.replace('"check_exact": true',
                                  '"check_exact": true, "check_exact": true'),
                     'x' * 16385):
            self.assertFalse(verify(text, 0))

    def test_missing_descendant_or_fixture(self):
        for index in (0, 3, 4):
            rows = list(self.rows)
            del rows[index]
            self.assertFalse(verify('\n'.join(map(json.dumps, rows)), 0))


if __name__ == '__main__':
    unittest.main()

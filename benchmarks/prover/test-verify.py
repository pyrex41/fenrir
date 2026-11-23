"""The benchmark checker must validate work counts and the selected branch."""
import unittest

from verify import check


class TableauEvidence(unittest.TestCase):
    def test_first_countermodel(self):
        case = ["t model 3 & a b"]
        check(case, ["t model 3 0"])
        # Both assignments falsify the goal, but FIFO traversal returns zero.
        for row in ("t model 3 2", "t model 2 0"):
            with self.subTest(row=row), self.assertRaises(AssertionError):
                check(case, [row])

    def test_fuel_boundary(self):
        for term in ("& a b", "> a a"):
            check(["t exhausted 2 " + term], ["t exhausted 2 -"])
            with self.subTest(term=term), self.assertRaises(AssertionError):
                check(["t exhausted 3 " + term], ["t exhausted 3 -"])
        check(["t proof 3 > a a"], ["t proof 3 ssx"])
        with self.assertRaises(AssertionError):
            check(["t proof 3 > a a"], ["t proof 3 sxx"])


if __name__ == "__main__":
    unittest.main()

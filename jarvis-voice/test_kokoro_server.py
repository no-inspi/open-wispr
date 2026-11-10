import tempfile
import unittest
from pathlib import Path

import kokoro_server as ks


def fake(text, lang):
    return f"<{lang[:2]}:{text}>"


class SplitTests(unittest.TestCase):
    def setUp(self):
        self.pattern = ks.english_pattern(["Git", "pull request", "pull", "issue"])

    def test_keeps_every_character(self):
        text = "Pousse sur git, puis ouvre une pull request."
        parts = ks.split_by_language(text, self.pattern)
        self.assertEqual("".join(p for _, p in parts), text)

    def test_matches_whole_words_ignoring_case(self):
        parts = ks.split_by_language("GIT et gitan", self.pattern)
        self.assertEqual(parts, [("en-us", "GIT"), ("fr-fr", " et gitan")])

    def test_prefers_the_longest_expression(self):
        parts = ks.split_by_language("une pull request", self.pattern)
        self.assertIn(("en-us", "pull request"), parts)

    def test_word_after_an_apostrophe(self):
        parts = ks.split_by_language("l'issue", self.pattern)
        self.assertEqual(parts, [("fr-fr", "l'"), ("en-us", "issue")])

    def test_accented_letters_are_part_of_words(self):
        pattern = ks.english_pattern(["merge"])
        self.assertEqual(ks.split_by_language("mergé", pattern), [("fr-fr", "mergé")])

    def test_without_words_everything_is_french(self):
        self.assertEqual(ks.split_by_language("Bonjour", None), [("fr-fr", "Bonjour")])


class PhonemizeTests(unittest.TestCase):
    def test_keeps_spaces_around_english_words(self):
        pattern = ks.english_pattern(["Git"])
        self.assertEqual(ks.phonemize("sur Git, puis", pattern, fake), "<fr:sur> <en:Git><fr:, puis>")
        self.assertEqual(ks.phonemize("le Git du projet", pattern, fake), "<fr:le> <en:Git> <fr:du projet>")


class WordsFileTests(unittest.TestCase):
    def test_ignores_comments_and_blank_lines(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "words.txt"
            path.write_text("# titre\nGit\n\n  Vault  # coffre\n", encoding="utf-8")
            self.assertEqual(ks.read_words(path), ["Git", "Vault"])

    def test_default_list_is_readable(self):
        words = ks.read_words(Path(__file__).with_name("english-words.txt"))
        self.assertIn("Git", words)
        self.assertIn("Vault", words)


if __name__ == "__main__":
    unittest.main()

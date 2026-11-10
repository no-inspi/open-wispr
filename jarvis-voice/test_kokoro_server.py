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


    def test_forced_pronunciation_replaces_english(self):
        words = {"tendr": "tɛndøʁ", "git": None}
        pattern = ks.english_pattern(words)
        self.assertEqual(ks.phonemize("sur TENDR et Git", pattern, fake, words),
                         "<fr:sur> tɛndøʁ <fr:et> <en:Git>")


class WordsFileTests(unittest.TestCase):
    def test_ignores_comments_and_blank_lines(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "words.txt"
            path.write_text("# titre\nGit\n\n  Vault  # coffre\nTendr = tɛndøʁ\n", encoding="utf-8")
            self.assertEqual(ks.read_words(path), {"git": None, "vault": None, "tendr": "tɛndøʁ"})

    def test_default_list_is_readable(self):
        words = ks.read_words(Path(__file__).with_name("english-words.txt"))
        self.assertIn("git", words)
        self.assertEqual(words["tendr"], "tɛndøʁ")


class LearningTests(unittest.TestCase):
    def test_most_frequent_transcription_wins(self):
        self.assertEqual(ks.choose_phonemes(["tɛndør", "tɛndøʁ", "tɛndør"]), "tɛndør")

    def test_tie_goes_to_the_closest_to_the_others(self):
        self.assertEqual(ks.choose_phonemes(["tɛndøʁ", "tɛndyʁ", "a"]), "tɛndøʁ")

    def test_same_length_takes_vote_sound_by_sound(self):
        self.assertEqual(ks.choose_phonemes(["tʌndər", "tɛndəʁ", "tɛndør"]), "tɛndər")

    def test_empty_takes_give_nothing(self):
        self.assertIsNone(ks.choose_phonemes(["", ""]))

    def test_edit_distance(self):
        self.assertEqual(ks.edit_distance("tɛndøʁ", "tɛndyʁ"), 1)
        self.assertEqual(ks.edit_distance("", "abc"), 3)

    def test_set_word_replaces_the_line_ignoring_case(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "words.txt"
            path.write_text("# titre\nGit\ntendr = tˈɛndœʁ  # ancien\n", encoding="utf-8")
            ks.set_word(path, "Tendr", "tɛndøʁ")
            self.assertEqual(path.read_text(encoding="utf-8"), "# titre\nGit\nTendr = tɛndøʁ\n")

    def test_set_word_appends_a_new_word(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "words.txt"
            path.write_text("Git\n", encoding="utf-8")
            ks.set_word(path, "Cyrus", "sˈaɪɹəs")
            self.assertEqual(ks.read_words(path), {"git": None, "cyrus": "sˈaɪɹəs"})

    def test_trim_silence_keeps_the_word(self):
        import numpy as np
        audio = np.zeros(16000, dtype="float32")
        audio[8000:9600] = 0.5
        trimmed = ks.trim_silence(audio, 16000)
        self.assertEqual(len(trimmed), 1600 + 2 * 1600)


if __name__ == "__main__":
    unittest.main()

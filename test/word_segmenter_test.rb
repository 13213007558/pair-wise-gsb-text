require_relative "./test_helper"
require "text/word_segmenter"

class WordSegmenterTest < Test::Unit::TestCase
  def test_finds_optimal_segmentation_and_returns_original_ranges
    dictionary = {
      "at" => 1,
      "lash" => 1,
      "tray" => 1
    }
    result = Text::WordSegmenter.new(dictionary).segment("AtLASHtray")

    assert_equal ["At", "LASH", "tray"], result.words
    assert_equal [0...2, 2...6, 6...10], result.ranges
    assert result.ranges.all? { |range| !"AtLASHtray"[range].nil? }
    assert_equal "AtLASHtray", result.words.join
    assert_in_delta(-3 * Math.log(1.0 / 3), result.score, 1e-12)
  end

  def test_dynamic_programming_beats_longest_prefix_and_matches_exhaustive_search
    string = "atlashtray"
    dictionary = {
      "at" => 1,
      "atlas" => 1,
      "lash" => 1,
      "tray" => 1
    }
    result = Text::WordSegmenter.new(dictionary).segment(string)

    assert_equal ["at", "lash", "tray"], result.words
    assert_not_equal ["atlas", "h", "tray"], result.words
    assert_equal exhaustive_best(string, dictionary), [result.words, result.score.round(12)]
  end

  def test_bigram_frequency_can_change_the_best_path
    dictionary = {
      "a" => 1000,
      "agent" => 1001,
      "gentleman" => 1000,
      "leman" => 1001
    }

    without_bigrams = Text::WordSegmenter.new(dictionary).segment("agentleman")
    with_bigrams = Text::WordSegmenter.new(
      dictionary,
      { ["a", "gentleman"] => 1 }
    ).segment("agentleman")

    assert_equal ["agent", "leman"], without_bigrams.words
    assert_equal ["a", "gentleman"], with_bigrams.words
    assert with_bigrams.score < without_bigrams.score
  end

  def test_unicode_normalization_is_used_only_for_lookup
    segmenter = Text::WordSegmenter.new(
      { "fish" => 1 },
      nil,
      normalization: :case_and_unicode
    )
    result = segmenter.segment("ﬁsh")

    assert_equal ["ﬁsh"], result.words
    assert_equal [0...3], result.ranges
    assert_equal "ﬁsh", result.words.join
  end

  def test_caller_declared_boundaries_are_never_crossed
    dictionary = {
      "a1,b" => 100,
      "a" => 1,
      "1" => 1,
      "," => 1,
      "b" => 1
    }
    boundary = lambda { |character| character =~ /\d|\p{Punctuation}/ }
    result = Text::WordSegmenter.new(
      dictionary,
      nil,
      hard_boundaries: boundary
    ).segment("a1,b")

    assert_equal ["a", "1", ",", "b"], result.words
    assert_equal [0...1, 1...2, 2...3, 3...4], result.ranges
  end

  def test_unknown_run_before_a_hard_boundary_is_not_the_whole_sentence
    result = Text::WordSegmenter.new(
      { "z" => 1 },
      nil,
      hard_boundaries: "!"
    ).segment("ab!")

    assert_equal ["ab", "!"], result.words
    assert_equal [0...2, 2...3], result.ranges
    assert_equal 18.0, result.score
  end

  def test_unknown_words_have_a_maximum_length_and_cannot_cover_the_whole_sentence
    result = Text::WordSegmenter.new(
      { "z" => 1 },
      nil,
      unknown_cost: 6,
      unknown_per_char_cost: 2,
      max_unknown_length: 4
    ).segment("abcdefgh")

    assert_equal ["abcd", "efgh"], result.words
    assert result.tokens.none?(&:known)
    assert_equal 28.0, result.score
  end

  def test_equal_scoring_segmentations_use_a_deterministic_lexical_rule
    result = Text::WordSegmenter.new(
      { "z" => 1 },
      nil,
      max_unknown_length: 4
    ).segment("abcdef")

    assert_equal ["ab", "cdef"], result.words
    assert_equal 24.0, result.score
  end

  private

  def exhaustive_best(string, dictionary)
    total = dictionary.values.inject(0, :+).to_f
    partitions = [[]]

    (string.length - 1).times do |position|
      boundary = position + 1
      partitions.concat(partitions.map { |parts| parts + [boundary] })
    end

    candidates = partitions.map do |boundaries|
      starts = [0] + boundaries + [string.length]
      parts = starts.each_cons(2).map { |start, finish| string[start...finish] }
      valid = parts.all? do |part|
        dictionary.key?(part) || part.length <= 4
      end
      next unless valid

      score = parts.inject(0.0) do |total_score, part|
        if dictionary.key?(part)
          total_score - Math.log(dictionary[part].to_f / total)
        else
          total_score + 6.0 + (2.0 * part.length)
        end
      end
      [parts, score.round(12)]
    end

    candidates.compact.min_by { |parts, score| [score, parts] }
  end
end

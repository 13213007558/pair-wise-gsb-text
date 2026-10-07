# encoding: utf-8

require_relative "./test_helper"
require 'text/word_segmenter'

class WordSegmenterTest < Test::Unit::TestCase
  def test_finds_better_path_than_longest_prefix_greedy
    words = {
      "cat" => 50,
      "sand" => 50,
      "dogs" => 50,
      "cats" => 2,
      "and" => 2
    }
    segmenter = Text::WordSegmenter.new(words)
    result = segmenter.segment("catsanddogs")

    assert_equal ["cat", "sand", "dogs"], result.words
    assert_equal ["cats", "and", "dogs"],
      greedy_words(words, "catsanddogs")
  end

  def test_matches_exhaustive_boundary_enumeration
    examples = [
      [
        "catsanddogs",
        {
          "cat" => 50,
          "sand" => 50,
          "dogs" => 50,
          "cats" => 2,
          "and" => 2
        },
        nil
      ],
      [
        "atruetest",
        {
          "a" => 50,
          "true" => 50,
          "test" => 50,
          "at" => 2,
          "rue" => 2
        },
        nil
      ],
      [
        "newyork",
        {
          "new" => 20,
          "york" => 20,
          "newyork" => 2,
          "ork" => 2
        },
        {
          ["new", "york"] => 20
        }
      ]
    ]

    examples.each do |string, word_counts, bigram_counts|
      segmenter = Text::WordSegmenter.new(
        word_counts,
        bigram_counts: bigram_counts
      )
      result = segmenter.segment(string)
      exhaustive = exhaustive_best(
        string,
        word_counts,
        bigram_counts,
        segmenter
      )

      assert_equal 2 ** (string.length - 1),
        exhaustive[:partition_count],
        string
      assert_equal exhaustive[:words], result.words, string
      assert_in_delta exhaustive[:cost], result.cost, 1e-12, string
    end
  end

  def test_tokens_return_original_character_and_byte_ranges
    segmenter = Text::WordSegmenter.new(
      { "i" => 1, "love" => 1, "ruby" => 1 },
      case_normalization: :downcase
    )
    result = segmenter.segment("ILoveRuby")

    assert_equal ["I", "Love", "Ruby"], result.words
    assert_equal [[0, 1], [1, 5], [5, 9]],
      result.tokens.map { |token| [token.start_char, token.end_char] }
    assert_equal [[0, 1], [1, 5], [5, 9]],
      result.tokens.map { |token| [token.start_byte, token.end_byte] }
    assert_equal "ILoveRuby",
      result.tokens.map { |token|
        "ILoveRuby"[token.start_byte...token.end_byte]
      }.join
    assert result.tokens.all?(&:known?)
    assert_in_delta result.score, -result.cost, 1e-12
  end

  def test_unicode_normalization_does_not_change_original_ranges
    normalized_word = "Caf\u00e9"
    original_word = normalized_word.unicode_normalize(:nfd)
    segmenter = Text::WordSegmenter.new(
      { normalized_word => 1 },
      unicode_normalization: :nfc
    )

    result = segmenter.segment(original_word)

    assert_equal [original_word], result.words
    assert_equal [[0, 5]],
      result.tokens.map { |token| [token.start_char, token.end_char] }
    assert_equal [[0, 6]],
      result.tokens.map { |token| [token.start_byte, token.end_byte] }
    assert_equal original_word,
      original_word[
        result.tokens.first.start_byte...result.tokens.first.end_byte
      ]
    assert result.tokens.first.known?
  end

  def test_caller_declared_character_boundaries_are_hard
    segmenter = Text::WordSegmenter.new(
      { "cat" => 1, "dog" => 1 },
      case_normalization: :downcase
    )
    boundary_classifier = method(:digit_or_punctuation?)
    result = segmenter.segment("cat1dog", hard_boundaries: boundary_classifier)

    assert_equal ["cat", "1", "dog"], result.words
    assert_equal [true, false, true],
      result.tokens.map(&:known?)
    assert_equal [3, 4, 7],
      result.tokens.map(&:end_char)
  end

  def test_caller_can_declare_forced_boundary_positions
    segmenter = Text::WordSegmenter.new(
      { "cat" => 1, "cats" => 1, "sand" => 1 }
    )

    result = segmenter.segment("catsand", hard_boundaries: [3])

    assert_equal ["cat", "sand"], result.words
  end

  def test_unknown_pieces_are_limited_and_cannot_cover_the_whole_sentence
    segmenter = Text::WordSegmenter.new(
      {},
      max_unknown_length: 2,
      unknown_base_penalty: 2.0,
      unknown_per_char_penalty: 1.0
    )
    result = segmenter.segment("abcdef")

    assert_equal ["ab", "cd", "ef"], result.words
    assert result.tokens.none?(&:known?)
    assert_equal 12.0, result.cost
  end

  def test_known_word_is_allowed_to_span_the_whole_sentence
    segmenter = Text::WordSegmenter.new(
      { "abcdef" => 1 },
      max_unknown_length: 2
    )

    assert_equal ["abcdef"], segmenter.segment("abcdef").words
  end

  def test_equivalent_best_segmentations_are_deterministic
    words = {
      "ab" => 1,
      "cde" => 1,
      "abc" => 1,
      "de" => 1
    }
    segmenter = Text::WordSegmenter.new(words)
    results = Array.new(10) { segmenter.segment("abcde").words }

    assert_equal [["abc", "de"]], results.uniq
  end

  private

  def digit_or_punctuation?(character)
    !!(character =~ /\A[\d\p{P}]\z/)
  end

  def greedy_words(word_counts, string)
    words = []
    position = 0

    while position < string.length
      known = word_counts.keys.select do |word|
        string[position, word.length] == word
      end
      word = known.max_by(&:length)
      flunk "missing greedy word at #{position}" if word.nil?
      words << word
      position += word.length
    end

    words
  end

  def exhaustive_best(string, raw_word_counts, raw_bigram_counts, segmenter)
    word_counts = Hash[
      raw_word_counts.map { |word, count| [word.downcase, Float(count)] }
    ]
    bigram_counts = Hash[
      Array(raw_bigram_counts).map do |(first, second), count|
        [[first.downcase, second.downcase], Float(count)]
      end
    ]
    total = word_counts.values.inject(0.0, :+)
    vocabulary_size = word_counts.length
    alpha = 0.1
    candidates = []

    boundary_sets(string.length).each do |boundaries|
      words = words_at_boundaries(string, boundaries)
      keys = words.map(&:downcase)
      known = keys.map { |key| word_counts.key?(key) }
      next unless words.all? { |word| word.length <= 3 || word_counts.key?(word.downcase) }

      cost = keys.each_with_index.inject(0.0) do |sum, (key, index)|
        if known[index]
          denominator = total + alpha * (vocabulary_size + 1)
          sum += -Math.log((word_counts.fetch(key) + alpha) / denominator)
        else
          sum += 4.0 + key.length
        end

        if index > 0 && !raw_bigram_counts.nil?
          if known[index] && known[index - 1]
            pair_count = bigram_counts.fetch([keys[index - 1], key], 0.0)
            previous_count = word_counts.fetch(keys[index - 1])
            transition_denominator =
              previous_count + alpha * (vocabulary_size + 1)
            sum += -Math.log(
              (alpha + pair_count) / transition_denominator
            )
          else
            sum += -Math.log(alpha / (alpha * (vocabulary_size + 1)))
          end
        end

        sum
      end

      candidates << {
        words: words,
        cost: cost,
        boundaries: boundaries,
        unknown_count: known.count(false)
      }
    end

    best = candidates.min_by do |candidate|
      [
        candidate[:cost],
        candidate[:unknown_count],
        candidate[:words].length,
        candidate[:boundaries].reverse.map { |boundary| -boundary }
      ]
    end

    best.merge(partition_count: boundary_sets(string.length).length)
  end

  def boundary_sets(length)
    @boundary_sets ||= {}
    positions = (1...length).to_a
    @boundary_sets[length] ||= (0...length).flat_map do |size|
      positions.combination(size).to_a
    end
  end

  def words_at_boundaries(string, boundaries)
    positions = [0, boundaries, string.length].flatten
    positions.each_cons(2).map do |start_position, end_position|
      string[start_position...end_position]
    end
  end
end

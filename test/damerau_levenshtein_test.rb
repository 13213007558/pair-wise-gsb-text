# coding: UTF-8

require_relative "./test_helper"
require "text/damerau_levenshtein"
require "text/levenshtein"

class DamerauLevenshteinTest < Test::Unit::TestCase
  include Text::DamerauLevenshtein

  def iso_8859_1(s)
    s.force_encoding(Encoding::ISO_8859_1)
  end

  def test_should_calculate_distances_for_basic_examples
    assert_equal 0, distance("test", "test")
    assert_equal 1, distance("test", "tent")
    assert_equal 2, distance("gumbo", "gambol")
    assert_equal 3, distance("kitten", "sitting")
  end

  def test_should_count_adjacent_transposition_as_one_edit
    assert_equal 1, distance("ab", "ba")
    assert_equal 1, distance("test", "tset")
    assert_equal 1, distance("abcdef", "abdcef")
  end

  # The unrestricted algorithm may edit a substring more than once, so
  # "CA" -> "ABC" costs 2 (transpose, then insert between the transposed
  # characters). The restricted optimal string alignment variant cannot
  # do this and reports 3.
  def test_should_distinguish_full_algorithm_from_optimal_string_alignment
    assert_equal 3, osa_distance("CA", "ABC")
    assert_equal 2, distance("CA", "ABC")
  end

  def test_should_give_full_distances_for_empty_strings
    assert_equal 0, distance("", "")
    assert_equal 3, distance("", "foo")
    assert_equal 3, distance("foo", "")
    assert_equal 1, distance("a", "")
  end

  def test_should_treat_utf_8_codepoints_as_one_element
    assert_equal 1, distance("föo", "foo")
    assert_equal 1, distance("français", "francais")
    assert_equal 1, distance("私の", "の私")
    assert_equal 2, distance("私の名前はポールです", "ぼくの名前はポールです")
  end

  def test_should_process_single_byte_encodings
    assert_equal 1, distance(iso_8859_1("f\xF6o"), iso_8859_1("foo"))
    assert_equal 1, distance(iso_8859_1("fran\xE7ais"), iso_8859_1("francais"))
    assert_equal 1, distance(iso_8859_1("fran\xE7ais"), iso_8859_1("fran\xE6ais"))
  end

  def test_should_handle_invalid_encoding_like_the_levenshtein_module
    invalid = "a\xFFb".dup.force_encoding(Encoding::UTF_8)
    assert_raise(ArgumentError) { Text::Levenshtein.distance(invalid, "ab") }
    assert_raise(ArgumentError) { distance(invalid, "ab") }
    assert_raise(ArgumentError) { edit_sequence(invalid, "ab") }

    binary = "\xF6".dup.force_encoding(Encoding::ASCII_8BIT)
    assert_raise(Encoding::UndefinedConversionError) { Text::Levenshtein.distance(binary, "o") }
    assert_raise(Encoding::UndefinedConversionError) { distance(binary, "o") }
  end

  def test_should_return_calculated_distance_when_within_maximum
    assert_equal 0, distance("test", "test", 0)
    assert_equal 1, distance("ab", "ba", 1)
    assert_equal 2, distance("CA", "ABC", 2)
    assert_equal 3, distance("kitten", "sitting", 3)
    assert_equal 3, distance("kitten", "sitting", 10)
    assert_equal 3, distance("", "cat", 3)
    assert_equal 3, distance("cat", "", 5)
  end

  def test_should_return_interval_status_when_maximum_is_exceeded
    result = distance("kitten", "sitting", 2)
    assert_kind_of Range, result
    assert_equal 3, result.begin
    assert result.cover?(3), "interval should cover the true distance"

    assert_equal (1..2), distance("ab", "ba", 0)
    assert_equal (3..5), distance("", "abcde", 2)
    assert_equal (1..1), distance("a", "b", 0)
  end

  def test_should_not_return_a_truncated_value_as_if_it_were_the_distance
    # The true distance is 3; a truncated result would wrongly claim 2.
    assert_not_equal 2, distance("kitten", "sitting", 2)
    assert_not_equal 2, distance("kitten", "sitting", 2).to_i if distance("kitten", "sitting", 2).is_a?(Integer)
  end

  def test_should_reject_invalid_maximum
    assert_raise(ArgumentError) { distance("a", "b", -1) }
    assert_raise(ArgumentError) { distance("a", "b", 1.5) }
  end

  def test_should_return_replayable_edit_sequence
    operations = edit_sequence("CA", "ABC")
    assert_equal [[:transpose, 0, "C", "A"], [:insert, 1, "B"]], operations
    assert_equal "ABC", apply("CA", operations)
    assert_equal distance("CA", "ABC"), operations.length
  end

  def test_should_return_empty_edit_sequence_for_equal_strings
    assert_equal [], edit_sequence("test", "test")
    assert_equal [], edit_sequence("", "")
  end

  def test_should_build_and_replay_edit_sequences
    assert_equal "sitting", apply("kitten", edit_sequence("kitten", "sitting"))
    assert_equal "gambol", apply("gumbo", edit_sequence("gumbo", "gambol"))
    assert_equal "abc", apply("", edit_sequence("", "abc"))
    assert_equal "", apply("abc", edit_sequence("abc", ""))
    assert_equal "ba", apply("ab", edit_sequence("ab", "ba"))
  end

  def test_should_choose_edit_sequence_deterministically_when_several_are_optimal
    # "aa" -> "a" can delete either "a"; the stable choice is fixed.
    assert_equal [[:delete, 0, "a"]], edit_sequence("aa", "a")
    assert_equal edit_sequence("aaba", "abaa"), edit_sequence("aaba", "abaa")
    first, second = edit_sequence("abab", "baba"), edit_sequence("abab", "baba")
    assert_equal first, second
    assert_equal "baba", apply("abab", first)
  end

  def test_should_raise_on_unknown_operation_when_applying
    assert_raise(ArgumentError) { apply("ab", [[:dance, 0, "a"]]) }
  end

  private

  # The restricted optimal string alignment distance, in which no substring
  # is edited more than once.
  def osa_distance(source, target)
    s = source.chars
    t = target.chars
    n = s.length
    m = t.length
    d = (0..n).map { |i| [i] + [0] * m }
    (0..m).each { |j| d[0][j] = j }
    (1..n).each do |i|
      (1..m).each do |j|
        cost = s[i - 1] == t[j - 1] ? 0 : 1
        d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
        if i > 1 && j > 1 && s[i - 1] == t[j - 2] && s[i - 2] == t[j - 1]
          d[i][j] = [d[i][j], d[i - 2][j - 2] + 1].min
        end
      end
    end
    d[n][m]
  end
end

class DamerauLevenshteinExhaustiveTest < Test::Unit::TestCase
  ALPHABET = %w[a b].freeze
  MAX_LENGTH = 4

  def all_strings
    strings = [""]
    (1..MAX_LENGTH).each do |length|
      strings.concat(ALPHABET.repeated_permutation(length).map(&:join))
    end
    strings
  end

  # A shortest edit path between strings of at most MAX_LENGTH characters
  # costs at most MAX_LENGTH edits, so no string on such a path can be
  # longer than 2 * MAX_LENGTH; longer strings are never generated.
  SEARCH_LENGTH_BOUND = 2 * MAX_LENGTH

  def each_variant(str)
    chars = str.chars
    chars.each_index do |i|
      yield (chars[0...i] + chars[(i + 1)..-1]).join # deletion
      ALPHABET.each do |char|
        next if char == chars[i]
        copy = chars.dup
        copy[i] = char
        yield copy.join # substitution
      end
    end
    if chars.length < SEARCH_LENGTH_BOUND
      (0..chars.length).each do |i|
        ALPHABET.each do |char|
          yield (chars[0...i] + [char] + chars[i..-1]).join # insertion
        end
      end
    end
    (0...(chars.length - 1)).each do |i|
      copy = chars.dup
      copy[i], copy[i + 1] = copy[i + 1], copy[i]
      yield copy.join # adjacent transposition
    end
  end

  # Ground truth: breadth-first search over single edits always finds the
  # unrestricted Damerau-Levenshtein distance.
  def brute_force_distances_from(source)
    distances = { source => 0 }
    queue = [source]
    until queue.empty?
      current = queue.shift
      each_variant(current) do |variant|
        next if distances.key?(variant)
        distances[variant] = distances[current] + 1
        queue << variant
      end
    end
    distances
  end

  def test_should_match_exhaustive_search_on_a_small_alphabet
    strings = all_strings
    strings.each do |source|
      expected = brute_force_distances_from(source)
      strings.each do |target|
        distance = Text::DamerauLevenshtein.distance(source, target)
        assert_equal expected[target], distance,
          "distance(#{source.inspect}, #{target.inspect})"

        operations = Text::DamerauLevenshtein.edit_sequence(source, target)
        assert_equal distance, operations.length,
          "operation count for #{source.inspect} -> #{target.inspect}"
        assert_equal target, Text::DamerauLevenshtein.apply(source, operations),
          "replaying #{source.inspect} -> #{target.inspect}"

        assert_equal distance, Text::DamerauLevenshtein.distance(source, target, distance)
        if distance > 0
          interval = Text::DamerauLevenshtein.distance(source, target, distance - 1)
          assert_kind_of Range, interval
          assert interval.cover?(distance),
            "interval #{interval} should cover true distance #{distance}"
        end
      end
    end
  end
end

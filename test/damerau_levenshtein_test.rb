# coding: UTF-8

require_relative "./test_helper"
require "text/damerau_levenshtein"
require "text/levenshtein"

class DamerauLevenshteinTest < Test::Unit::TestCase
  include Text::DamerauLevenshtein

  def iso_8859_1(s)
    s.force_encoding(Encoding::ISO_8859_1)
  end

  def test_should_calculate_lengths_for_basic_examples
    assert_equal 0, distance("test", "test")
    assert_equal 1, distance("test", "tent")
    assert_equal 2, distance("gumbo", "gambol")
    assert_equal 3, distance("kitten", "sitting")
  end

  def test_should_count_adjacent_transposition_as_one_edit
    assert_equal 1, distance("ab", "ba")
    assert_equal 1, distance("abcd", "abdc")
    assert_equal 1, distance("a cat", "a act")
  end

  def test_should_allow_editing_a_substring_more_than_once
    # The full Damerau-Levenshtein distance: transpose "CA" into "AC", then
    # insert "B". The restricted (OSA) variant would report 3 here.
    assert_equal 2, distance("CA", "ABC")
    assert_equal 2, distance("ABC", "CA")
    assert_equal 2, distance("CA", "ACB")
  end

  def test_should_give_full_distances_for_empty_strings
    assert_equal 0, distance("", "")
    assert_equal 3, distance("", "foo")
    assert_equal 3, distance("foo", "")
  end

  def test_should_treat_utf_8_codepoints_as_one_element
    assert_equal 1, distance("föo", "foo")
    assert_equal 1, distance("öf", "fö")
    assert_equal 1, distance("私の", "の私")
    assert_equal 2, distance("私の名前はポールです", "ぼくの名前はポールです")
  end

  def test_should_process_single_byte_encodings
    assert_equal 1, distance(iso_8859_1("f\xF6o"), iso_8859_1("foo"))
    assert_equal 1, distance(iso_8859_1("\xF6\xE6"), iso_8859_1("\xE6\xF6"))
  end

  def test_should_raise_for_invalid_encoding_like_levenshtein
    invalid = "f\xF6o".dup.force_encoding(Encoding::UTF_8)
    assert_raise(ArgumentError) { distance(invalid, "foo") }
    assert_raise(ArgumentError) { Text::Levenshtein.distance(invalid, "foo") }
  end

  def test_should_raise_for_undefined_conversion_like_levenshtein
    binary = "\xF6".b
    assert_raise(Encoding::UndefinedConversionError) { distance(binary, "foo") }
    assert_raise(Encoding::UndefinedConversionError) {
      Text::Levenshtein.distance(binary, "foo")
    }
  end

  def test_should_return_calculated_distance_when_not_more_than_maximum
    assert_equal 0, distance("test", "test", 0)
    assert_equal 1, distance("test", "tent", 1)
    assert_equal 2, distance("CA", "ABC", 2)
    assert_equal 2, distance("CA", "ABC", 5)
    assert_equal 3, distance("kitten", "sitting", 3)
    assert_equal 3, distance("", "cat", 3)
    assert_equal 3, distance("cat", "", 4)
  end

  def test_should_return_limit_status_when_distance_exceeds_maximum
    result = distance("kitten", "sitting", 2)
    assert_kind_of Text::DamerauLevenshtein::LimitExceeded, result
    refute_kind_of Integer, result
    assert result.exceeded?
    assert_equal 2, result.max_distance
    assert_equal (3..7), result.range
  end

  def test_should_return_limit_status_without_computing_when_lengths_differ_too_much
    result = distance("", "abcdef", 3)
    assert_kind_of Text::DamerauLevenshtein::LimitExceeded, result
    assert_equal (4..6), result.range
  end

  def test_should_report_interval_containing_true_distance
    [["gumbo", "gambol", 1], ["CA", "ABC", 1], ["", "kitten", 2]].each do |a, b, max|
      result = distance(a, b, max)
      assert_kind_of Text::DamerauLevenshtein::LimitExceeded, result
      assert result.range.cover?(distance(a, b)),
        "expected #{result.range} to cover #{distance(a, b)}"
    end
  end

  def test_edit_sequence_should_distinguish_full_algorithm_from_osa
    seq = edit_sequence("CA", "ABC")
    assert_equal 2, seq.distance
    assert_equal [:transpose, :insert], seq.operations.map(&:type)
    assert_equal "ABC", seq.apply
  end

  def test_edit_sequence_should_replay_to_target
    seq = edit_sequence("kitten", "sitting")
    assert_equal 3, seq.distance
    assert_equal distance("kitten", "sitting"), seq.distance
    assert_equal "sitting", seq.apply
  end

  def test_edit_sequence_should_handle_empty_strings
    assert_equal [], edit_sequence("", "").operations
    assert_equal "abc", edit_sequence("", "abc").apply
    assert_equal "", edit_sequence("abc", "").apply
    assert_equal 3, edit_sequence("abc", "").distance
  end

  def test_edit_sequence_should_replay_on_explicit_string
    seq = edit_sequence("ab", "ba")
    assert_equal "ba", seq.apply("ab")
  end

  def test_edit_sequence_should_prefer_transpose_over_two_substitutions
    seq = edit_sequence("ab", "ba")
    assert_equal 1, seq.distance
    assert_equal :transpose, seq.operations.first.type
  end

  def test_edit_sequence_should_be_deterministic
    assert_equal edit_sequence("abba", "baab").operations,
                 edit_sequence("abba", "baab").operations
  end

  def test_edit_sequence_should_replay_unicode
    seq = edit_sequence("föo", "oöf")
    assert_equal "oöf", seq.apply
    assert_equal 2, seq.distance
  end
end

class DamerauLevenshteinExhaustiveTest < Test::Unit::TestCase
  ALPHABET = %w[a b].freeze
  MAX_LENGTH = 5

  def all_strings
    @all_strings ||= (0..MAX_LENGTH).flat_map { |len|
      ALPHABET.repeated_permutation(len).map(&:join)
    }
  end

  def neighbours(str)
    chars = str.chars
    result = []
    chars.each_index do |i|
      result << (chars[0...i] + chars[(i + 1)..-1]).join
    end
    (0..chars.length).each do |i|
      ALPHABET.each do |c|
        result << (chars[0...i] + [c] + chars[i..-1]).join
      end
    end
    chars.each_index do |i|
      ALPHABET.each do |c|
        next if c == chars[i]
        result << (chars[0...i] + [c] + chars[(i + 1)..-1]).join
      end
    end
    (0...(chars.length - 1)).each do |i|
      next if chars[i] == chars[i + 1]
      copy = chars.dup
      copy[i], copy[i + 1] = copy[i + 1], copy[i]
      result << copy.join
    end
    result
  end

  # Breadth-first search over unit-cost edits: the ground truth for the full
  # Damerau-Levenshtein distance.
  def brute_force_distance(a, b)
    return 0 if a == b
    visited = { a => 0 }
    queue = [a]
    until queue.empty?
      current = queue.shift
      d = visited[current]
      neighbours(current).each do |nxt|
        next if visited.key?(nxt)
        return d + 1 if nxt == b
        visited[nxt] = d + 1
        queue << nxt
      end
    end
    raise "unreachable"
  end

  def test_exhaustive_distances_on_small_alphabet
    all_strings.each do |a|
      all_strings.each do |b|
        assert_equal brute_force_distance(a, b),
          Text::DamerauLevenshtein.distance(a, b),
          "distance(#{a.inspect}, #{b.inspect})"
      end
    end
  end

  def test_exhaustive_edit_sequence_replay_on_small_alphabet
    all_strings.each do |a|
      all_strings.each do |b|
        seq = Text::DamerauLevenshtein.edit_sequence(a, b)
        assert_equal b, seq.apply, "replay #{a.inspect} -> #{b.inspect}"
        assert_equal seq.operations.length, seq.distance
        assert_equal brute_force_distance(a, b), seq.distance,
          "cost of edit sequence #{a.inspect} -> #{b.inspect}"
      end
    end
  end

  def test_exhaustive_limit_status_on_small_alphabet
    all_strings.each do |a|
      all_strings.each do |b|
        true_distance = Text::DamerauLevenshtein.distance(a, b)
        (0..true_distance).each do |max|
          result = Text::DamerauLevenshtein.distance(a, b, max)
          if max >= true_distance
            assert_equal true_distance, result
          else
            assert_kind_of Text::DamerauLevenshtein::LimitExceeded, result
            assert result.range.cover?(true_distance)
          end
        end
      end
    end
  end
end

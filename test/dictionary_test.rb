# coding: UTF-8

require_relative "./test_helper"
require "text/levenshtein/dictionary"
require "json"
require "set"

class DictionaryTest < Test::Unit::TestCase
  WORDS = %w[
    cat cats cattle bat bats battle dog dogs catalog catch car cart coat
    rate rat ratify later date data datum cut cute cup cap cape camp
  ].freeze

  def naive_candidates(words, query, max_distance, priority = nil)
    words.each_with_index.map do |word, ordinal|
      value = priority_for(priority, word, ordinal)
      {
        word: word,
        ordinal: ordinal,
        distance: Text::Levenshtein.distance(query, word),
        priority: value
      }
    end.select do |match|
      match[:distance] <= max_distance
    end.sort do |left, right|
      compare(left, right)
    end.map { |match| match[:word] }
  end

  def priority_for(priority, word, ordinal)
    if priority.respond_to?(:call)
      priority.call(word)
    elsif priority
      priority[word] || 1000
    else
      ordinal
    end
  end

  def compare(left, right)
    comparison = left[:distance] <=> right[:distance]
    return comparison unless comparison.zero?

    comparison = left[:priority] <=> right[:priority]
    comparison.zero? ? left[:ordinal] <=> right[:ordinal] : comparison
  end

  def test_threshold_search_matches_naive_scan
    dictionary = Text::Levenshtein::Dictionary.new(WORDS)

    %w[cat cats bat dog dat cup cap xyz].each do |query|
      0.upto(3) do |max_distance|
        assert_equal naive_candidates(WORDS, query, max_distance),
          dictionary.candidates(query, max_distance: max_distance),
          "#{query.inspect} within #{max_distance}"
      end
    end
  end

  def test_top_k_matches_naive_scan
    dictionary = Text::Levenshtein::Dictionary.new(WORDS)

    %w[cat cats bat dog dat cup cap xyz].each do |query|
      1.upto(6) do |k|
        expected = WORDS.each_with_index
          .map { |word, ordinal| [Text::Levenshtein.distance(query, word), ordinal, word] }
          .sort.first(k).map(&:last)
        assert_equal expected, dictionary.top_k(query, k)
      end
    end
  end

  def test_randomized_searches_match_naive_scan
    rng = Random.new(271828)
    alphabet = ("a".."f").to_a
    words = Array.new(140) do
      length = rng.rand(1..6)
      Array.new(length) { alphabet.sample(random: rng) }.join
    end.uniq
    dictionary = Text::Levenshtein::Dictionary.new(words)

    80.times do
      query = Array.new(rng.rand(0..7)) { alphabet.sample(random: rng) }.join
      0.upto(2) do |max_distance|
        expected = words.each_with_index
          .map { |word, ordinal| [Text::Levenshtein.distance(query, word), ordinal, word] }
          .select { |distance, _, _| distance <= max_distance }
          .sort.map(&:last)
        assert_equal expected, dictionary.candidates(query, max_distance: max_distance)
      end

      1.upto(5) do |k|
        expected = words.each_with_index
          .map { |word, ordinal| [Text::Levenshtein.distance(query, word), ordinal, word] }
          .sort.first(k).map(&:last)
        assert_equal expected, dictionary.top_k(query, k)
      end
    end
  end

  def test_terminal_just_beyond_query_length_is_not_pruned
    dictionary = Text::Levenshtein::Dictionary.new(%w[abcd])

    assert_equal ["abcd"], dictionary.candidates("abc", max_distance: 1)
  end

  def test_preserves_identities_that_normalize_to_the_same_text
    words = ["Café", "café", "CAFÉ"]
    dictionary = Text::Levenshtein::Dictionary.new(words, normalize: :nfkc_casefold)

    assert_equal words, dictionary.candidates("café", max_distance: 0)
    assert_equal 3, dictionary.length
  end

  def test_ties_use_priority_then_input_order
    words = %w[bcd cde abc axy]
    priority = { "bcd" => 2, "cde" => 1, "abc" => 1, "axy" => 2 }
    dictionary = Text::Levenshtein::Dictionary.new(words, priority: priority)

    assert_equal %w[bcd cde abc axy], dictionary.candidates("acd", max_distance: 2)
    assert_equal %w[bcd cde], dictionary.top_k("acd", 2)
  end

  def test_query_normalization_matches_index_normalization
    dictionary = Text::Levenshtein::Dictionary.new(%w[Cafe], normalize: :case)

    assert_equal ["Cafe"], dictionary.candidates("CAFE", max_distance: 0)
  end

  def test_accepts_a_set_of_strings
    dictionary = Text::Levenshtein::Dictionary.new(Set.new(%w[cat dog]))

    assert_equal ["cat"], dictionary.candidates("car", max_distance: 1)
  end

  def test_normalized_priority_search_matches_naive_scan
    rng = Random.new(314159)
    alphabet = ("a".."f").to_a
    base_words = Array.new(100) do
      Array.new(rng.rand(1..6)) { alphabet.sample(random: rng) }.join
    end.uniq
    words = base_words.map { |word| word.chars.map { |char| char.send(rng.rand(2).zero? ? :upcase : :downcase) }.join }
    priority = lambda { |word| word.bytes.sum % 3 }
    dictionary = Text::Levenshtein::Dictionary.new(words, normalize: :case, &priority)

    40.times do
      query = Array.new(rng.rand(0..7)) { alphabet.sample(random: rng) }.join
      normalized_query = query.downcase
      expected = words.each_with_index.map do |word, ordinal|
        [
          Text::Levenshtein.distance(normalized_query, word.downcase),
          priority.call(word),
          ordinal,
          word
        ]
      end

      0.upto(2) do |max_distance|
        candidates = expected.select { |match| match.first <= max_distance }.sort.map(&:last)
        assert_equal candidates, dictionary.candidates(query, max_distance: max_distance)
      end

      1.upto(5) do |k|
        assert_equal expected.sort.first(k).map(&:last), dictionary.top_k(query, k)
      end
    end
  end

  def test_export_and_load_round_trip
    dictionary = Text::Levenshtein::Dictionary.new(
      ["CAT", "Cat"],
      normalize: :case,
      priority: { "CAT" => 2, "Cat" => 1 }
    )
    json = dictionary.export
    restored = Text::Levenshtein::Dictionary.load(json)

    assert_equal ["Cat", "CAT"], restored.candidates("cat", max_distance: 0)
    assert_equal dictionary.node_count, restored.node_count
    assert_equal dictionary.length, restored.length
  end

  def test_export_contains_plain_json_without_object_additions
    json = Text::Levenshtein::Dictionary.new(%w[cat]).export
    parsed = JSON.parse(json, create_additions: false)

    assert_equal "text-levenshtein-dictionary", parsed["format"]
    refute json.include?("!ruby/")
  end

  def test_load_rejects_malformed_json_and_ruby_object_tags
    assert_raise(Text::Levenshtein::Dictionary::InvalidIndexError) do
      Text::Levenshtein::Dictionary.load("{")
    end

    json = JSON.generate(
      "json_class" => "Text::Levenshtein::Dictionary",
      "format" => "text-levenshtein-dictionary",
      "version" => 1,
      "normalization_config" => { "type" => "symbol", "name" => "none" },
      "trie" => { "entries" => [], "children" => {} }
    )

    assert_kind_of Hash, JSON.parse(json, create_additions: false)
    assert_raise(Text::Levenshtein::Dictionary::InvalidIndexError) do
      Text::Levenshtein::Dictionary.load(json)
    end
  end

  def test_rejects_unknown_format_and_version
    payload = {
      "format" => "text-levenshtein-dictionary",
      "version" => 999,
      "normalization_config" => { "type" => "symbol", "name" => "none" },
      "trie" => { "entries" => [], "children" => {} }
    }

    assert_raise(Text::Levenshtein::Dictionary::IncompatibleIndexError) do
      Text::Levenshtein::Dictionary.load(JSON.generate(payload))
    end

    payload["version"] = 1
    payload["format"] = "something-else"
    assert_raise(Text::Levenshtein::Dictionary::InvalidIndexError) do
      Text::Levenshtein::Dictionary.load(JSON.generate(payload))
    end
  end

  def test_rejects_normalization_config_mismatch
    dictionary = Text::Levenshtein::Dictionary.new(%w[CAT], normalize: :case)

    assert_raise(Text::Levenshtein::Dictionary::IncompatibleIndexError) do
      Text::Levenshtein::Dictionary.load(dictionary.export, normalize: :none)
    end

    assert_raise(Text::Levenshtein::Dictionary::IncompatibleIndexError) do
      Text::Levenshtein::Dictionary.load(dictionary.export, normalize: :case,
                                         normalization_config: { "name" => "other" })
    end
  end

  def test_load_requires_custom_normalizer_for_custom_config
    normalizer = lambda { |text| text.downcase.gsub(/[^a-z]/, "") }
    dictionary = Text::Levenshtein::Dictionary.new(
      %w[cafe],
      normalize: normalizer,
      normalization_config: { "type" => "strip_non_lowercase_letters" }
    )
    json = dictionary.export

    assert_raise(Text::Levenshtein::Dictionary::IncompatibleIndexError) do
      Text::Levenshtein::Dictionary.load(json)
    end

    restored = Text::Levenshtein::Dictionary.load(
      json,
      normalize: normalizer,
      normalization_config: { "type" => "strip_non_lowercase_letters" }
    )
    assert_equal ["cafe"], restored.candidates("CAFE!", max_distance: 0)
  end

  def test_reports_shared_prefix_node_expansion
    words = 1000.times.map { |index| "sharedprefix%03d" % index }
    dictionary = Text::Levenshtein::Dictionary.new(words)
    result = dictionary.candidates_with_stats("sharedprefix042", max_distance: 0)

    assert_equal ["sharedprefix042"], result[:candidates]
    assert_operator result[:expanded_nodes], :<, dictionary.node_count
    assert_equal 1123, dictionary.node_count
    assert_equal 16, result[:expanded_nodes]
  end
end

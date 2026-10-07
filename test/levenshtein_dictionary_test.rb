# coding: UTF-8

require_relative "./test_helper"
require "text/levenshtein/dictionary"
require "stringio"

class LevenshteinDictionaryTest < Test::Unit::TestCase
  def test_finds_candidates_within_distance
    dictionary = build_dictionary(words)

    result = dictionary.candidates("car", 1, include_stats: true)

    assert_equal ["car", "care", "card", "bar"], result.matches.map(&:entry)
    assert_equal [0, 1, 1, 1], result.matches.map(&:distance)
    assert_equal ["car", "care", "card", "bar"], dictionary.candidates("car", 1)
    assert_operator result.expanded_nodes, :<, 111
  end

  def test_finds_exact_top_k_with_stable_priority
    dictionary = build_dictionary(words)

    assert_equal ["car", "care", "card"], dictionary.top_k("car", 3)
    assert_equal ["car", "care", "card", "bar"], dictionary.top_k("car", 4, max_distance: 1)
    assert_equal [], dictionary.top_k("car", 0)
  end

  def test_matches_naive_scan_for_small_dictionary
    srand(2468)
    entries = Array.new(60) { random_word }.uniq
    priorities = entries.each_with_index.each_with_object({}) do |(entry, index), map|
      map[entry] = index if index.even?
    end
    dictionary = Text::Levenshtein::Dictionary.new(entries) { |entry| priorities.fetch(entry, 100) }

    30.times do
      query = random_word
      [0, 1, 2].each do |max_distance|
        assert_equal naive_candidates(entries, priorities, query, max_distance),
                     dictionary.candidates(query, max_distance)
      end

      [1, 5, 10, 100].each do |k|
        assert_equal naive_top_k(entries, priorities, query, k),
                     dictionary.top_k(query, k)
      end
    end
  end

  def test_keeps_duplicate_identities_after_normalization
    first = "Caf\u00e9"
    second = "Cafe\u0301"
    dictionary = Text::Levenshtein::Dictionary.new(
      [first, second, "cafe"],
      normalization: :nfc,
      case_insensitive: true
    )

    assert_equal [first, second], dictionary.candidates("caf\u00e9", 0)
    assert_equal ["cafe", first, second], dictionary.top_k("cafe", 10)
    assert_equal 3, dictionary.size
  end

  def test_reuses_shared_prefix_edit_state
    dictionary = Text::Levenshtein::Dictionary.new(shared_prefix_words)

    exact = dictionary.search("prefix000", max_distance: 0)
    approximate = dictionary.search("prefix000", max_distance: 1)

    assert_equal ["prefix000"], exact.matches.map(&:entry)
    assert_equal 10, exact.expanded_nodes
    assert_equal 64, approximate.expanded_nodes
    assert_equal 1117, trie_node_count(dictionary)
    assert_operator approximate.expanded_nodes, :<, trie_node_count(dictionary)
  end

  def test_exports_and_reloads_without_generic_deserialization
    dictionary = build_dictionary(words)
    exported = dictionary.export
    reloaded = Text::Levenshtein::Dictionary.load(exported)

    assert_equal dictionary.entries, reloaded.entries
    assert_equal dictionary.top_k("car", 4), reloaded.top_k("car", 4)
    assert_not_match(/json_class|Marshal|yaml/, exported)

    io = StringIO.new
    dictionary.export(io)
    assert_equal exported, io.string
  end

  def test_rejects_incompatible_export
    assert_raise(ArgumentError) do
      exported = JSON.parse(build_dictionary(words).export)
      Text::Levenshtein::Dictionary.load(exported.merge("version" => 2).to_json)
    end
    assert_raise(ArgumentError) do
      exported = JSON.parse(build_dictionary(words).export)
      exported["config"]["case_insensitive"] = true
      Text::Levenshtein::Dictionary.load(exported.to_json)
    end
    assert_raise(ArgumentError) do
      exported = JSON.parse(build_dictionary(words).export)
      exported["config"]["normalization"] = "nfc"
      Text::Levenshtein::Dictionary.load(exported.to_json)
    end
    assert_raise(ArgumentError) do
      exported = JSON.parse(build_dictionary(words).export)
      exported["config"]["normalization"] = 123
      Text::Levenshtein::Dictionary.load(exported.to_json)
    end
  end

  def test_does_not_deserialize_arbitrary_objects
    payload = {
      "format" => "text-levenshtein-dictionary",
      "version" => 1,
      "config" => { "normalization" => nil, "case_insensitive" => false },
      "entries" => [
        { "entry" => "cat", "rank" => 0, "priority" => 1, "json_class" => "Object" }
      ]
    }

    reloaded = Text::Levenshtein::Dictionary.load(payload.to_json)
    assert_equal ["cat"], reloaded.entries
  end

  def test_explicit_priority_overrides_constructor_block
    dictionary = Text::Levenshtein::Dictionary.new(["car"]) { 10 }
    dictionary.add("card", 2)
    dictionary.add("care")

    assert_equal ["car", "card", "care"], dictionary.top_k("car", 3)
  end

  private

  def words
    %w[car card care bar barn bat]
  end

  def build_dictionary(entries)
    Text::Levenshtein::Dictionary.new(entries) { |entry| priorities.fetch(entry) }
  end

  def priorities
    { "car" => 0, "care" => 1, "card" => 2, "bar" => 3, "barn" => 4, "bat" => 5 }
  end

  def naive_candidates(entries, priorities, query, max_distance)
    sorted_entries(entries, priorities, query).select { |_, distance, _| distance <= max_distance }
                                             .map(&:first)
  end

  def naive_top_k(entries, priorities, query, k)
    sorted_entries(entries, priorities, query).first(k).map(&:first)
  end

  def sorted_entries(entries, priorities, query)
    entries.each_with_index.map do |entry, index|
      [entry, distance(entry, query), priorities.fetch(entry, 100), index]
    end.sort_by { |_, distance, priority, index| [distance, priority, index] }
  end

  def distance(a, b)
    row = (0..b.length).to_a
    a.each_char.with_index do |char_a, i|
      next_row = [i + 1]
      b.each_char.with_index do |char_b, j|
        next_row << [
          row[j] + (char_a == char_b ? 0 : 1),
          row[j + 1] + 1,
          next_row[j] + 1
        ].min
      end
      row = next_row
    end
    row.last
  end

  def random_word
    (0...(rand(4) + 2)).map { %w[a b c d][rand(4)] }.join
  end

  def shared_prefix_words
    (0...1000).map { |number| format("prefix%03d", number) }
  end

  def trie_node_count(dictionary)
    root = dictionary.instance_variable_get(:@root)
    stack = [root]
    count = 0
    until stack.empty?
      node = stack.pop
      count += 1
      stack.concat(node.children.values)
    end
    count
  end
end

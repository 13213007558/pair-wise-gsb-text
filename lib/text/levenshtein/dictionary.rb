# encoding: utf-8

require "json"
require "text/levenshtein"

module Text # :nodoc:
module Levenshtein

class Dictionary
  FORMAT_NAME = "text-levenshtein-dictionary"
  FORMAT_VERSION = 1

  class DictionaryError < StandardError; end
  class InvalidIndexError < DictionaryError; end
  class IncompatibleIndexError < DictionaryError; end

  Node = Struct.new(:children, :entries) # :nodoc:
  Entry = Struct.new(:word, :priority, :ordinal) # :nodoc:

  def self.load(source, normalize: nil, normalization_config: nil)
    json = source.respond_to?(:read) ? source.read : source
    raise TypeError, "expected a JSON string or IO" unless json.is_a?(String)

    begin
      payload = JSON.parse(json, create_additions: false)
    rescue JSON::ParserError => error
      raise InvalidIndexError, "invalid dictionary JSON: #{error.message}"
    end

    dictionary = allocate
    dictionary.send(:load_payload, payload, normalize, normalization_config)
    dictionary
  end

  def self.load_file(path, normalize: nil, normalization_config: nil)
    load(File.read(path), normalize: normalize, normalization_config: normalization_config)
  end

  def initialize(words = [], normalize: nil, normalization_config: nil, priority: nil, &priority_block)
    raise ArgumentError, "provide either priority: or a block, not both" if priority && block_given?

    @normalizer, @normalization_config = resolve_normalizer(normalize, normalization_config)
    @priority = block_given? ? priority_block : priority
    @root = Node.new({}, [])
    @node_count = 1
    @length = 0

    unless words.respond_to?(:each)
      raise TypeError, "words must be an enumerable collection of strings"
    end

    words.each_with_index { |word, ordinal| add(word, ordinal) }
  end

  def candidates(query, max_distance:, stats: false)
    raise ArgumentError, "max_distance must be non-negative" unless non_negative_integer?(max_distance)

    result = search(normalize_query(query), max_distance: max_distance)
    words = result[:matches].map { |match| match[:word] }
    stats ? { candidates: words, expanded_nodes: result[:expanded_nodes] } : words
  end

  def candidates_with_stats(query, max_distance:)
    candidates(query, max_distance: max_distance, stats: true)
  end

  def top_k(query, k)
    raise ArgumentError, "k must be positive" unless positive_integer?(k)

    search(normalize_query(query), limit: k)[:matches].map { |match| match[:word] }
  end

  attr_reader :node_count
  attr_reader :length
  alias size length

  def export(output = nil)
    json = JSON.generate(
      "format" => FORMAT_NAME,
      "version" => FORMAT_VERSION,
      "normalization_config" => @normalization_config,
      "trie" => serialize_trie
    )

    return json if output.nil?
    if output.is_a?(String)
      File.write(output, json)
      return output
    end

    if output.respond_to?(:write)
      output.write(json)
      output
    else
      raise TypeError, "expected a path or IO-like object"
    end
  end

private

  def add(word, ordinal)
    raise TypeError, "dictionary entries must be strings" unless word.is_a?(String)

    original = word.dup.encode(Encoding::UTF_8)
    normalized = normalize_text(original)
    value = priority_for(original, ordinal)
    JSON.generate(value)

    node = normalized.inject(@root) do |current, char|
      current.children[char] ||= begin
        @node_count += 1
        Node.new({}, [])
      end
    end

    node.entries << Entry.new(original, value, ordinal)
    @length += 1
  end

  def search(query, max_distance: nil, limit: nil)
    stack = [{ node: @root, row: (0..query.length).to_a, depth: 0 }]
    matches = []
    expanded_nodes = 0
    cutoff = max_distance

    until stack.empty?
      state = stack.pop
      row = state[:row]
      distance = row.last
      expanded_nodes += 1

      next if cutoff && row.min > cutoff

      if !state[:node].entries.empty? && (cutoff.nil? || distance <= cutoff)
        state[:node].entries.each do |entry|
          candidate = {
            distance: distance,
            priority: entry.priority,
            ordinal: entry.ordinal,
            word: entry.word
          }

          if limit
            insert_limited_match(matches, candidate, limit)
            cutoff = matches.last[:distance] if matches.length == limit
          else
            matches << candidate
          end
        end
      end

      state[:node].children.sort_by(&:first).reverse_each do |char, child|
        depth = state[:depth] + 1
        next if cutoff && depth > query.length + cutoff
        child_row = next_row(row, query, char)
        next if cutoff && child_row.min > cutoff
        stack << { node: child, row: child_row, depth: depth }
      end
    end

    { matches: limit ? matches : matches.sort { |a, b| compare_match(a, b) }, expanded_nodes: expanded_nodes }
  end

  def next_row(row, query, char)
    values = [row.first + 1]
    (1...row.length).each do |column|
      values << [
        row[column] + 1,
        values[column - 1] + 1,
        row[column - 1] + (char == query[column - 1] ? 0 : 1)
      ].min
    end
    values
  end

  def insert_limited_match(matches, candidate, limit)
    index = matches.bsearch_index { |existing| compare_match(candidate, existing) < 0 }
    if index
      matches.insert(index, candidate)
    elsif matches.length < limit
      matches << candidate
    end
    matches.pop if matches.length > limit
  end

  def compare_match(left, right)
    comparison = left[:distance] <=> right[:distance]
    return comparison unless comparison.zero?

    comparison = left[:priority] <=> right[:priority]
    if comparison.nil?
      left[:ordinal] <=> right[:ordinal]
    elsif comparison.zero?
      left[:ordinal] <=> right[:ordinal]
    else
      comparison
    end
  end

  def priority_for(word, ordinal)
    return ordinal if @priority.nil?

    value = if @priority.respond_to?(:call)
      @priority.call(word)
    elsif @priority.respond_to?(:[])
      @priority[word]
    end
    value.nil? ? ordinal : value
  end

  def normalize_query(query)
    raise TypeError, "query must be a string" unless query.is_a?(String)
    normalize_text(query.dup)
  end

  def normalize_text(text)
    text.encode!(Encoding::UTF_8)
    normalized = @normalizer.call(text)
    raise TypeError, "normalizer must return a string" unless normalized.is_a?(String)
    normalized.dup.encode(Encoding::UTF_8).unpack("U*")
  end

  def resolve_normalizer(normalize, explicit_config)
    name = normalize.nil? ? :none : normalize

    if name.is_a?(Symbol)
      config = { "type" => "symbol", "name" => name.to_s }
      if explicit_config && JSON.generate(explicit_config) != JSON.generate(config)
        raise IncompatibleIndexError, "normalization_config does not match #{name}"
      end
      [built_in_normalizer(name), config]
    elsif name.respond_to?(:call)
      config = explicit_config
      config ||= name.normalization_config if name.respond_to?(:normalization_config)
      unless config.is_a?(Hash)
        raise ArgumentError, "custom normalizers require a JSON-serializable normalization_config"
      end
      json_config = JSON.parse(JSON.generate(config))
      raise ArgumentError, "normalization_config must be a JSON object" unless json_config.is_a?(Hash)
      [name, json_config]
    else
      raise ArgumentError, "normalize must be :none, :case, :nfkc_casefold, or callable"
    end
  end

  def built_in_normalizer(name)
    case name
    when :none then lambda { |text| text }
    when :case then lambda { |text| text.downcase }
    when :nfkc_casefold then lambda { |text| text.unicode_normalize(:nfkc).downcase }
    else raise ArgumentError, "unknown normalizer #{name.inspect}"
    end
  end

  def serialize_trie
    root = blank_node
    stack = [[@root, root]]

    until stack.empty?
      node, target = stack.pop
      target["entries"] = node.entries.map { |entry| [entry.word, entry.priority, entry.ordinal] }
      node.children.each do |char, child|
        target_child = blank_node
        target["children"][char.chr(Encoding::UTF_8)] = target_child
        stack << [child, target_child]
      end
    end

    root
  end

  def blank_node
    { "entries" => [], "children" => {} }
  end

  def load_payload(payload, normalize_option, explicit_config)
    validate_payload(payload)

    config = payload["normalization_config"]
    @normalizer, resolved_config = resolve_loaded_normalizer(config, normalize_option, explicit_config)
    unless resolved_config == config
      raise IncompatibleIndexError, "normalization config does not match index"
    end

    @root = Node.new({}, [])
    @node_count = 1
    @length = 0
    @priority = nil
    ordinals = {}

    stack = [[@root, payload["trie"]]]
    until stack.empty?
      node, serialized = stack.pop
      unless serialized["entries"].all? { |entry| entry.is_a?(Array) && entry.length == 3 }
        raise InvalidIndexError, "entries must contain word, priority, and ordinal"
      end

      serialized["entries"].each do |word, priority, ordinal|
        validate_entry(word, priority, ordinal)
        if ordinals.key?(ordinal)
          raise InvalidIndexError, "entry ordinals must be unique"
        end
        ordinals[ordinal] = true
        node.entries << Entry.new(word, priority, ordinal)
        @length += 1
      end

      serialized["children"].each do |char, child|
        validate_node(child)
        codepoints = char.unpack("U*")
        unless codepoints.length == 1
          raise InvalidIndexError, "trie edge labels must contain one Unicode codepoint"
        end
        node.children[codepoints.first] = child_node = Node.new({}, [])
        @node_count += 1
        stack << [child_node, child]
      end
    end
  end

  def validate_payload(payload)
    unless payload.is_a?(Hash) && payload.keys.sort == %w(format normalization_config trie version)
      raise InvalidIndexError, "unexpected dictionary payload shape"
    end
    unless payload["format"] == FORMAT_NAME
      raise InvalidIndexError, "unexpected dictionary format"
    end
    unless payload["version"] == FORMAT_VERSION
      raise IncompatibleIndexError, "incompatible dictionary version"
    end
    raise InvalidIndexError, "normalization config must be an object" unless payload["normalization_config"].is_a?(Hash)
    validate_node(payload["trie"])
  end

  def validate_node(node)
    unless node.is_a?(Hash) && node.keys.sort == %w(children entries)
      raise InvalidIndexError, "unexpected trie node shape"
    end
    unless node["children"].is_a?(Hash) && node["entries"].is_a?(Array)
      raise InvalidIndexError, "unexpected trie node contents"
    end
  end

  def validate_entry(word, priority, ordinal)
    unless word.is_a?(String) && word.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      raise InvalidIndexError, "dictionary identities must be UTF-8 strings"
    end
    unless ordinal.is_a?(Integer) && ordinal >= 0
      raise InvalidIndexError, "entry ordinals must be non-negative integers"
    end
    JSON.generate(priority)
  end

  def resolve_loaded_normalizer(config, normalize_option, explicit_config)
    if normalize_option || explicit_config
      resolve_normalizer(normalize_option, explicit_config)
    elsif config == { "type" => "symbol", "name" => "none" }
      [built_in_normalizer(:none), config]
    elsif config == { "type" => "symbol", "name" => "case" }
      [built_in_normalizer(:case), config]
    elsif config == { "type" => "symbol", "name" => "nfkc_casefold" }
      [built_in_normalizer(:nfkc_casefold), config]
    else
      raise IncompatibleIndexError, "custom normalization config requires a matching normalizer"
    end
  end

  def non_negative_integer?(value)
    value.is_a?(Integer) && value >= 0
  end

  def positive_integer?(value)
    value.is_a?(Integer) && value > 0
  end
end

end
end

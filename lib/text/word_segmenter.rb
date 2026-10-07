# frozen_string_literal: true

require 'unicode_normalize' unless String.method_defined?(:unicode_normalize)

module Text
  # Finds the highest-probability word sequence for a string in which word
  # boundaries have been lost.
  class WordSegmenter
    Token = Struct.new(:value, :start, :finish, :known) do
      def range
        start...finish
      end
      alias to_s value
    end

    Result = Struct.new(:tokens, :score) do
      def words
        tokens.map(&:value)
      end
      alias to_a words

      def ranges
        tokens.map(&:range)
      end

      def to_h
        {
          words: words,
          score: score,
          ranges: ranges
        }
      end
    end

    DEFAULT_OPTIONS = {
      bigram_weight: 0.5,
      unknown_cost: 6.0,
      unknown_per_char_cost: 2.0,
      max_unknown_length: 4,
      normalization: :case
    }

    # call-seq:
    #   Text::WordSegmenter.new(word_counts, bigram_counts = nil, options = {})
    #
    # +word_counts+ maps a canonical word to its frequency. +bigram_counts+
    # maps [previous_word, word] pairs to adjacent frequencies.
    # Equal-cost paths are resolved by the lexicographically smallest canonical
    # word sequence, then the smallest original-value sequence.
    def initialize(word_counts, bigram_counts = nil, options = {})
      options = DEFAULT_OPTIONS.merge(options)

      @word_counts = normalize_counts(word_counts)
      @total_count = @word_counts.values.inject(0, :+).to_f
      raise ArgumentError, "word_counts must contain at least one positive count" if @total_count.zero?

      @bigram_counts = normalize_bigram_counts(bigram_counts || {})
      @bigram_totals = Hash.new(0.0)
      @bigram_counts.each do |(previous_word, _), count|
        @bigram_totals[previous_word] += count
      end

      @bigram_weight = fetch_float(options, :bigram_weight)
      raise ArgumentError, "bigram_weight must be between 0 and 1" unless (0.0..1.0).cover?(@bigram_weight)

      @unknown_cost = fetch_float(options, :unknown_cost)
      @unknown_per_char_cost = fetch_float(options, :unknown_per_char_cost)
      @max_unknown_length = options.fetch(:max_unknown_length, 4)
      unless @max_unknown_length.is_a?(Integer) && @max_unknown_length >= 1
        raise ArgumentError, "max_unknown_length must be a positive integer"
      end

      @normalization = options.fetch(:normalization, :case)
      unless [:none, :case, :unicode, :case_and_unicode].include?(@normalization)
        raise ArgumentError, "unknown normalization: #{@normalization.inspect}"
      end

      @hard_boundaries = build_boundary_predicate(options[:hard_boundaries])
    end

    def segment(string)
      raise TypeError, "string must be a String" unless string.is_a?(String)

      chars = string.chars.to_a
      return Result.new([], 0.0) if chars.empty?

      cuts = hard_cuts(chars)
      paths = { 0 => Path.new(0.0, [], [], []) }

      each_position(chars) do |start_index|
        path = paths[start_index]
        next unless path

        candidates(chars, cuts, start_index).each do |candidate|
          finish = start_index + candidate.length
          candidate_score = score(candidate, path)
          total_score = path.score + candidate_score
          candidate_key = path.key + [candidate.key]
          candidate_values = path.values + [candidate.value]
          candidate_backtrace = path.backtrace + [candidate]
          candidate_path = Path.new(total_score, candidate_key, candidate_values, candidate_backtrace)
          existing = paths[finish]

          if existing.nil? || better?(candidate_path, existing)
            paths[finish] = candidate_path
          end
        end
      end

      final_path = paths[chars.length]
      if final_path.nil? || final_path.key.empty?
        raise ArgumentError, "input cannot be segmented under the configured unknown-word limit"
      end

      build_result(chars, final_path)
    end

    def self.segment(string, word_counts, bigram_counts = nil, options = {})
      new(word_counts, bigram_counts, options).segment(string)
    end

    private

    Path = Struct.new(:score, :key, :values, :backtrace)
    Candidate = Struct.new(:length, :key, :known, :value)

    def fetch_float(options, key)
      value = options.fetch(key)
      raise ArgumentError, "#{key} must be numeric" unless value.is_a?(Numeric)
      value.to_f
    end

    def normalize_counts(counts)
      unless counts.respond_to?(:each_pair)
        raise TypeError, "word_counts must respond to each_pair"
      end

      counts.each_with_object({}) do |(word, count), normalized|
        count = validate_count(count, "word count")
        key = canonical(word.to_s)
        normalized[key] = normalized.fetch(key, 0.0) + count
      end
    end

    def normalize_bigram_counts(counts)
      unless counts.respond_to?(:each_pair)
        raise TypeError, "bigram_counts must respond to each_pair"
      end

      counts.each_with_object({}) do |(pair, count), normalized|
        unless pair.is_a?(Array) && pair.length == 2
          raise ArgumentError, "bigram keys must be two-element arrays"
        end

        previous_word = canonical(pair[0].to_s)
        word = canonical(pair[1].to_s)
        unless @word_counts.key?(previous_word) && @word_counts.key?(word)
          raise ArgumentError, "bigram #{pair.inspect} contains an unknown word"
        end

        count = validate_count(count, "bigram count")
        normalized[[previous_word, word]] = normalized.fetch([previous_word, word], 0.0) + count
      end
    end

    def validate_count(count, description)
      begin
        converted = Float(count)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{description} must be numeric"
      end
      raise ArgumentError, "#{description} must be non-negative" unless converted >= 0
      converted
    end

    def canonical(string)
      string = string.unicode_normalize(:nfkc) if unicode_normalization?
      string = string.downcase if case_normalization?
      string
    end

    def case_normalization?
      @normalization == :case || @normalization == :case_and_unicode
    end

    def unicode_normalization?
      @normalization == :unicode || @normalization == :case_and_unicode
    end

    def build_boundary_predicate(hard_boundaries)
      case hard_boundaries
      when nil
        nil
      when Proc, Method
        hard_boundaries
      when Regexp
        lambda { |character| hard_boundaries.match?(character) }
      when String
        characters = hard_boundaries.chars.to_a
        lambda { |character| characters.include?(character) }
      else
        raise ArgumentError, "hard_boundaries must be callable, a Regexp, or a String"
      end
    end

    def hard_cuts(chars)
      return [] if @hard_boundaries.nil?

      cuts = []
      chars.each_with_index do |character, index|
        if @hard_boundaries.call(character)
          cuts << index
          cuts << index + 1 unless index + 1 == chars.length
        end
      end
      cuts.uniq.sort
    rescue => error
      raise ArgumentError, "hard_boundaries predicate failed: #{error.message}"
    end

    def each_position(chars)
      chars.length.times { |index| yield index }
    end

    def crosses_cut?(cuts, start_index, finish)
      cuts.any? { |cut| cut > start_index && cut < finish }
    end

    def candidates(chars, cuts, start_index)
      known = []
      unknown = []

      1.upto(chars.length - start_index) do |length|
        finish = start_index + length
        next if crosses_cut?(cuts, start_index, finish)

        value = chars[start_index, length].join
        key = canonical(value)
        if @word_counts.key?(key)
          known << Candidate.new(length, key, true, value)
        elsif length <= @max_unknown_length &&
            !single_unknown_for_whole_input?(chars.length, cuts, start_index, finish)
          unknown << Candidate.new(length, key, false, value)
        end
      end

      known.sort_by(&:length) + unknown.sort_by(&:length)
    end

    def single_unknown_for_whole_input?(length, cuts, start_index, finish)
      length > 1 && cuts.empty? && start_index.zero? && finish == length
    end

    def score(candidate, path)
      if candidate.known
        known_score(candidate.key, path)
      else
        @unknown_cost + (@unknown_per_char_cost * candidate.length)
      end
    end

    def known_score(word, path)
      unigram = word_probability(word)
      probability = unigram

      if @bigram_weight.positive? && !path.key.empty?
        previous_word = path.key.last
        adjacent = bigram_probability(previous_word, word, unigram)
        probability = ((1.0 - @bigram_weight) * unigram) + (@bigram_weight * adjacent)
      end

      -Math.log(probability.clamp(Float::EPSILON, 1.0))
    end

    def word_probability(word)
      @word_counts.fetch(word, 0.0) / @total_count
    end

    def bigram_probability(previous_word, word, unigram)
      previous_total = @bigram_totals[previous_word]
      return unigram if previous_total.nil? || previous_total.zero?

      pair_count = @bigram_counts.fetch([previous_word, word], 0.0)
      pair_count / previous_total
    end

    def better?(candidate, existing)
      key_comparison = candidate.key <=> existing.key
      value_comparison = candidate.values <=> existing.values

      candidate.score < existing.score ||
        (candidate.score == existing.score &&
          (key_comparison == -1 ||
            (key_comparison.zero? && value_comparison == -1)))
    end

    def build_result(chars, final_path)
      tokens = []
      start_index = 0

      final_path.backtrace.each do |candidate|
        finish = start_index + candidate.length
        value = chars[start_index, candidate.length].join
        tokens << Token.new(value, start_index, finish, candidate.known)
        start_index = finish
      end

      Result.new(tokens, final_path.score)
    end
  end
end

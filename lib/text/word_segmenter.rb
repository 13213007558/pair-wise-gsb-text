# encoding: utf-8

module Text
  # Dynamic programming word segmentation for strings imported without spaces.
  # Ties choose fewer unknown words, then fewer tokens, then the latest first
  # boundary, giving a deterministic result without depending on hash order.
  class WordSegmenter
    Token = Struct.new(
      :text,
      :start_char,
      :end_char,
      :start_byte,
      :end_byte,
      :known
    ) do
      def known?
        known
      end
    end

    Result = Struct.new(:words, :score, :cost, :tokens)

    State = Struct.new(
      :cost,
      :previous,
      :start_char,
      :end_char,
      :key,
      :known,
      :unknown_word_count,
      :token_count
    )

    def initialize(
      word_counts,
      bigram_counts: nil,
      case_normalization: nil,
      unicode_normalization: nil,
      unigram_alpha: 0.1,
      bigram_alpha: 0.1,
      max_unknown_length: 3,
      unknown_base_penalty: 4.0,
      unknown_per_char_penalty: 1.0
    )
      unless [nil, :downcase].include?(case_normalization)
        raise ArgumentError, "case_normalization must be nil or :downcase"
      end

      unless [nil, :nfc, :nfd, :nfkc, :nfkd].include?(unicode_normalization)
        raise ArgumentError,
          "unicode_normalization must be nil, :nfc, :nfd, :nfkc, or :nfkd"
      end

      validate_positive_number(unigram_alpha, :unigram_alpha)
      validate_positive_number(bigram_alpha, :bigram_alpha)
      unless max_unknown_length.is_a?(Integer) && max_unknown_length >= 1
        raise ArgumentError, ":max_unknown_length must be a positive integer"
      end
      validate_non_negative_number(unknown_base_penalty, :unknown_base_penalty)
      validate_positive_number(
        unknown_per_char_penalty,
        :unknown_per_char_penalty
      )

      @case_normalization = case_normalization
      @unicode_normalization = unicode_normalization
      @unigram_alpha = Float(unigram_alpha)
      @bigram_alpha = Float(bigram_alpha)
      @max_unknown_length = max_unknown_length
      @unknown_base_penalty = Float(unknown_base_penalty)
      @unknown_per_char_penalty = Float(unknown_per_char_penalty)

      @word_counts = {}
      word_counts.each do |word, count|
        add_count!(@word_counts, normalize_key(word), count, :word_counts)
      end

      @vocabulary_size = @word_counts.length
      @total_word_count = @word_counts.values.inject(0.0, :+)
      @unigram_costs = Hash[@word_counts.map do |key, count|
        [key, unigram_cost(count)]
      end]

      @bigram_counts = {}
      @use_bigram_costs = !bigram_counts.nil?
      read_bigram_counts(bigram_counts) if @use_bigram_costs
    end

    def segment(string, hard_boundaries: nil)
      text = string.encode(Encoding::UTF_8)
      characters = text.each_codepoint.map do |codepoint|
        codepoint.chr(Encoding::UTF_8)
      end
      byte_positions = character_byte_positions(characters)
      forced_boundaries, boundary_predicate =
        resolve_hard_boundaries(hard_boundaries, characters)
      limits = candidate_limits(characters, boundary_predicate)

      initial_state = State.new(0.0, nil, nil, nil, nil, nil, 0, 0)
      states = Array.new(characters.length + 1)
      states[0] = initial_state

      1.upto(characters.length) do |end_char|
        0.upto(end_char - 1) do |start_char|
          previous_state = states[start_char]
          next if previous_state.nil?
          next if end_char > limits[start_char]
          next if crosses_forced_boundary?(
            start_char,
            end_char,
            forced_boundaries
          )

          length = end_char - start_char
          raw_word = characters[start_char, length].join
          key = normalize_key(raw_word)
          known = @word_counts.key?(key)
          next unless known || length <= @max_unknown_length

          word_cost = if known
            @unigram_costs.fetch(key)
          else
            unknown_cost(length)
          end

          transition_cost = if @use_bigram_costs && start_char > 0
            transition_cost(
              previous_state.key,
              previous_state.known,
              key,
              known
            )
          else
            0.0
          end

          candidate = State.new(
            previous_state.cost + word_cost + transition_cost,
            previous_state,
            start_char,
            end_char,
            key,
            known,
            previous_state.unknown_word_count + (known ? 0 : 1),
            previous_state.token_count + 1
          )

          if better_state?(candidate, states[end_char])
            states[end_char] = candidate
          end
        end
      end

      build_result(characters, byte_positions, states.last)
    end

    private

    def normalize_key(value)
      key = String(value).encode(Encoding::UTF_8)
      key = key.downcase if @case_normalization == :downcase
      if @unicode_normalization
        key = key.unicode_normalize(@unicode_normalization)
      end
      key
    end

    def unigram_cost(count)
      denominator =
        @total_word_count + @unigram_alpha * (@vocabulary_size + 1)
      numerator = count + @unigram_alpha
      -Math.log(numerator / denominator)
    end

    def unknown_cost(length)
      @unknown_base_penalty + @unknown_per_char_penalty * length
    end

    def transition_cost(previous_key, previous_known, key, known)
      vocabulary_events = @vocabulary_size + 1
      denominator = if previous_known
        @word_counts.fetch(previous_key, 0.0) +
          @bigram_alpha * vocabulary_events
      else
        @bigram_alpha * vocabulary_events
      end

      pair_count = if previous_known && known
        @bigram_counts.dig(previous_key, key) || 0.0
      else
        0.0
      end

      -Math.log((@bigram_alpha + pair_count) / denominator)
    end

    def read_bigram_counts(bigram_counts)
      unless bigram_counts.is_a?(Hash)
        raise ArgumentError, ":bigram_counts must be a Hash"
      end

      bigram_counts.each do |first, value|
        if value.is_a?(Hash)
          value.each do |second, count|
            add_bigram_count!(first, second, count)
          end
        elsif first.is_a?(Array) && first.length == 2
          add_bigram_count!(first[0], first[1], value)
        else
          raise ArgumentError,
            ":bigram_counts must use nested hashes or [first, second] keys"
        end
      end
    end

    def add_bigram_count!(first, second, count)
      unless count.is_a?(Numeric) && count >= 0
        raise ArgumentError, "bigram counts must be non-negative numbers"
      end

      first_key = normalize_key(first)
      second_key = normalize_key(second)
      @bigram_counts[first_key] ||= {}
      @bigram_counts[first_key][second_key] ||= 0.0
      @bigram_counts[first_key][second_key] += Float(count)
    end

    def add_count!(counts, key, count, name)
      unless count.is_a?(Numeric) && count > 0
        raise ArgumentError, "#{name} counts must be positive numbers"
      end
      counts[key] ||= 0.0
      counts[key] += Float(count)
    end

    def validate_positive_number(value, name)
      unless value.is_a?(Numeric) && value > 0
        raise ArgumentError, "#{name} must be a positive number"
      end
    end

    def validate_non_negative_number(value, name)
      unless value.is_a?(Numeric) && value >= 0
        raise ArgumentError, "#{name} must be a non-negative number"
      end
    end

    def character_byte_positions(characters)
      positions = [0]
      characters.each do |character|
        positions << positions.last + character.bytesize
      end
      positions
    end

    def resolve_hard_boundaries(boundaries, characters)
      case boundaries
      when nil
        [Array.new(characters.length + 1, 0), nil]
      when Regexp
        [Array.new(characters.length + 1, 0), boundaries]
      when Enumerable
        markers = Array.new(characters.length + 1, 0)
        boundaries.each do |position|
          unless position.is_a?(Integer) &&
              position >= 1 &&
              position < characters.length
            raise ArgumentError,
              "hard boundary positions must be between 1 and #{characters.length - 1}"
          end
          markers[position] = 1
        end
        prefix = Array.new(characters.length + 1, 0)
        1.upto(characters.length) do |position|
          prefix[position] = prefix[position - 1] + markers[position]
        end
        [prefix, nil]
      else
        if boundaries.respond_to?(:call)
          [Array.new(characters.length + 1, 0), boundaries]
        else
          raise ArgumentError,
            ":hard_boundaries must be a Regexp, callable, or Enumerable of positions"
        end
      end
    end

    def candidate_limits(characters, boundary_predicate)
      limits = Array.new(characters.length + 1, characters.length)
      next_boundary = characters.length

      (characters.length - 1).downto(0) do |index|
        character = characters[index]
        if hard_character?(character, boundary_predicate)
          limits[index] = index + 1
          next_boundary = index
        else
          limits[index] = next_boundary
        end
      end

      limits
    end

    def hard_character?(character, boundary_predicate)
      return false if boundary_predicate.nil?

      if boundary_predicate.is_a?(Regexp)
        boundary_predicate.match?(character)
      else
        !!boundary_predicate.call(character)
      end
    end

    def crosses_forced_boundary?(start_char, end_char, forced_boundaries)
      forced_boundaries[end_char - 1] - forced_boundaries[start_char] > 0
    end

    def better_state?(candidate, current)
      return true if current.nil?

      candidate_key = [
        candidate.cost,
        candidate.unknown_word_count,
        candidate.token_count,
        -candidate.start_char
      ]
      current_key = [
        current.cost,
        current.unknown_word_count,
        current.token_count,
        -current.start_char
      ]

      (candidate_key <=> current_key) < 0
    end

    def build_result(characters, byte_positions, state)
      tokens = []

      until state.previous.nil?
        start_char = state.start_char
        end_char = state.end_char
        tokens << Token.new(
          characters[start_char, end_char - start_char].join,
          start_char,
          end_char,
          byte_positions[start_char],
          byte_positions[end_char],
          state.known
        )
        state = state.previous
      end

      tokens.reverse!
      result = Result.new(tokens.map(&:text), nil, nil, tokens)
      result.cost = total_cost(tokens)
      result.score = -result.cost
      result
    end

    def total_cost(tokens)
      cost = 0.0

      tokens.each_with_index do |token, index|
        key = normalize_key(token.text)
        length = token.end_char - token.start_char
        cost += if token.known?
          @unigram_costs.fetch(key)
        else
          unknown_cost(length)
        end

        if @use_bigram_costs && index > 0
          previous = tokens[index - 1]
          cost += transition_cost(
            normalize_key(previous.text),
            previous.known?,
            key,
            token.known?
          )
        end
      end

      cost
    end
  end
end

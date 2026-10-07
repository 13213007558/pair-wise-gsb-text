require "json"
require "text/levenshtein"

module Text
  module Levenshtein
    class Dictionary
      VERSION = 1
      FORMAT = "text-levenshtein-dictionary"
      NORMALIZATION_FORMS = [nil, :nfc, :nfd, :nfkc, :nfkd].freeze

      Match = Struct.new(:entry, :distance, :priority, :rank) do
        include Comparable

        def <=>(other)
          return nil unless other.is_a?(Match)

          [distance, priority.nil? ? 1 : 0, priority, rank, entry] <=>
            [other.distance, other.priority.nil? ? 1 : 0, other.priority, other.rank, other.entry]
        end
      end

      SearchResult = Struct.new(:matches, :expanded_nodes)
      StoredMatch = Struct.new(:entry, :priority, :rank)

      Node = Struct.new(:children, :matches) do
        def initialize
          self.children = {}
          self.matches = []
        end
      end

      def self.load(source, normalization: nil, case_insensitive: false)
        raw = source.respond_to?(:read) ? source.read : source
        payload = JSON.parse(raw, create_additions: false)
        configuration = normalized_configuration(normalization, case_insensitive)

        validate_payload(payload, configuration)

        dictionary = new(normalization: configuration[:normalization],
                         case_insensitive: configuration[:case_insensitive])
        entries = payload["entries"]
        entries.each_with_index do |entry, expected_rank|
          unless entry.is_a?(Hash)
            raise ArgumentError, "invalid dictionary entry"
          end
          rank = read_non_negative_integer(entry, "rank")
          unless rank == expected_rank
            raise ArgumentError, "invalid dictionary rank"
          end

          dictionary.send(:add_entry,
                           read_utf8_string(entry, "entry"),
                           read_priority(entry),
                           rank)
        end
        dictionary
      end

      def self.normalized_configuration(normalization, case_insensitive)
        form = normalization.nil? ? nil : normalization.to_sym
        unless NORMALIZATION_FORMS.include?(form)
          raise ArgumentError, "unsupported normalization: #{normalization.inspect}"
        end
        unless case_insensitive.equal?(true) || case_insensitive.equal?(false)
          raise ArgumentError, "case_insensitive must be true or false"
        end

        { normalization: form, case_insensitive: case_insensitive }
      end
      private_class_method :normalized_configuration

      def self.validate_payload(payload, configuration)
        unless payload.is_a?(Hash) && payload["format"] == FORMAT
          raise ArgumentError, "invalid dictionary export"
        end
        unless payload["version"] == VERSION
          raise ArgumentError, "incompatible dictionary version"
        end
        config = payload["config"]
        unless config.is_a?(Hash)
          raise ArgumentError, "incompatible dictionary configuration"
        end

        exported_normalization = config["normalization"]
        unless exported_normalization.nil? ||
               (exported_normalization.is_a?(String) &&
                NORMALIZATION_FORMS.include?(exported_normalization.to_sym))
          raise ArgumentError, "incompatible dictionary normalization configuration"
        end
        exported_normalization = exported_normalization.to_sym unless exported_normalization.nil?
        exported_case_insensitive = config["case_insensitive"]
        unless (exported_case_insensitive.equal?(true) ||
                exported_case_insensitive.equal?(false)) &&
               exported_normalization == configuration[:normalization] &&
               exported_case_insensitive == configuration[:case_insensitive]
          raise ArgumentError, "incompatible dictionary normalization configuration"
        end
        unless payload["entries"].is_a?(Array)
          raise ArgumentError, "invalid dictionary entries"
        end
      end
      private_class_method :validate_payload

      def self.read_utf8_string(payload, key)
        value = payload[key]
        unless value.is_a?(String) && value.encoding == Encoding::UTF_8
          raise ArgumentError, "invalid dictionary #{key}"
        end
        value
      end
      private_class_method :read_utf8_string

      def self.read_non_negative_integer(payload, key)
        value = payload[key]
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError, "invalid dictionary #{key}"
        end
        value
      end
      private_class_method :read_non_negative_integer

      def self.read_priority(payload)
        value = payload["priority"]
        unless value.nil? || value.is_a?(Integer)
          raise ArgumentError, "invalid dictionary priority"
        end
        value
      end
      private_class_method :read_priority

      def initialize(entries = nil, normalization: nil, case_insensitive: false, &priority)
        configuration = self.class.send(:normalized_configuration, normalization, case_insensitive)
        @normalization = configuration[:normalization]
        @case_insensitive = configuration[:case_insensitive]
        @priority = priority
        @root = Node.new
        @size = 0
        @stored_entries = []

        entries&.each { |entry| add(entry) }
      end

      attr_reader :normalization, :case_insensitive, :size

      def add(entry, priority = nil)
        unless entry.is_a?(String)
          raise ArgumentError, "entry must be a String"
        end
        priority = @priority.call(entry) if priority.nil? && @priority
        unless priority.nil? || priority.is_a?(Integer)
          raise ArgumentError, "priority must be an Integer or nil"
        end

        add_entry(entry.dup.force_encoding(entry.encoding), priority, @size)
        self
      end

      def candidates(query, max_distance, include_stats: false)
        result = search(query, max_distance: max_distance)
        include_stats ? result : result.matches.map(&:entry)
      end

      def top_k(query, k, max_distance: nil, include_stats: false)
        validate_non_negative_integer(:k, k)
        unless max_distance.nil?
          validate_non_negative_integer(:max_distance, max_distance)
        end

        result = search(query, max_distance: max_distance, limit: k)
        include_stats ? result : result.matches.map(&:entry)
      end

      def search(query, max_distance: nil, limit: nil)
        unless query.is_a?(String)
          raise ArgumentError, "query must be a String"
        end
        unless max_distance.nil?
          validate_non_negative_integer(:max_distance, max_distance)
        end
        unless limit.nil?
          validate_non_negative_integer(:limit, limit)
        end

        return SearchResult.new([], 1) if limit == 0

        query_codepoints = codepoints(normalize(query))
        stack = [[@root, (0..query_codepoints.length).to_a]]
        matches = []
        expanded_nodes = 0

        until stack.empty?
          node, row = stack.pop
          expanded_nodes += 1

          node.matches.each do |stored_match|
            distance = row.last
            next unless max_distance.nil? || distance <= max_distance

            candidate = Match.new(stored_match.entry, distance,
                                  stored_match.priority, stored_match.rank)
            add_candidate(matches, candidate, limit)
          end

          cutoff = matches.length == limit ? matches.last.distance : nil
          node.children.each do |codepoint, child|
            child_row = next_row(row, query_codepoints, codepoint)
            lower_bound = child_row.min
            next unless cutoff.nil? || lower_bound <= cutoff
            next if max_distance && lower_bound > max_distance

            stack << [child, child_row]
          end
        end

        SearchResult.new(matches, expanded_nodes)
      end

      def entries
        @stored_entries.sort_by(&:rank).map(&:entry)
      end

      def export(io = nil)
        payload = {
          "format" => FORMAT,
          "version" => VERSION,
          "config" => {
            "normalization" => normalization,
            "case_insensitive" => case_insensitive
          },
          "entries" => @stored_entries.sort_by(&:rank).map do |stored|
            exported = {
              "entry" => stored.entry.encode(Encoding::UTF_8),
              "rank" => stored.rank
            }
            exported["priority"] = stored.priority unless stored.priority.nil?
            exported
          end
        }
        json = JSON.generate(payload)
        if io
          io.write(json)
          io
        else
          json
        end
      end

      private

      def add_entry(entry, priority, rank)
        node = codepoints(normalize(entry)).reduce(@root) do |current, codepoint|
          current.children[codepoint] ||= Node.new
        end
        node.matches << StoredMatch.new(entry.dup.freeze, priority, rank)
        @stored_entries << node.matches.last
        @size += 1
      end

      def normalize(string)
        value = string.encode(Encoding::UTF_8)
        value = value.unicode_normalize(@normalization) unless @normalization.nil?
        value = value.downcase(:fold) if @case_insensitive
        value
      end

      def codepoints(string)
        string.unpack("U*")
      end

      def next_row(row, query_codepoints, codepoint)
        next_row = [row.first + 1]
        query_codepoints.each_with_index do |query_codepoint, index|
          substitution = row[index] + (query_codepoint == codepoint ? 0 : 1)
          insertion = row[index + 1] + 1
          deletion = next_row[index] + 1
          next_row << [substitution, insertion, deletion].min
        end
        next_row
      end

      def add_candidate(matches, candidate, limit)
        index = matches.bsearch_index { |match| match > candidate } || matches.length
        matches.insert(index, candidate)
        matches.pop if limit && matches.length > limit
      end

      def validate_non_negative_integer(name, value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError, "#{name} must be a non-negative Integer"
        end
      end
    end
  end
end

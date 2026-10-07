$:.unshift File.expand_path("../../lib", __FILE__)
require "text/levenshtein/dictionary"

words = Array.new(10_000) { |index| "commonprefix%04d" % index }
dictionary = Text::Levenshtein::Dictionary.new(words)
result = dictionary.candidates_with_stats("commonprefix5432", max_distance: 1)

puts "words: #{words.length}"
puts "trie nodes: #{dictionary.node_count}"
puts "expanded nodes: #{result[:expanded_nodes]}"
puts "candidates: #{result[:candidates].length}"

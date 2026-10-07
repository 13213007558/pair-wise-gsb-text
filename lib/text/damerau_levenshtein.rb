#
# Damerau-Levenshtein distance algorithm implementation for Ruby, with UTF-8
# support.
#
# Like Text::Levenshtein, the distance is calculated in terms of Unicode
# codepoints, but a transposition of two adjacent characters also counts as a
# single edit. This is the *full* Damerau-Levenshtein distance: substrings
# may be edited more than once, so "CA" can be transformed into "ABC" in two
# edits (transpose "CA" into "AC", then insert "B"). The restricted variant
# (optimal string alignment), which forbids editing a substring twice, would
# report a distance of 3 for the same pair.
#
# Author: Paul Battley (pbattley@gmail.com)
#

module Text # :nodoc:
module DamerauLevenshtein

  # Status object returned by distance when a max_distance was given and the
  # true distance exceeds it. The exact distance is unknown, but it lies
  # within range, so a truncated value is never mistaken for the real
  # distance.
  #
  class LimitExceeded
    # The limit that was exceeded.
    attr_reader :max_distance

    # The interval (max_distance + 1)..upper_bound within which the true
    # distance lies. The upper bound is the length of the longer string,
    # which is always achievable by substitutions plus insertions or
    # deletions.
    attr_reader :range

    def initialize(max_distance, upper_bound) # :nodoc:
      @max_distance = max_distance
      @range = ((max_distance + 1)..upper_bound)
    end

    def exceeded?
      true
    end

    def inspect
      "#<#{self.class.name} range=#{range}>"
    end
    alias to_s inspect
  end

  # A single primitive edit. Every operation has unit cost.
  #
  # * +type+: one of :insert, :delete, :substitute or :transpose.
  # * +position+: index into the string as it stands when the operation is
  #   applied. For :transpose, the characters at position and position + 1
  #   are swapped.
  # * +character+: the inserted or substituted character, the deleted
  #   character for :delete, and nil for :transpose.
  #
  Operation = Struct.new(:type, :position, :character)

  # An optimal sequence of edit operations that transforms source into
  # target. The sequence can be replayed with apply.
  #
  class EditSequence
    # The source and target strings, encoded as UTF-8.
    attr_reader :source, :target

    # The operations, in the order in which they must be applied.
    attr_reader :operations

    def initialize(source, target, operations) # :nodoc:
      @source = source
      @target = target
      @operations = operations.freeze
    end

    # The total cost of the sequence. Every operation has unit cost, so this
    # is simply the number of operations.
    def distance
      operations.length
    end

    # Replay the operations on string (the source by default) and return the
    # resulting UTF-8 string.
    def apply(string = source)
      chars = DamerauLevenshtein.send(:characters, string)
      operations.each do |op|
        case op.type
        when :insert
          chars.insert(op.position, op.character)
        when :delete
          chars.delete_at(op.position)
        when :substitute
          chars[op.position] = op.character
        when :transpose
          chars[op.position], chars[op.position + 1] =
            chars[op.position + 1], chars[op.position]
        end
      end
      chars.join
    end
  end

  # Calculate the full Damerau-Levenshtein distance between two strings
  # +str1+ and +str2+.
  #
  # The distance is calculated in terms of Unicode codepoints. Be aware that
  # this algorithm does not perform normalisation: if there is a possibility
  # of different normalised forms being used, normalisation should be
  # performed beforehand.
  #
  # If the optional argument max_distance is given and the distance exceeds
  # it, a LimitExceeded status object is returned instead of an Integer; its
  # range describes the interval within which the true distance lies.
  #
  def distance(str1, str2, max_distance = nil)
    s = codepoints(str1)
    t = codepoints(str2)

    if max_distance
      upper_bound = [s.length, t.length].max
      if (s.length - t.length).abs > max_distance
        return LimitExceeded.new(max_distance, upper_bound)
      end
      d = compute(s, t, false).first
      d > max_distance ? LimitExceeded.new(max_distance, upper_bound) : d
    else
      compute(s, t, false).first
    end
  end

  # Calculate an optimal sequence of edit operations (insertions, deletions,
  # substitutions and adjacent transpositions, each with unit cost) that
  # transforms +str1+ into +str2+, and return it as an EditSequence.
  #
  # Repeated characters can admit several equally optimal sequences. Ties
  # are broken deterministically, preferring (in order) a match or
  # substitution, a transposition, a deletion and finally an insertion, so
  # the same pair of strings always yields the same sequence.
  #
  def edit_sequence(str1, str2)
    s = codepoints(str1)
    t = codepoints(str2)
    _, parents = compute(s, t, true)
    operations = replay(parents, s, t)
    EditSequence.new(
      s.map { |cp| cp.chr(Encoding::UTF_8) }.join,
      t.map { |cp| cp.chr(Encoding::UTF_8) }.join,
      operations
    )
  end

private
  def codepoints(str) # :nodoc:
    str.encode(Encoding::UTF_8).unpack("U*")
  end

  def characters(str) # :nodoc:
    codepoints(str).map { |cp| cp.chr(Encoding::UTF_8) }
  end

  # Lowrance-Wagner dynamic programming algorithm. Returns the distance and,
  # if record is true, a matrix of parent moves for backtracking.
  def compute(s, t, record) # :nodoc:
    n = s.length
    m = t.length
    big_int = n + m + 1

    h = Array.new(n + 2) { Array.new(m + 2, 0) }
    parents = record ? Array.new(n + 2) { Array.new(m + 2, nil) } : nil

    h[0][0] = big_int
    (0..n).each do |i|
      h[i + 1][0] = big_int
      h[i + 1][1] = i
    end
    (0..m).each do |j|
      h[0][j + 1] = big_int
      h[1][j + 1] = j
    end

    last_row = Hash.new(0)
    (1..n).each do |i|
      last_match_col = 0
      (1..m).each do |j|
        i1 = last_row[t[j - 1]]
        j1 = last_match_col

        cost = (s[i - 1] == t[j - 1]) ? 0 : 1
        last_match_col = j if cost.zero?

        diagonal = h[i][j] + cost
        transposition = h[i1][j1] + (i - i1 - 1) + 1 + (j - j1 - 1)
        deletion = h[i][j + 1] + 1
        insertion = h[i + 1][j] + 1

        best = diagonal
        move = cost.zero? ? :match : :substitute
        if transposition < best
          best = transposition
          move = [:transpose, i1, j1]
        end
        if deletion < best
          best = deletion
          move = :delete
        end
        if insertion < best
          best = insertion
          move = :insert
        end

        h[i + 1][j + 1] = best
        parents[i + 1][j + 1] = move if record
      end
      last_row[s[i - 1]] = i
    end

    [h[n + 1][m + 1], parents]
  end

  # Backtrack through the parent matrix and expand the moves into primitive
  # operations whose positions refer to the string as it stands when each
  # operation is applied.
  def replay(parents, s, t) # :nodoc:
    s = s.map { |cp| cp.chr(Encoding::UTF_8) }
    t = t.map { |cp| cp.chr(Encoding::UTF_8) }
    moves = []
    i = s.length
    j = t.length
    while i > 0 || j > 0
      move = (i > 0 && j > 0) ? parents[i + 1][j + 1] : nil
      case move
      when :match
        moves << [:match]
        i -= 1
        j -= 1
      when :substitute
        moves << [:substitute, t[j - 1]]
        i -= 1
        j -= 1
      when :delete
        moves << [:delete, s[i - 1]]
        i -= 1
      when :insert
        moves << [:insert, t[j - 1]]
        j -= 1
      when Array
        _, i1, j1 = move
        moves << [:block, i1, j1, i, j]
        i = i1 - 1
        j = j1 - 1
      else
        if i.zero?
          moves << [:insert, t[j - 1]]
          j -= 1
        else
          moves << [:delete, s[i - 1]]
          i -= 1
        end
      end
    end
    moves.reverse!

    operations = []
    pos = 0
    moves.each do |move|
      case move[0]
      when :match
        pos += 1
      when :substitute
        operations << Operation.new(:substitute, pos, move[1])
        pos += 1
      when :delete
        operations << Operation.new(:delete, pos, move[1])
      when :insert
        operations << Operation.new(:insert, pos, move[1])
        pos += 1
      when :block
        _, i1, j1, i, j = move
        # Delete the characters between the two that will be transposed.
        (i - i1 - 1).times do |k|
          operations << Operation.new(:delete, pos + 1, s[i1 + k])
        end
        # Transpose the two characters, now adjacent.
        operations << Operation.new(:transpose, pos, nil)
        # Insert the characters between the transposed pair in the target.
        (j - j1 - 1).times do |k|
          operations << Operation.new(:insert, pos + 1 + k, t[j1 + k])
        end
        pos += 2 + (j - j1 - 1)
      end
    end
    operations
  end

  extend self
end
end

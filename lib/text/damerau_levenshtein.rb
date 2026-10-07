#
# Full Damerau-Levenshtein distance algorithm implementation for Ruby, with
# UTF-8 support.
#
# The Damerau-Levenshtein distance extends the Levenshtein distance with a
# fourth edit operation: the transposition of two adjacent characters. This
# is the unrestricted version of the algorithm (Lowrance and Wagner), in
# which a substring may be edited more than once. It differs from the
# restricted optimal string alignment (OSA) variant: for example, the
# distance from "CA" to "ABC" is 2 here (transpose "CA" into "AC", then
# insert "B"), while OSA would report 3.
#

module Text # :nodoc:
module DamerauLevenshtein

  # Calculate the full Damerau-Levenshtein distance between two strings
  # +str1+ and +str2+ using insertion, deletion, substitution and adjacent
  # transposition, each with a cost of 1.
  #
  # The distance is calculated in terms of Unicode codepoints. Be aware that
  # this algorithm does not perform normalisation: if there is a possibility
  # of different normalised forms being used, normalisation should be
  # performed beforehand.
  #
  # If the optional +max_distance+ is given (a non-negative Integer), the
  # exact distance is returned when it does not exceed +max_distance+.
  # When the true distance exceeds +max_distance+, a Range is returned
  # instead: the true distance is guaranteed to lie within it. The Range is
  # an interval status, not a truncated distance; check for it before using
  # the result as a number:
  #
  #   result = Text::DamerauLevenshtein.distance("kitten", "sitting", 2)
  #   result # => 3..7
  #
  def distance(str1, str2, max_distance = nil)
    if max_distance && (!max_distance.is_a?(Integer) || max_distance < 0)
      raise ArgumentError, "max_distance must be a non-negative Integer"
    end

    s = str1.encode(Encoding::UTF_8).unpack("U*")
    t = str2.encode(Encoding::UTF_8).unpack("U*")

    return 0 if s == t

    n = s.length
    m = t.length

    # Every edit changes the length by at most one, so the length difference
    # is a lower bound on the distance.
    if max_distance && (n - m).abs > max_distance
      return exceeded_interval(max_distance, n, m)
    end

    d = distance_matrix(s, t)[n][m]

    if max_distance && d > max_distance
      exceeded_interval(max_distance, n, m)
    else
      d
    end
  end

  # Calculate an optimal sequence of edit operations that transforms +str1+
  # into +str2+. The result is an Array of operations, each an Array whose
  # first element is one of :insert, :delete, :substitute or :transpose:
  #
  #   [:insert,     position, char]
  #   [:delete,     position, char]
  #   [:substitute, position, old_char, new_char]
  #   [:transpose,  position, first_char, second_char]
  #
  # Positions are zero-based codepoint offsets into the string as it
  # evolves, so replaying the operations in order (see +apply+) transforms
  # +str1+ into +str2+. Characters are single-character UTF-8 Strings.
  #
  # The number of operations equals the distance. When repeated characters
  # allow several optimal sequences, the choice is deterministic: diagonal
  # moves (match or substitution) are preferred, then transpositions, then
  # deletions, then insertions.
  #
  def edit_sequence(str1, str2)
    s = str1.encode(Encoding::UTF_8).unpack("U*")
    t = str2.encode(Encoding::UTF_8).unpack("U*")

    matrix = distance_matrix(s, t)
    moves = backtrack(matrix, s, t)
    emit_operations(moves, s, t)
  end

  # Replay a sequence of operations, as produced by +edit_sequence+, on
  # +source+, returning the resulting (UTF-8) String.
  #
  def apply(source, operations)
    chars = source.encode(Encoding::UTF_8).chars
    operations.each do |operation|
      type, position = operation
      case type
      when :insert
        chars.insert(position, operation[2])
      when :delete
        chars.delete_at(position)
      when :substitute
        chars[position] = operation[3]
      when :transpose
        chars[position], chars[position + 1] = chars[position + 1], chars[position]
      else
        raise ArgumentError, "unknown edit operation: " + type.inspect
      end
    end
    chars.join
  end

private

  # The interval status returned when the distance exceeds max_distance:
  # the true distance is greater than max_distance and at most the cost of
  # substituting the common length and inserting or deleting the rest.
  def exceeded_interval(max_distance, n, m) # :nodoc:
    (max_distance + 1)..[n, m].max
  end

  # The unrestricted Damerau-Levenshtein dynamic programming matrix of
  # Lowrance and Wagner. The returned matrix has (s.length + 1) rows and
  # (t.length + 1) columns; cell [i][j] holds the distance between the
  # first i elements of s and the first j elements of t.
  def distance_matrix(s, t) # :nodoc:
    n = s.length
    m = t.length
    infinity = n + m + 1

    # Rows and columns are offset by one to make room for a sentinel border
    # that keeps transpositions away from non-existent prefixes.
    d = Array.new(n + 2) { Array.new(m + 2, 0) }
    d[0][0] = infinity
    (0..n).each do |i|
      d[i + 1][0] = infinity
      d[i + 1][1] = i
    end
    (0..m).each do |j|
      d[0][j + 1] = infinity
      d[1][j + 1] = j
    end

    # last_row[char] is the 1-based row in which char last appeared in s.
    last_row = Hash.new(0)
    (1..n).each do |i|
      # The 1-based column in which s[i - 1] last appeared in t.
      last_matching_col = 0
      (1..m).each do |j|
        i1 = last_row[t[j - 1]]
        j1 = last_matching_col

        cost = 1
        if s[i - 1] == t[j - 1]
          cost = 0
          last_matching_col = j
        end

        substitution  = d[i][j] + cost
        insertion     = d[i + 1][j] + 1
        deletion      = d[i][j + 1] + 1
        transposition = d[i1][j1] + (i - i1 - 1) + 1 + (j - j1 - 1)

        d[i + 1][j + 1] = [substitution, insertion, deletion, transposition].min
      end
      last_row[s[i - 1]] = i
    end

    # Drop the sentinel border, leaving an (n + 1) x (m + 1) matrix.
    (1..(n + 1)).map { |i| d[i][1..(m + 1)] }
  end

  # Walk the matrix from the bottom right corner back to the origin,
  # collecting the moves of an optimal edit script in reverse order. Ties
  # are resolved by the fixed preference order documented in
  # +edit_sequence+, so the result is stable.
  def backtrack(matrix, s, t) # :nodoc:
    moves = []
    i = s.length
    j = t.length

    while i > 0 || j > 0
      value = matrix[i][j]

      if i > 0 && j > 0
        cost = s[i - 1] == t[j - 1] ? 0 : 1
        if value == matrix[i - 1][j - 1] + cost
          moves << (cost.zero? ? [:match] : [:substitute, s[i - 1], t[j - 1]])
          i -= 1
          j -= 1
          next
        end

        i1 = j1 = nil
        (i - 1).downto(1) do |k|
          if s[k - 1] == t[j - 1]
            i1 = k
            break
          end
        end
        (j - 1).downto(1) do |k|
          if t[k - 1] == s[i - 1]
            j1 = k
            break
          end
        end
        if i1 && j1 &&
           value == matrix[i1 - 1][j1 - 1] + (i - i1 - 1) + 1 + (j - j1 - 1)
          moves << [:transpose_block, i1, j1, i, j]
          i = i1 - 1
          j = j1 - 1
          next
        end
      end

      if i > 0 && value == matrix[i - 1][j] + 1
        moves << [:delete, s[i - 1]]
        i -= 1
        next
      end

      # An insertion is always possible here: the matrix guarantees
      # value == matrix[i][j - 1] + 1 when no other move applied.
      moves << [:insert, t[j - 1]]
      j -= 1
    end

    moves.reverse
  end

  # Convert the backtracked moves into a replayable operation sequence,
  # tracking the cursor position in the evolving string. A transposition
  # block expands to deletions of the characters between the transposed
  # pair, the transposition itself, and insertions of the target characters
  # that fall between the pair.
  def emit_operations(moves, s, t) # :nodoc:
    operations = []
    position = 0

    moves.each do |move|
      case move[0]
      when :match
        position += 1
      when :substitute
        operations << [:substitute, position, char_string(move[1]), char_string(move[2])]
        position += 1
      when :delete
        operations << [:delete, position, char_string(move[1])]
      when :insert
        operations << [:insert, position, char_string(move[1])]
        position += 1
      when :transpose_block
        _, i1, j1, i, j = move
        ((i1 + 1)...i).each do |k|
          operations << [:delete, position + 1, char_string(s[k - 1])]
        end
        operations << [:transpose, position, char_string(s[i1 - 1]), char_string(s[i - 1])]
        ((j1 + 1)...j).each_with_index do |k, index|
          operations << [:insert, position + 1 + index, char_string(t[k - 1])]
        end
        position += j - j1 + 1
      end
    end

    operations
  end

  def char_string(codepoint) # :nodoc:
    [codepoint].pack("U*")
  end

  extend self
end
end

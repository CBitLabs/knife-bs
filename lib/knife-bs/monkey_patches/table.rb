#
# Author: bcandrea (https://github.com/bcandrea)
# Source: Terminal Table Pull Request #30 
# (https://github.com/visionmedia/terminal-table/pull/30)
#

#
# == Terminal::Table (Patch)
# As of version 1.4.5 (latest release 2012-03-15),
# the gem `terminal-table` has a bug when a specified
# width of a table ends up smaller than the combined
# column widths. It references an uninitialized variable
# `wanted` which raises a NameError. This patch fixes
# the bug by referring to `style.width` instead of
# `wanted`.

module Terminal
  class Table

    private
    def additional_column_widths
      return [] if style.width.nil?
      spacing = style.width - columns_width
      if spacing < 0
        raise "Table width exceeds wanted width of #{style.width} characters."
      else
        per_col = spacing / number_of_columns
        arr = (1...number_of_columns).to_a.map { |i| per_col }
        other_cols = arr.inject(0) { |s, i| s + 1 }
        arr << spacing - other_cols
        arr
      end
    end

  end
end

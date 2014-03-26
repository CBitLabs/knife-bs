class Array
  unless method_defined?(:quardatic_mean)
    def quadratic_mean
      ::Math.sqrt( self.inject(0) {|s, y| s += y*y}.to_f / self.length )
    end
  end
end
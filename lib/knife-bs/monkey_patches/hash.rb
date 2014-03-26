class Hash
  def -(other_hash)
    tmp = self.dup.to_hash
    tmp.each do |key, val|
      tmp.delete(key) if other_hash.has_key?(key) && other_hash[key] == tmp[key]
    end
    return tmp
  end
end

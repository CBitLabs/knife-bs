class AmiMixin
  include ::Chef::Knife::BsMixin
  def initialize(bsconf, data)
    super(bsconf, 'ami', data, File.expand_path(File.dirname(__FILE__)))
  end

  def ami_name
    @data[:full_name] ||= [:prefix,   :body,
                           :git_hash, :suffix].inject('') do |acc,part|
      self.instance_variable_set(
        "@#{part.to_s}",
        @data[part] ? binding.eval('"'+ @data[part] +'"') : ''
      )
      self.class.send(
        :define_method,
        part.to_s,
        proc {self.instance_variable_get("@#{part.to_s}")}
      )
      acc + self.instance_variable_get("@#{part.to_s}")
    end
    @data[:full_name]
  end

  def tags
    {
      :Name => ami_name,
      :creator => ENV['USER'],
      :created => Time.now.to_i
    }
  end

  def clean(server)
    action('run', server, 'clean')
  end
end

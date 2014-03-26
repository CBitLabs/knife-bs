class AmiMixin
  include ::Chef::Knife::BsMixin
  def initialize(data)
    super('ami', data, File.expand_path(File.dirname(__FILE__)))
  end

  def clean(server)
    action('run', server, 'clean')
  end
end

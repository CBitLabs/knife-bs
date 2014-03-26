class SSHKeysMixin
  include ::Chef::Knife::BsMixin
  def initialize(data)
    super('ssh-keys', data,
          File.expand_path(File.dirname(__FILE__)))
  end

  def authorize(server)
    action('run', server, 'authorize_ssh_keys')
  end
end

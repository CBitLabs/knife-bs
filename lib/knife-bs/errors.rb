class AMIError < StandardError; end
class YamlError < ArgumentError; end
class CloudwatchError < ArgumentError; end

# Use for errors with requests to EC2
class Ec2Error < RuntimeError; end
# Use for errors with EBS devices
class EbsError < RuntimeError; end
class BootstrapError < RuntimeError; end

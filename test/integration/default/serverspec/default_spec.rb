require 'spec_helper'

describe package('awsagent') do
  it { should be_installed }
end

# On a non-ec2 host, awsagent will fail to start successfully 
#describe service('awsagent') do
#  it { should be_running }
#end
